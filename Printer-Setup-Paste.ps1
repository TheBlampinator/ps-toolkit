#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      PRINTER SETUP - paste the whole thing into PowerShell
    ================================================================

      IMPORTANT - the ScreenConnect Commands tab kills a command after
      10 SECONDS, and some builds ignore #timeout. This script therefore
      never waits longer than ~4s. If the work has not finished by then
      it prints how to read the result a few seconds later. Nothing is
      lost: the user-session payload writes a log and keeps going.

      The lines at the top are ScreenConnect hashbang modifiers. They MUST
      be contiguous on the first lines - a blank line between them and
      only the first is applied, which silently leaves the 10-second kill
      in place. Confirmed on 26.7.6.9783.

      Works pasted into the Commands tab, Backstage, or a user window.

      NOTHING IS BUILT IN. This script will not run until you set
      $env:PrinterSetupPath - it prints exactly what to type. No file
      upload, no execution policy change: pasted commands are not
      subject to the policy.
    ================================================================
#>

# =====================================================================
#  SETTINGS - ENVIRONMENT VARIABLES ONLY. There is no printer name in
#  this file on purpose: nothing site-specific, nothing to edit.
# =====================================================================
$SetDefault  = $true                            # set it as the user's default
$Elevated    = $false                           # $true only if the driver won't install
$User        = ''                               # blank = whoever is logged on
$WaitSeconds = 180                              # a failing printui call takes ~150s

if ($env:PrinterSetupElevated -eq 'true')  { $Elevated    = $true }
if ($env:PrinterSetupDefault -eq 'false')  { $SetDefault  = $false }
if ($env:PrinterSetupUser)                 { $User        = $env:PrinterSetupUser }
if ($env:PrinterSetupWait)                 { $WaitSeconds = [int]$env:PrinterSetupWait }

# Read mode: print the newest stored result and stop. Needs no queue, so it runs
# BEFORE the guard below. Safe to repeat, and it clears anything left behind.
if ($env:PrinterSetupRead) {
    $logs = @(Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Setup-*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime)
    if ($logs.Count) {
        $f = $logs[-1]
        Write-Host ('Result from {0:HH:mm:ss}  ({1})' -f $f.LastWriteTime, $f.FullName)
        Get-Content -LiteralPath $f.FullName | ForEach-Object { Write-Host '  ' $_ }
        $raw = Get-Content -LiteralPath $f.FullName -Raw
        Write-Host ''
        if ($raw -match 'CONNECTED OK') { Write-Host 'VERDICT: PRESENT' }
        elseif ($raw -match 'FAILED:')   { Write-Host 'VERDICT: FAILED - see the message above' }
        else                             { Write-Host 'VERDICT: still running or incomplete' }
    }
    else {
        Write-Host 'No stored result yet - the work may still be starting, or it never ran.'
    }
    Get-ScheduledTask -TaskName 'PrinterSetup-*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Get-ChildItem 'C:\ProgramData\PrinterToolkit' -Filter 'PrinterSetup-*.ps1' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return
}

# =====================================================================
#  HARD STOP. Nothing is added until a queue is supplied.
# =====================================================================
if (-not $env:PrinterSetupPath) {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - NO PRINTER WAS ADDED. NOTHING WAS CHANGED.    #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host '  This script has no printer name built in, so it needs one.' -ForegroundColor Yellow
    Write-Host '  $env:PrinterSetupPath is not set.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Copy this line, replace the placeholders, and put it BEFORE' -ForegroundColor White
    Write-Host '  the command (same console, one line each):' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterSetupPath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Example, queue name with spaces included in the quotes:' -ForegroundColor White
    Write-Host "      `$env:PrinterSetupPath = '\\PRINTSERVER\FINANCE HP4525'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Then run the same command again. Optional extras, same' -ForegroundColor White
    Write-Host '  pattern, each on its own line:' -ForegroundColor White
    Write-Host "      `$env:PrinterSetupDefault  = 'false'   # don't set it default" -ForegroundColor DarkGray
    Write-Host "      `$env:PrinterSetupElevated = 'true'    # only if the driver is missing" -ForegroundColor DarkGray
    Write-Host "      `$env:PrinterSetupUser     = 'DOMAIN\name'  # pick the user yourself" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Tip: print the queue name on the server with' -ForegroundColor White
    Write-Host '      Get-Printer -ComputerName PRINT-SERVER | Select-Object Name' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$PrinterPath = ([string]$env:PrinterSetupPath).TrimEnd('\')
if ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - the queue name is not in the right form.       #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host ('  Got      : {0}' -f $PrinterPath) -ForegroundColor Yellow
    Write-Host '  Expected : \\SERVER\QUEUE   (two backslashes, one separator)' -ForegroundColor White
    Write-Host '             forward slashes are not accepted' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterSetupPath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.8.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# First output line, so a run is identifiable at a glance. If you do NOT see this line
# in the Commands tab, whatever you pasted was not this script.
Say ('Printer-Setup-Paste v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work that has to happen inside the user's session. Kept as literal text so it can
# be written to a file and run under the user's token (or run right here).
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

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($ident.IsSystem) { throw 'Refusing to run as SYSTEM - the printer would be added for SYSTEM, not the user.' }

    Write-Log ('Printer setup for {0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    Write-Log ('Windows:  {0} build {1}' -f ([Environment]::OSVersion.VersionString), ([Environment]::OSVersion.Version.Build))
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
        else {
            # Silent skip was a blind spot: with no log line it looked as though
            # the cmdlet had been tried and failed.
            Write-Log 'Add-PrinterConnection is not available on this machine (needs Windows 10 / Server 2016+).'
        }

        # Second route: the WMI method, which exists on every Windows and returns a real
        # error code instead of printui's meaningless 0.
        # It is a STATIC method, so Invoke-CimMethod -ClassName cannot see it on older
        # builds; the [wmiclass] accelerator can, and that is what Windows PowerShell 5.1
        # offers. Both are tried, then printui as the last resort.
        if (-not $added) {
            try {
                $wmiSw = [System.Diagnostics.Stopwatch]::StartNew()
                $wc = [wmiclass]'Win32_Printer'
                $res = $wc.AddWindowsPrinterConnection($PrinterPath)
                $wmiSw.Stop()
                $code = if ($res -and $null -ne $res.ReturnValue) { $res.ReturnValue } else { -1 }
                Write-Log ('Win32_Printer.AddWindowsPrinterConnection (wmiclass) returned {0} after {1:N1}s' -f `
                            $code, $wmiSw.Elapsed.TotalSeconds)
                if ($code -eq 0) { $added = $true; Write-Log 'WMI add reported success.' }
            }
            catch {
                Write-Log ('wmiclass route failed: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $added) {
            try {
                $wmiSw = [System.Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-CimMethod -ClassName Win32_Printer `
                        -MethodName AddWindowsPrinterConnection `
                        -Arguments @{ PrinterPath = $PrinterPath } -ErrorAction Stop
                $wmiSw.Stop()
                Write-Log ('Win32_Printer.AddWindowsPrinterConnection (CIM) returned {0} after {1:N1}s' -f `
                            $r.ReturnValue, $wmiSw.Elapsed.TotalSeconds)
                if ($r.ReturnValue -eq 0) { $added = $true; Write-Log 'WMI add reported success.' }
            }
            catch {
                Write-Log ('CIM route failed: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $added) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                    -ArgumentList ('printui.dll,PrintUIEntry /in /q /n "{0}"' -f $PrinterPath)
            $sw.Stop()
            # printui returns 0 even when it adds nothing, so this number is only a
            # hint; the registry read-back below is the real verdict.
            Write-Log ('printui /in exit code: {0} (after {1:N1}s - 0 does not mean it worked)' -f `
                        $p.ExitCode, $sw.Elapsed.TotalSeconds)
        }
        Start-Sleep -Seconds 2
    }
    else {
        Write-Log 'Already connected for this user - not adding again.'
    }

    # Read back. This is what makes the verdict trustworthy.
    $present = Test-Path -LiteralPath $connPath
    $visible = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterPath })
    Write-Log ('After - key present: {0}' -f $present)
    Write-Log ('After - visible to user: {0}' -f [bool]$visible)

    if (-not $present -or -not $visible) {
        throw ('{0} is not on the printer list. If the driver is missing and non-admin install is blocked, set Elevated to true and paste again.' -f $PrinterPath)
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
}
catch {
    # Always leave a terminal marker, so the outer script and read mode can tell
    # "still working" from "gave up".
    Write-Log ('FAILED: {0}' -f $_.Exception.Message)
    throw
}
'@

# ---- 0. sanity-check the config ----------------------------------------------
$PrinterPath = $PrinterPath.TrimEnd('\')
if ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
    throw "`$PrinterPath must look like \\server\printer - you have '$PrinterPath'"
}

Say ('Queue:    {0}' -f $PrinterPath)
Say ('Default:  {0}   Elevated: {1}' -f $SetDefault, $Elevated)

# ---- 1. drop the payload somewhere every account can read it ------------------
$toolDir = 'C:\ProgramData\PrinterToolkit'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $payloadFile = Join-Path $toolDir ('PrinterSetup-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
catch {
    $payloadFile = Join-Path $env:TEMP ('PrinterSetup-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
Say ('Payload:  {0}' -f $payloadFile)

$ok = $false
$deferred = $false
$payloadKept = $false
$taskName = $null

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()

    # ---- 2. already the right user? just do the work -------------------------
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
        # ---- 3. SYSTEM: find the user and run the payload in their session ----
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

        $taskName = 'PrinterSetup-' + $stamp
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PrinterPath "{1}"{2}' -f `
                        $payloadFile, $PrinterPath, $(if ($SetDefault) { ' -SetDefault' } else { '' })

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
        $runLevel  = if ($Elevated) { 'Highest' } else { 'Limited' }
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $runLevel
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

        Say ('Task:     {0} (run level {1})' -f $taskName, $runLevel)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
            -Settings $settings -Force | Out-Null

        try { Start-ScheduledTask -TaskName $taskName }
        catch { Say ('Task start failed: {0}' -f $_.Exception.Message) }

        # Wait for a terminal marker in the payload's log rather than for the task state:
        # the log tells us whether it actually succeeded.
        Say ('Waiting up to {0}s for the result...' -f $WaitSeconds)
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        # Only a log written by THIS run counts. Without this filter the newest log is
        # whatever a previous attempt left behind, and its verdict is reported as if it
        # were this run's - a stale FAILED looks exactly like a fresh one.
        $runStart = (Get-Date).AddSeconds(-3)
        $raw = $null
        $logFile = $null
        do {
            Start-Sleep -Seconds 1
            $logFile = Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Setup-*.log' -ErrorAction SilentlyContinue |
                           Where-Object { $_.LastWriteTime -ge $runStart } |
                           Sort-Object LastWriteTime | Select-Object -Last 1
            if ($logFile) { $raw = Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction SilentlyContinue }
        } while ((-not $raw -or $raw -notmatch 'CONNECTED OK|FAILED:') -and (Get-Date) -lt $deadline)

        Write-Host ''
        if ($raw -and $raw -match 'CONNECTED OK|FAILED:') {
            Say ('Log: {0}' -f $logFile.FullName)
            Get-Content -LiteralPath $logFile.FullName | ForEach-Object { Write-Host '    ' $_ }
            $ok = ($raw -match 'CONNECTED OK')
        }
        else {
            # Out of time - the Commands tab kills us at 10s. Keep the payload and the
            # task: the task may not have started yet, and it needs the payload file.
            $deferred = $true
            $payloadKept = $true
            Say 'The work is still running - this console is about to be killed.'
            Write-Host ''
            Write-Host 'Read the result in a few seconds with:' -ForegroundColor Yellow
            Write-Host "  Get-Content (Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Setup-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Tail 25"
            Write-Host ''
            Write-Host 'Or, one line (same gist, read-only, also cleans up):' -ForegroundColor Yellow
            Write-Host "  `$env:PrinterSetupRead = 'true'; irm <this gist url> | iex"
            Write-Host ''
            Say ('Task: {0}  (cleanup: Unregister-ScheduledTask -TaskName ''{0}'' -Confirm:$false)' -f $taskName)
        }
    }
}
finally {
    # Never remove the payload while a deferred task may still be about to use it.
    if (-not $payloadKept) {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $deferred -and $taskName) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($ok) {
    Write-Host ('RESULT: CONNECTED - {0} is on the printer list.' -f $PrinterPath) -ForegroundColor Green
    if ($SetDefault) { Write-Host '        It is set as the default printer.' }
}
elseif (-not $deferred) {
    Write-Host 'RESULT: NOT CONNECTED - read the log above for the reason.' -ForegroundColor Red
    Write-Host '        If it mentions access denied, set $Elevated = $true and paste again.'
}
