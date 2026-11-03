#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      RESET OUTLOOK CACHE - for the logged-on user. Detects whether
      they use NEW Outlook or CLASSIC Outlook and resets the right one.
      Paste the whole thing into PowerShell.
    ================================================================

      What it does, per user, after closing Outlook:

        * CLASSIC Outlook (outlook.exe) - renames each cached-mailbox
          data file (*.ost) to *.ost.old-<stamp>. Outlook rebuilds the
          OST and re-syncs from the server on next launch. Nothing is
          deleted, so it is reversible, and .pst files (local-only data,
          e.g. POP/archives) are NEVER touched.

        * NEW Outlook (olk.exe) - renames the app's LocalCache folder to
          LocalCache.old-<stamp>. New Outlook recreates it and
          re-downloads from the cloud. Also reversible.

      It resets whichever is detected (or both). It does NOT remove
      accounts, profiles or signatures.

      Runs pasted into the Commands tab, from Backstage, or the user's
      own window. As SYSTEM it bridges into the logged-on user session.

      Optional:
        $env:OutlookCacheUser = 'DOMAIN\name'       # pick the user yourself
        $env:OutlookCacheMode = 'classic'|'new'|'both'   # default: both detected

      The hashbang lines at the top must stay contiguous - a blank line
      between them and ScreenConnect keeps its 10-second kill.
    ================================================================
#>

$User = ''
$Mode = 'auto'
if ($env:OutlookCacheUser) { $User = $env:OutlookCacheUser }
if ($env:OutlookCacheMode) { $Mode = ([string]$env:OutlookCacheMode).ToLower() }
if ($Mode -notin 'auto','both','classic','new') { $Mode = 'auto' }

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Reset-OutlookCache v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work must run as the user: the OST and the new-Outlook cache live in their profile.
$PayloadText = @'
[CmdletBinding()]
param([string]$Mode = 'auto', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile
function W { param([string]$m = '') Write-Output $m; if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m } }

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { W 'FAILED: refusing to run as SYSTEM - Outlook data is per-user.'; W 'END-OF-REPORT'; return }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
W ('Identity : {0}' -f $ident.Name)
W ('Machine  : {0}' -f $env:COMPUTERNAME)

# ---- detect what is installed / in use ------------------------------------
$ostDir   = Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'
$osts     = @(Get-ChildItem -LiteralPath $ostDir -Filter '*.ost' -ErrorAction SilentlyContinue)
$classicInstalled = $false
try {
    $ap = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\outlook.exe'
    $classicInstalled = (Test-Path -LiteralPath $ap) -or ($osts.Count -gt 0)
}
catch { $classicInstalled = ($osts.Count -gt 0) }

$newPkg = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.OutlookForWindows_8wekyb3d8bbwe'
$newInstalled = Test-Path -LiteralPath $newPkg

W ('Classic Outlook installed : {0} ({1} OST file(s))' -f $classicInstalled, $osts.Count)
W ('New Outlook installed     : {0}' -f $newInstalled)

$doClassic = $false
$doNew     = $false
switch ($Mode) {
    'classic' { $doClassic = $true }
    'new'     { $doNew = $true }
    default   { $doClassic = $classicInstalled; $doNew = $newInstalled }   # auto / both
}

# ---- close Outlook (both kinds) -------------------------------------------
$running = @(Get-Process -Name outlook, olk -ErrorAction SilentlyContinue)
if ($running.Count) {
    W ('Closing Outlook ({0})...' -f (($running | Select-Object -ExpandProperty Name -Unique) -join ', '))
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Process -Name outlook, olk -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
}

$did = $false
$problems = @()

# ---- classic: rename the OST(s) -------------------------------------------
if ($doClassic) {
    if ($osts.Count -eq 0) {
        W 'Classic: no .ost files to reset (not in cached mode, or never signed in).'
    }
    foreach ($ost in $osts) {
        $target = '{0}.old-{1}' -f $ost.FullName, $stamp
        try {
            Rename-Item -LiteralPath $ost.FullName -NewName (Split-Path $target -Leaf) -ErrorAction Stop
            W ('Classic: renamed {0} -> {1}' -f $ost.Name, (Split-Path $target -Leaf))
            $did = $true
        }
        catch {
            W ('Classic: could NOT rename {0}: {1}' -f $ost.Name, $_.Exception.Message)
            $problems += ('OST still locked: ' + $ost.Name)
        }
    }
}

# ---- new Outlook: rename the LocalCache folder ----------------------------
if ($doNew -and $newInstalled) {
    $localCache = Join-Path $newPkg 'LocalCache'
    if (Test-Path -LiteralPath $localCache) {
        $target = '{0}.old-{1}' -f $localCache, $stamp
        try {
            Rename-Item -LiteralPath $localCache -NewName (Split-Path $target -Leaf) -ErrorAction Stop
            W ('New: renamed LocalCache -> {0}' -f (Split-Path $target -Leaf))
            $did = $true
        }
        catch {
            W ('New: could NOT rename LocalCache: {0}' -f $_.Exception.Message)
            $problems += 'new-Outlook LocalCache still locked'
        }
    }
    else {
        W 'New: no LocalCache folder found (nothing to reset).'
    }
}

W ''
if ($problems.Count) {
    foreach ($p in $problems) { W ('PROBLEM: {0}' -f $p) }
    W 'FAILED: something could not be reset - see the PROBLEM line(s). Outlook may still be running.'
}
elseif ($did) {
    W 'Outlook will rebuild its cache and re-sync from the server next time it opens.'
    W 'OUTLOOK CACHE RESET'
}
else {
    W 'NOTHING-TO-DO: no Outlook cache was found to reset.'
}
W 'END-OF-REPORT'
'@

$toolDir = 'C:\ProgramData\OutlookCache'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $probe = Join-Path $toolDir ('Reset-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}
catch {
    $probe = Join-Path $env:TEMP ('Reset-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem
$raw = ''

if (-not $isSystem) {
    Say ('Running as {0} - resetting in place.' -f $ident.Name)
    $out = Join-Path $env:TEMP ('OutlookCache-{0}.txt' -f $stamp)
    & $probe -Mode $Mode -OutFile $out | ForEach-Object { Write-Host '    ' $_ }
    if (Test-Path -LiteralPath $out) {
        $raw = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}
else {
    $users = @(
        Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
            Select-Object -ExpandProperty UserName -Unique
    )
    if ($users.Count -eq 0) {
        Say 'Nobody is logged on - there is no Outlook profile to reset.'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not $User) {
        if ($users.Count -gt 1) {
            Say ('More than one user is logged on: {0}' -f ($users -join ', '))
            Say 'Set $env:OutlookCacheUser = ''DOMAIN\name'' and run again.'
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return
        }
        $User = $users[0]
    }
    elseif ($users -notcontains $User) {
        Say ('{0} has no session. Logged on: {1}' -f $User, ($users -join ', '))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return
    }
    Say ('SYSTEM shell - resetting in {0}''s session' -f $User)

    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    }
    catch { }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

    $outFile  = '{0}\AppData\Local\Temp\OutlookCache-{1}.txt' -f $profileDir, $stamp
    $taskName = 'OutlookCache-' + $stamp
    $argLine  = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode {1} -OutFile "{2}"' -f $probe, $Mode, $outFile

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    try {
        Start-ScheduledTask -TaskName $taskName
        Say 'Resetting...'
        $deadline = (Get-Date).AddSeconds(90)
        while ($raw -notmatch 'END-OF-REPORT' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 600
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
            ForEach-Object { Write-Host '    ' $_ }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    else {
        Say 'No report came back - the reset may not have run as that user.'
        Say ('Probe kept at {0}' -f $probe)
        return
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($raw -match 'OUTLOOK CACHE RESET') {
    Write-Host 'RESULT: RESET - Outlook''s cache was renamed; it rebuilds and re-syncs on next launch.' -ForegroundColor Green
    Write-Host '        The old cache is kept alongside as .old-<stamp> and can be restored if needed.'
}
elseif ($raw -match 'NOTHING-TO-DO') {
    Write-Host 'RESULT: NOTHING TO DO - no Outlook cache was found to reset.' -ForegroundColor Yellow
}
elseif ($raw -match 'FAILED:') {
    Write-Host 'RESULT: FAILED - see the PROBLEM line(s) above (Outlook may still be open).' -ForegroundColor Red
}
else {
    Write-Host 'RESULT: UNKNOWN - no verdict in the report.' -ForegroundColor Yellow
}
