#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      PRINTER CHECK - read-only. Paste the whole thing into PowerShell
    ================================================================

      Lists every printer the logged-on user actually has, which one is
      their default, and whether a specific queue is present. Changes
      nothing.

      Works pasted into the ScreenConnect Commands tab, Backstage, or a
      normal user PowerShell window.

      The three lines at the very top are ScreenConnect hashbang
      modifiers: #!ps sends this to PowerShell, #timeout lifts the
      10-second kill, #maxlength lifts the 10,000-character output cap.
    ================================================================
#>

# =========================== CONFIG ============================
$PrinterPath = '\\IBNPS01\Reception Printer'   # <-- queue to look for ('' = just list)
$User        = ''                               # blank = whoever is logged on
# ===============================================================

# Optional overrides for the one-liner form:
#   $env:PrinterCheckPath = '\\server\queue' ; $env:PrinterCheckUser = 'DOMAIN\name'
if ($env:PrinterCheckPath) { $PrinterPath = $env:PrinterCheckPath }
if ($env:PrinterCheckUser) { $User        = $env:PrinterCheckUser }

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Printer-Check v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The read-only probe. Runs inside the user's session, and is the only thing that
# ever touches the user's HKCU.
$PayloadText = @'
[CmdletBinding()]
param(
    [string]$PrinterPath = '',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile      # Write-Line appends here when the task runs us

function Write-Line {
    param([string]$m)
    Write-Output $m
    if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m }
}

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { throw 'Refusing to report on SYSTEM - that would list SYSTEM printers, not the user.' }

Write-Line ('Identity : {0}' -f $ident.Name)
Write-Line ('Machine  : {0}' -f $env:COMPUTERNAME)
Write-Line ''

# ---- printers in the user's own view ---------------------------------------
$printers = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Sort-Object Name)
Write-Line ('Printers visible to this user ({0}):' -f $printers.Count)
if ($printers.Count -eq 0) { Write-Line '  (none)' }
foreach ($p in $printers) {
    $tag = if ($p.Default) { 'DEFAULT' } else { '       ' }
    Write-Line ('  [{0}] {1}' -f $tag, $p.Name)
    Write-Line ('            driver: {0} | port: {1}' -f $p.DriverName, $p.PortName)
}

# ---- per-user connection keys ----------------------------------------------
Write-Line ''
$connKey = 'HKCU:\Printers\Connections'
$conns = @()
if (Test-Path -LiteralPath $connKey) {
    $conns = @(Get-ChildItem -LiteralPath $connKey -ErrorAction SilentlyContinue)
}
Write-Line ('Per-user connections in HKCU ({0}):' -f $conns.Count)
if ($conns.Count -eq 0) { Write-Line '  (none)' }
foreach ($c in $conns) {
    $bits = $c.PSChildName.TrimStart(',').Split(',')
    if ($bits.Count -ge 2) {
        Write-Line ('  \\{0}\{1}' -f $bits[0], ($bits[1..($bits.Count - 1)] -join ','))
    }
    else {
        Write-Line ('  {0}' -f $c.PSChildName)
    }
}

# ---- built-ins that are not real printers ----------------------------------
$fake = @($printers | Where-Object { $_.Name -match 'Microsoft (Print to PDF|XPS Document Writer)|Fax|OneNote' })
if ($fake.Count) {
    Write-Line ''
    Write-Line 'Note: built-in, not real printers:'
    $fake | ForEach-Object { Write-Line ('  {0}' -f $_.Name) }
}

# ---- the specific queue -----------------------------------------------------
if ($PrinterPath) {
    Write-Line ''
    $PrinterPath = $PrinterPath.TrimEnd('\')
    $match = @($printers | Where-Object { $_.Name -eq $PrinterPath })

    $parts = $PrinterPath.TrimStart('\').Split('\')
    $expectedKey = 'HKCU:\Printers\Connections\,,' + ($parts -join ',')
    $keyPresent = Test-Path -LiteralPath $expectedKey

    Write-Line ('Checking : {0}' -f $PrinterPath)
    Write-Line ('  in user printer list : {0}' -f [bool]$match)
    Write-Line ('  HKCU connection key  : {0}' -f $keyPresent)
    Write-Line ('  key path             : {0}' -f $expectedKey)
    if ($match) {
        Write-Line ('  is default           : {0}' -f [bool]$match[0].Default)
        Write-Line ('  driver / port        : {0} / {1}' -f $match[0].DriverName, $match[0].PortName)
    }

    if ($match -and $keyPresent)      { Write-Line 'VERDICT: PRESENT' }
    elseif ($match -or $keyPresent)   { Write-Line 'VERDICT: PARTIAL - listed or keyed, but not both. Remove and re-add.' }
    else                              { Write-Line 'VERDICT: ABSENT' }
}
'@

# ---- write the probe somewhere every account can read ----------------------
$toolDir = 'C:\ProgramData\PrinterToolkit'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $payloadFile = Join-Path $toolDir ('PrinterCheck-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
catch {
    $payloadFile = Join-Path $env:TEMP ('PrinterCheck-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
Say ('Probe:    {0}' -f $payloadFile)
Say ('Queue:    {0}' -f $(if ($PrinterPath) { $PrinterPath } else { '(list only)' }))

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()

    # ---- already the right user: just read ---------------------------------
    if (-not $ident.IsSystem) {
        Say ('Running as {0} - reading directly.' -f $ident.Name)
        & $payloadFile -PrinterPath $PrinterPath
    }
    else {
        # ---- SYSTEM: read from inside the user's session -------------------
        $users = @(
            Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
                Select-Object -ExpandProperty UserName -Unique
        )
        if ($users.Count -eq 0) { throw 'Nobody is logged on - there is no user printer list to read.' }

        if (-not $User) {
            if ($users.Count -gt 1) {
                throw ("More than one user is logged on: {0}. Set `$User = 'DOMAIN\name' at the top." -f ($users -join ', '))
            }
            $User = $users[0]
        }
        elseif ($users -notcontains $User) {
            throw ('{0} has no session. Logged on: {1}' -f $User, ($users -join ', '))
        }
        Say ('SYSTEM shell - reading in {0}''s session' -f $User)

        $profileDir = $null
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
            $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
        }
        catch {
            Say 'Could not translate the account to a SID; using a name-based profile path.'
        }
        if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

        # A task's console output is not readable from here, so the probe writes a file
        # in the user's own temp folder and we read that afterwards.
        $outFile = '{0}\AppData\Local\Temp\PrinterCheck-{1}.txt' -f $profileDir, $stamp
        $taskName = 'PrinterCheck-' + $stamp
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PrinterPath "{1}" -OutFile "{2}"' -f `
                        $payloadFile, $PrinterPath, $outFile

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
            -Settings $settings -Force | Out-Null

        $startedAt = Get-Date
        # LastRunTime is truncated to whole seconds by Windows, hence the slack.
        $notBefore = $startedAt.AddSeconds(-5)
        $task = $null; $info = $null; $done = $false
        $lastNote = Get-Date
        try {
            Start-ScheduledTask -TaskName $taskName
            Say 'Reading...'
            $deadline = (Get-Date).AddSeconds(120)
            do {
                Start-Sleep -Seconds 2
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
                $done = $task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -ge $notBefore
                if (-not $done -and ((Get-Date) - $lastNote).TotalSeconds -ge 30) {
                    Say ('  still waiting - state: {0}' -f $task.State)
                    $lastNote = Get-Date
                }
            } while (-not $done -and (Get-Date) -lt $deadline)
        }
        finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        Write-Host ''
        if (Test-Path -LiteralPath $outFile) {
            Get-Content -LiteralPath $outFile | ForEach-Object { Write-Host $_ }
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
        else {
            Say ('No output at {0} - the probe did not run as that user.' -f $outFile)
            Say ('Task result: {0}' -f $(if ($info) { $info.LastTaskResult } else { 'n/a' }))
        }
    }
}
finally {
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
}
