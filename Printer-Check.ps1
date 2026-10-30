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

      IMPORTANT - the ScreenConnect Commands tab kills a command after
      10 SECONDS. This script therefore never waits longer than ~4s. If
      the probe has not finished by then it prints the exact one-liner
      to read the result a few seconds later. Nothing is lost: the probe
      writes its output to a file inside the user's session.

      The lines at the top are ScreenConnect hashbang modifiers. They MUST
      be contiguous on the first lines - a blank line between them and
      only the first one is applied, which silently leaves the 10-second
      kill in place. Confirmed on 26.7.6.9783: pasted as-is, #timeout
      works and the script may wait; pasted with a blank line or without
      the timeout line, the console dies at 10s, which is why the
      fallback instructions are printed before the wait, not after.

      Works pasted into the Commands tab, Backstage, or a user window.
    ================================================================
#>

# =====================================================================
#  SETTINGS - taken from ENVIRONMENT VARIABLES ONLY.
#  There is no printer name anywhere in this file, on purpose: nothing
#  here is specific to one site, and nothing has to be edited.
# =====================================================================
$User        = ''                               # blank = whoever is logged on
$WaitSeconds = 25                               # needs #timeout in the Commands tab

if ($env:PrinterCheckUser) { $User        = $env:PrinterCheckUser }
if ($env:PrinterCheckWait) { $WaitSeconds = [int]$env:PrinterCheckWait }

# Read mode: print the newest stored result and stop. Safe to run repeatedly.
if ($env:PrinterCheckRead) {
    $f = Get-ChildItem 'C:\Users\*\AppData\Local\Temp\PrinterCheck-*.txt' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime | Select-Object -Last 1
    if ($f) {
        Write-Host ('Result from {0:HH:mm:ss}:' -f $f.LastWriteTime)
        Get-Content -LiteralPath $f.FullName | Where-Object { $_ -notmatch 'END-OF-REPORT' }
        Write-Host ('(file: {0})' -f $f.FullName)
    }
    else { Write-Host 'No stored result yet - the probe may still be starting.' }
    Get-ScheduledTask -TaskName 'PrinterCheck-*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    return
}

# =====================================================================
#  HARD STOP. This script will not run without a queue to look for.
#  Assigning $null or '' to an env var DELETES it in PowerShell, so the
#  word 'list' is the supported way to say "no queue, just show me the
#  printers".
# =====================================================================
if ($null -eq $env:PrinterCheckPath) {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - NOTHING WAS CHECKED. NOTHING WAS CHANGED.     #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host '  This script has no printer name built in, so it needs one.' -ForegroundColor Yellow
    Write-Host '  $env:PrinterCheckPath is not set.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Copy this line, replace the placeholders, and put it BEFORE' -ForegroundColor White
    Write-Host '  the command (same console, one line each):' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterCheckPath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Example:' -ForegroundColor White
    Write-Host "      `$env:PrinterCheckPath = '\\PRINTSERVER\FINANCE-HP4525'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  To list every printer without checking a specific queue:' -ForegroundColor White
    Write-Host "      `$env:PrinterCheckPath = 'list'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Then run the same command again.' -ForegroundColor White
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$PrinterPath = [string]$env:PrinterCheckPath
if ($PrinterPath -eq 'list') { $PrinterPath = '' }
elseif ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - the queue name is not in the right form.       #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host ('  Got      : {0}' -f $PrinterPath) -ForegroundColor Yellow
    Write-Host '  Expected : \\SERVER\QUEUE   (two backslashes, one separator)' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterCheckPath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.4.0'

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

Write-Line 'END-OF-REPORT'
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

$deferred = $false
$taskName = $null
$payloadKept = $false

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

        # A task's console output cannot be read from here, so the probe writes a
        # file in the user's own temp folder and we read that afterwards.
        $outFile  = '{0}\AppData\Local\Temp\PrinterCheck-{1}.txt' -f $profileDir, $stamp
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
        $task = $null; $info = $null
        # Print the fallback BEFORE waiting. If the console is killed mid-wait the
        # tail of the output is lost, so the instructions have to come first.
        Say ('Waiting up to {0}s for the probe...' -f $WaitSeconds)
        Write-Host '  If this console is killed before that, read the result with:' -ForegroundColor DarkGray
        Write-Host "    `$f = Get-ChildItem 'C:\Users\*\AppData\Local\Temp\PrinterCheck-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1; if (`$f) { Get-Content `$f.FullName } else { 'still running' }" -ForegroundColor DarkGray
        Write-Host ''
        try {
            Start-ScheduledTask -TaskName $taskName
            $deadline = (Get-Date).AddSeconds($WaitSeconds)
            # Wait for the END-OF-REPORT marker, not merely for the file to exist: the
            # probe creates it on its first line, so testing existence alone reads a
            # half-written report and prints a truncated printer list.
            $raw = ''
            while ($raw -notmatch 'END-OF-REPORT' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                if (Test-Path -LiteralPath $outFile) {
                    $raw = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
                    if (-not $raw) { $raw = '' }
                }
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
                # LastRunTime is truncated to whole seconds by Windows, hence the slack.
                if ($task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -ge $notBefore) {
                    Start-Sleep -Milliseconds 300   # let the file flush
                    break
                }
            }
        }
        catch {
            Say ('Task start failed: {0}' -f $_.Exception.Message)
        }

        Write-Host ''
        if (Test-Path -LiteralPath $outFile) {
            Get-Content -LiteralPath $outFile |
                Where-Object { $_ -notmatch 'END-OF-REPORT' } |
                ForEach-Object { Write-Host $_ }
            Say ('Result kept at {0}' -f $outFile)
        }
        else {
            # Out of time (the Commands tab kills at 10s). Do NOT delete the probe
            # or the task: the task may not have started yet.
            $deferred = $true
            $payloadKept = $true
            Say 'Probe is still running - this console is about to be killed.'
            Write-Host ''
            Write-Host 'Run this in a few seconds to read the result:' -ForegroundColor Yellow
            Write-Host ''
            Write-Host "  `$f = Get-ChildItem 'C:\Users\*\AppData\Local\Temp\PrinterCheck-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1"
            Write-Host "  if (`$f) { Get-Content `$f.FullName } else { 'still running' }"
            Write-Host ''
            Write-Host 'Or, one line:' -ForegroundColor Yellow
            Write-Host "  `$env:PrinterCheckRead = 'true'; irm <this gist url> | iex"
            Write-Host ''
            Say ('Task: {0}  (cleanup: Unregister-ScheduledTask -TaskName ''{0}'' -Confirm:$false)' -f $taskName)
        }
    }
}
finally {
    # Never remove the probe while a deferred task may still be about to use it.
    if (-not $payloadKept) {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $deferred -and $taskName) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
