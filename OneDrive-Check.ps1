#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      ONEDRIVE CHECK - read-only. Is OneDrive running, signed in,
      and actually syncing?
    ================================================================

      Reports, for the logged-on user:

        * whether OneDrive.exe is running, its version and uptime
        * which accounts are registered (work/school, personal)
        * the folder each one syncs, and whether that folder exists
        * when OneDrive last wrote to its own log - the only reliable
          local signal that the sync engine is alive and doing work
        * the last error lines from that log

      Ends with one verdict: HEALTHY, DEGRADED or FAILED, with the
      reason. Changes nothing. No printer names, no config.

      What it CANNOT tell you, without talking to Microsoft:
        - how much quota is left
        - whether one particular file is uploaded
        - why a specific file is stuck (needs the OneDrive UI)

      Run it pasted into the Commands tab, from Backstage, or in the
      user's own PowerShell window. When run as SYSTEM it bridges into
      the logged-on user's session automatically.
    ================================================================
#>

$ErrorActionPreference = 'Stop'
$scriptVersion = '1.0.0'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------------------------------------------------------------------------
#  The probe. Runs inside the user's session: only there does HKCU mean the
#  right person and only there is OneDrive.exe theirs.
# ---------------------------------------------------------------------------
$PayloadText = @'
[CmdletBinding()]
param([string]$OutFile = '')

$ErrorActionPreference = 'Continue'
$script:Out = $OutFile

function W {
    param([string]$m = '')
    Write-Output $m
    if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m }
}

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { throw 'Refusing to report on SYSTEM - run this in the user session.' }

W ('Identity : {0}' -f $ident.Name)
W ('Machine  : {0}' -f $env:COMPUTERNAME)

$problems = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList

# ---- 1. process -----------------------------------------------------------
W ''
$proc = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
if ($proc.Count) {
    $p = $proc | Sort-Object StartTime | Select-Object -First 1
    $ver = $null
    try { $ver = (Get-Item -LiteralPath $p.Path).VersionInfo.FileVersion } catch { }
    $up = try { (New-TimeSpan -Start $p.StartTime -End (Get-Date)) } catch { $null }
    W ('Process  : running ({0} instance(s), PID {1})' -f $proc.Count, $p.Id)
    if ($ver) { W ('Version  : {0}' -f $ver) }
    if ($up)  { W ('Uptime   : {0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes) }
    W ('Path     : {0}' -f $p.Path)
}
else {
    W 'Process  : NOT RUNNING'
    [void]$problems.Add('OneDrive.exe is not running')
}

# ---- 2. accounts ----------------------------------------------------------
$accountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
W ''
if (-not (Test-Path -LiteralPath $accountsKey)) {
    W 'Accounts : none registered - OneDrive has never been signed in for this user'
    [void]$problems.Add('no OneDrive account is registered (not signed in)')
}
else {
    $accts = @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue)
    W ('Accounts : {0} registered' -f $accts.Count)
    foreach ($a in $accts) {
        $props  = Get-ItemProperty -LiteralPath $a.PSPath -ErrorAction SilentlyContinue
        $folder = [string]$props.UserFolder
        $email  = [string]$props.UserEmail
        W ('  {0}' -f $a.PSChildName)
        if ($email) { W ('    user   : {0}' -f $email) } else { W '    user   : (no email recorded)' }
        if ($folder) {
            $exists = Test-Path -LiteralPath $folder
            W ('    folder : {0}' -f $folder)
            W ('    exists : {0}' -f $exists)
            if (-not $exists) { [void]$problems.Add("sync folder is missing: $folder") }
        }
        else {
            W '    folder : (none) - leftover registration, not a live account'
        }
    }
    if ($accts.Count -eq 0) { [void]$problems.Add('no OneDrive account is registered (not signed in)') }
}

# ---- 3. is the engine alive? log freshness --------------------------------
# OneDrive writes .odl logs continuously while it works. A log that has not been
# touched for a long time while the process IS running means it is stuck or idle.
$logRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\logs'
$newest = $null
if (Test-Path -LiteralPath $logRoot) {
    $newest = Get-ChildItem -LiteralPath $logRoot -Recurse -Filter '*.odl' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1
}
W ''
if ($newest) {
    $ageMinutes = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
    W ('Log      : last written {0} min ago ({1})' -f $ageMinutes, $newest.Name)
    if ($ageMinutes -gt 15 -and $proc.Count) {
        [void]$warnings.Add("OneDrive is running but has not written to its log for $ageMinutes min - it may be idle or stuck")
    }
}
else {
    W 'Log      : no OneDrive logs found - it may never have run for this user'
    if ($proc.Count) { [void]$warnings.Add('no OneDrive logs found despite the process running') }
}

# ---- 4. recent complaints in the log --------------------------------------
W ''
if ($newest) {
    $bad = @(Get-Content -LiteralPath $newest.FullName -Tail 400 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '(?i)\b(error|failed|quota|blocked|cannot|denied)\b' } |
                Select-Object -Last 5)
    if ($bad.Count) {
        W 'Recent log lines worth reading:'
        $bad | ForEach-Object { W ('  {0}' -f $_.Trim()) }
    }
    else {
        W 'Recent log lines worth reading: none of error/failed/quota/blocked in the last 400'
    }
}

# ---- 5. files in the sync folder (proof there is something to sync) --------
W ''
if ($accountsKey -and (Test-Path -LiteralPath $accountsKey)) {
    foreach ($a in @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue)) {
        $props  = Get-ItemProperty -LiteralPath $a.PSPath -ErrorAction SilentlyContinue
        $folder = [string]$props.UserFolder
        if ($folder -and (Test-Path -LiteralPath $folder)) {
            $files = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
                          Select-Object -First 200)
            $placeholders = @($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::Offline })
            W ('{0}: {1} item(s) at the top level, {2} cloud-only placeholder(s)' -f `
                $a.PSChildName, $files.Count, $placeholders.Count)
        }
    }
}

# ---- verdict --------------------------------------------------------------
W ''
if ($problems.Count) {
    foreach ($pr in $problems) { W ('PROBLEM: {0}' -f $pr) }
    W 'VERDICT: FAILED'
}
elseif ($warnings.Count) {
    foreach ($w in $warnings) { W ('WARNING: {0}' -f $w) }
    W 'VERDICT: DEGRADED'
}
else {
    W 'VERDICT: HEALTHY'
}
W 'END-OF-REPORT'
'@

# ---------------------------------------------------------------------------
#  Write the probe somewhere any account can read, then run it in the session
# ---------------------------------------------------------------------------
$toolDir = 'C:\ProgramData\OneDriveCheck'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $probe = Join-Path $toolDir ('Probe-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}
catch {
    $probe = Join-Path $env:TEMP ('Probe-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}

Say ('OneDrive-Check v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem

# ---- run as the logged-on user directly -----------------------------------
if (-not $isSystem) {
    Say ('Running as {0} - checking in place.' -f $ident.Name)
    $out = Join-Path $env:TEMP ('OneDriveCheck-{0}.txt' -f $stamp)
    & $probe -OutFile $out
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return
}

# ---- SYSTEM: bridge into the user session ---------------------------------
$users = @(
    Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
        Select-Object -ExpandProperty UserName -Unique
)
if ($users.Count -eq 0) {
    Say 'Nobody is logged on - there is no OneDrive session to inspect.'
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return
}
if ($users.Count -gt 1) {
    Say ('More than one user is logged on: {0}' -f ($users -join ', '))
    Say 'Set $env:OneDriveCheckUser = ''DOMAIN\name'' and run again.'
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return
}
$target = if ($env:OneDriveCheckUser) { $env:OneDriveCheckUser } else { $users[0] }
Say ('Target user: {0}' -f $target)

$profileDir = $null
try {
    $sid = (New-Object System.Security.Principal.NTAccount($target)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
    $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
}
catch { }
if (-not $profileDir) { $profileDir = 'C:\Users\' + ($target -split '\\')[-1] }

$outFile  = '{0}\AppData\Local\Temp\OneDriveCheck-{1}.txt' -f $profileDir, $stamp
$taskName = 'OneDriveCheck-' + $stamp
$argLine  = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}"' -f $probe, $outFile

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$principal = New-ScheduledTaskPrincipal -UserId $target -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
    -Settings $settings -Force | Out-Null

$raw = ''
try {
    Start-ScheduledTask -TaskName $taskName
    Say 'Reading...'
    $deadline = (Get-Date).AddSeconds(40)
    while ($raw -notmatch 'END-OF-REPORT' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $outFile) {
            $raw = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
            if (-not $raw) { $raw = '' }
        }
    }
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host ''
if ($raw -match 'END-OF-REPORT') {
    Get-Content -LiteralPath $outFile | Where-Object { $_ -notmatch 'END-OF-REPORT' } |
        ForEach-Object { Write-Host $_ }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}
else {
    Say 'No report came back - the probe did not run as that user.'
    Say ('Probe kept at {0}' -f $probe)
    return
}
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($raw -match 'VERDICT: HEALTHY') {
    Write-Host 'RESULT: HEALTHY - OneDrive is running, signed in and writing to its log.' -ForegroundColor Green
}
elseif ($raw -match 'VERDICT: DEGRADED') {
    Write-Host 'RESULT: DEGRADED - it is signed in, but something looks stuck or idle.' -ForegroundColor Yellow
}
elseif ($raw -match 'VERDICT: FAILED') {
    Write-Host 'RESULT: FAILED - see the PROBLEM lines above.' -ForegroundColor Red
}
else {
    Write-Host 'RESULT: UNKNOWN - no verdict in the report.' -ForegroundColor Yellow
}
