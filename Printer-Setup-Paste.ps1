#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      PRINTER SETUP - paste the whole thing into PowerShell
    ================================================================

      The three lines above are ScreenConnect "hashbang" modifiers.
      They matter if you paste this into the Commands tab (the web
      PowerShell box), which otherwise kills any command after 10
      SECONDS and truncates output at 10,000 characters:

        #!ps              send this to PowerShell instead of cmd
        #timeout=600000   10 minutes instead of 10 seconds
        #maxlength=...    full log instead of a truncated stub

      In Backstage or a normal PowerShell window they are just
      comments '#...' and are ignored, so nothing breaks there.

      Works in a ScreenConnect Backstage / Commands tab shell (SYSTEM)
      and also in a normal user PowerShell window.

      EDIT ONLY THE FOUR LINES IN THE CONFIG BLOCK BELOW, then paste
      the entire file into the PowerShell window and press Enter.

      No file upload, no execution policy change: commands pasted into
      an interactive PowerShell session are not subject to the policy.

      What it does, in plain terms: gets the printer connected in the
      logged-on user's own session, so it actually appears in their
      printer list. Adds nothing to SYSTEM's profile.
    ================================================================
#>

# =========================== CONFIG ============================
$PrinterPath = '\\IBNPS01\Reception printer'   # <-- CHANGE THIS: \\server\printer
$SetDefault  = $true                            # make it the user's default printer
$Elevated    = $false                           # $true only if the driver won't install
$User        = ''                               # blank = whoever is logged on
# ===============================================================

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.2.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# First output line, so a run is identifiable at a glance. If you do NOT see this line
# in the Commands tab, whatever you pasted was not this script.
Say ('Printer-Setup-Paste v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work that has to happen inside the user's session. Kept as literal text so it
# can be dropped to a file and run under the user's token (or run right here).
$PayloadText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrinterPath,
    [switch]$SetDefault
)
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'PrinterToolkit'
$null = New-Item -ItemType Directory -Path $logDir -Force
$logFile = Join-Path $logDir ('Setup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$m)
    $line = '{0}  {1}' -f (Get-Date -Format 's'), $m
    Add-Content -LiteralPath $logFile -Value $line
    Write-Output $line
}

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { throw 'Refusing to run as SYSTEM - the printer would be added for SYSTEM, not the user.' }

Write-Log ('Printer setup for {0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
Write-Log ('Identity: {0}' -f $ident.Name)
Write-Log ('Queue:    {0}' -f $PrinterPath)

$parts = $PrinterPath.TrimEnd('\').TrimStart('\').Split('\')
$connPath = 'HKCU:\Printers\Connections\,,' + ($parts -join ',')

Write-Log ('Registry key: {0}' -f $connPath)
Write-Log ('Before - key present: {0}' -f (Test-Path -LiteralPath $connPath))

$existing = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterPath })
Write-Log ('Before - visible to user: {0}' -f [bool]$existing)

if (-not $existing) {
    $added = $false
    if (Get-Command Add-PrinterConnection -ErrorAction SilentlyContinue) {
        try {
            Add-PrinterConnection -ConnectionName $PrinterPath -ErrorAction Stop
            $added = $true
            Write-Log 'Add-PrinterConnection succeeded.'
        }
        catch {
            Write-Log ('Add-PrinterConnection failed: {0}' -f $_.Exception.Message)
            Write-Log 'Trying printui.dll instead.'
        }
    }
    if (-not $added) {
        $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                -ArgumentList ('printui.dll,PrintUIEntry /in /q /n "{0}"' -f $PrinterPath)
        Write-Log ('printui /in exit code: {0}' -f $p.ExitCode)
    }
    Start-Sleep -Seconds 2
}
else {
    Write-Log 'Already connected for this user - not adding again.'
}

# Read back. This is what makes the exit code trustworthy.
$present = Test-Path -LiteralPath $connPath
$visible = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterPath })
Write-Log ('After - key present: {0}' -f $present)
Write-Log ('After - visible to user: {0}' -f [bool]$visible)

if (-not $present -or -not $visible) {
    throw ('NOT CONNECTED: {0} is not on the printer list. If the driver is missing and non-admin install is blocked, set the Elevated option to true and paste again.' -f $PrinterPath)
}

if ($SetDefault) {
    $target = $visible | Select-Object -First 1
    try {
        Invoke-CimMethod -InputObject $target -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
        Write-Log 'SetDefaultPrinter invoked.'
    }
    catch {
        $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                -ArgumentList ('printui.dll,PrintUIEntry /y /q /n "{0}"' -f $PrinterPath)
        Write-Log ('printui /y exit code: {0}' -f $p.ExitCode)
    }
    $def = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Default }) | Select-Object -First 1
    if ($def) { Write-Log ('Default printer: {0}' -f $def.Name) }
    if (-not $def -or $def.Name -ne $PrinterPath) {
        throw ('Could not confirm {0} as the default printer.' -f $PrinterPath)
    }
}

Write-Log 'Printers for this user now:'
Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    Write-Log ('  {0}{1}  [{2}]' -f $_.Name, $(if ($_.Default) { ' (default)' } else { '' }), $_.PortName)
}

Write-Log 'CONNECTED OK'
'@

# ---- 0. sanity-check the config -------------------------------------------------
$PrinterPath = $PrinterPath.TrimEnd('\')
if ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
    throw "`$PrinterPath must look like \\server\printer - you have '$PrinterPath'"
}

Say ('Queue:     {0}' -f $PrinterPath)
Say ('Default:   {0}' -f $SetDefault)

# ---- 1. drop the payload somewhere every account can read it --------------------
$toolDir = 'C:\ProgramData\PrinterToolkit'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $payloadFile = Join-Path $toolDir ('PrinterSetup-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
catch {
    $toolDir = $env:TEMP
    $payloadFile = Join-Path $toolDir ('PrinterSetup-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
Say ('Payload:   {0}' -f $payloadFile)

$ok = $false
$keepPayload = $false

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()

    # ---- 2. already the right user? just do the work ---------------------------
    if (-not $ident.IsSystem) {
        Say ('Running as {0} - doing the work directly.' -f $ident.Name)
        try {
            & $payloadFile -PrinterPath $PrinterPath -SetDefault:$SetDefault | ForEach-Object { Write-Host '    ' $_ }
            $ok = $true
        }
        catch {
            Say ('Payload reported: {0}' -f $_.Exception.Message)
        }
    }
    else {
        # ---- 3. SYSTEM: find the user and bridge into their session ------------
        $users = @(
            Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
                Select-Object -ExpandProperty UserName -Unique
        )
        if ($users.Count -eq 0) { throw 'Nobody is logged on. A printer connection needs a user session.' }

        if (-not $User) {
            if ($users.Count -gt 1) {
                throw ("More than one user is logged on: {0}. Set `$User = 'DOMAIN\name' at the top." -f ($users -join ', '))
            }
            $User = $users[0]
        }
        elseif ($users -notcontains $User) {
            throw ('{0} has no session. Logged on: {1}' -f $User, ($users -join ', '))
        }

        Say ('SYSTEM shell - bridging into {0}' -f $User)

        # profile path by SID, because the folder name does not always match the account
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

        $taskName = 'PrinterSetup-' + $stamp
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PrinterPath "{1}"{2}' -f `
                        $payloadFile, $PrinterPath, $(if ($SetDefault) { ' -SetDefault' } else { '' })

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
        $runLevel  = if ($Elevated) { 'Highest' } else { 'Limited' }
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $runLevel
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

        Say ('Task:      {0} (run level {1})' -f $taskName, $runLevel)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
            -Settings $settings -Force | Out-Null

        $startedAt = Get-Date
        # LastRunTime comes back truncated to whole seconds, so allow slack - otherwise a
        # task that finishes in 200ms never satisfies "LastRunTime -gt startedAt".
        $notBefore = $startedAt.AddSeconds(-5)
        $task = $null; $info = $null; $done = $false
        $lastNote = Get-Date

        try {
            Start-ScheduledTask -TaskName $taskName
            Say 'Waiting for the user session...'

            $deadline = (Get-Date).AddSeconds(180)
            do {
                Start-Sleep -Seconds 2
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
                $done = $task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -ge $notBefore
                if (-not $done -and ((Get-Date) - $lastNote).TotalSeconds -ge 30) {
                    Say ('  still waiting - state: {0}, last result: {1}' -f `
                            $task.State, $(if ($info) { $info.LastTaskResult } else { 'n/a' }))
                    $lastNote = Get-Date
                }
            } while (-not $done -and (Get-Date) -lt $deadline)

            if (-not $done) {
                Say ("Timed out waiting. Task state: {0}. Its log may still be growing." -f $task.State)
                $keepPayload = $true
            }
            elseif ($info.LastTaskResult -eq 0) {
                Say 'Task finished, exit code 0.'
                $ok = $true
            }
            else {
                Say ('Task finished with exit code {0} (0x{0:X}).' -f $info.LastTaskResult)
            }
        }
        finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        # show the user's log, wherever it actually is
        $logDir = '{0}\AppData\Local\PrinterToolkit' -f $profileDir
        $log = Get-ChildItem -LiteralPath $logDir -Filter 'Setup-*.log' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            Say ('Log: {0}' -f $log.FullName)
            Get-Content -LiteralPath $log.FullName | ForEach-Object { Write-Host '    ' $_ }
            if ((Get-Content -LiteralPath $log.FullName -Raw) -match 'CONNECTED OK') { $ok = $true }
        }
        else {
            Say ('No log at {0} - the task did not run as that user.' -f $logDir)
        }
    }
}
finally {
    if ($keepPayload) {
        Say ('Payload kept for inspection: {0}' -f $payloadFile)
    }
    else {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($ok) {
    Write-Host ('RESULT: CONNECTED - {0} is on the printer list.' -f $PrinterPath) -ForegroundColor Green
    if ($SetDefault) { Write-Host '        It is set as the default printer.' }
}
else {
    Write-Host 'RESULT: NOT CONNECTED - read the log above for the reason.' -ForegroundColor Red
    Write-Host '        If it mentions access denied, set $Elevated = $true and paste again.'
}
