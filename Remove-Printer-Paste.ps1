#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      REMOVE PRINTER - remove a network printer connection from the
      logged-on user. Paste the whole thing into PowerShell.
    ================================================================

      The companion to Printer-Setup-Paste.ps1. Use it to remove a
      printer the user no longer needs, or to clear a half-installed
      connection (Printer-Check.ps1 VERDICT: PARTIAL) before adding it
      again cleanly.

      NOTHING IS BUILT IN. It will not run until you set
      $env:PrinterRemovePath - it prints exactly what to type. Removing
      a connection is per-user data, so a SYSTEM shell bridges into the
      logged-on user's session automatically.

      Optional:
        $env:PrinterRemoveUser = 'DOMAIN\name'   # pick the user yourself
        $env:PrinterRemoveRead = 'true'          # print the last result and stop

      The hashbang lines at the top must stay contiguous - a blank line
      between them and ScreenConnect keeps its 10-second kill.
    ================================================================
#>

$User        = ''
$WaitSeconds = 25
if ($env:PrinterRemoveUser) { $User        = $env:PrinterRemoveUser }
if ($env:PrinterRemoveWait) { $WaitSeconds = [int]$env:PrinterRemoveWait }

# Read mode: print the newest stored result and stop. Safe to repeat.
if ($env:PrinterRemoveRead) {
    $logs = @(Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Remove-*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime)
    if ($logs.Count) {
        $f = $logs[-1]
        Write-Host ('Result from {0:HH:mm:ss}  ({1})' -f $f.LastWriteTime, $f.FullName)
        Get-Content -LiteralPath $f.FullName | ForEach-Object { Write-Host '  ' $_ }
        $raw = Get-Content -LiteralPath $f.FullName -Raw
        Write-Host ''
        if ($raw -match 'REMOVED OK')  { Write-Host 'VERDICT: REMOVED' }
        elseif ($raw -match 'FAILED:')  { Write-Host 'VERDICT: FAILED - see the message above' }
        else                            { Write-Host 'VERDICT: still running or incomplete' }
    }
    else { Write-Host 'No stored result yet - the work may still be starting, or it never ran.' }
    Get-ScheduledTask -TaskName 'PrinterRemove-*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    return
}

if (-not $env:PrinterRemovePath) {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - NO PRINTER WAS REMOVED. NOTHING WAS CHANGED.  #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host '  This script has no printer name built in, so it needs one.' -ForegroundColor Yellow
    Write-Host '  $env:PrinterRemovePath is not set.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Copy this line, replace the placeholders, and put it BEFORE' -ForegroundColor White
    Write-Host '  the command (same console, one line each):' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterRemovePath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Then run the same command again. Optional:' -ForegroundColor White
    Write-Host "      `$env:PrinterRemoveUser = 'DOMAIN\name'   # pick the user yourself" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Tip: list what the user has first with Printer-Check.ps1.' -ForegroundColor White
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$PrinterPath = ([string]$env:PrinterRemovePath).TrimEnd('\')
if ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - the queue name is not in the right form.       #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host ('  Got      : {0}' -f $PrinterPath) -ForegroundColor Yellow
    Write-Host '  Expected : \\SERVER\QUEUE   (two backslashes, one separator)' -ForegroundColor White
    Write-Host ''
    Write-Host "      `$env:PrinterRemovePath = '\\PRINT-SERVER\QUEUE-NAME'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    return
}

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Remove-Printer-Paste v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

$PayloadText = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PrinterPath)
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'PrinterToolkit'
$null = New-Item -ItemType Directory -Path $logDir -Force
$logFile = Join-Path $logDir ('Remove-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Write-Log { param([string]$m) $line = '{0}  {1}' -f (Get-Date -Format 's'), $m; Add-Content -LiteralPath $logFile -Value $line; Write-Output $line }

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($ident.IsSystem) { throw 'Refusing to run as SYSTEM - that would act on SYSTEM''s printers, not the user''s.' }

    Write-Log ('Remove printer for {0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
    Write-Log ('Identity: {0}' -f $ident.Name)
    Write-Log ('Queue:    {0}' -f $PrinterPath)

    $parts = $PrinterPath.TrimEnd('\').TrimStart('\').Split('\')
    $connPath = 'HKCU:\Printers\Connections\,,' + ($parts -join ',')
    $before = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterPath })
    Write-Log ('Before - visible to user: {0}' -f [bool]$before)
    Write-Log ('Before - connection key: {0}' -f (Test-Path -LiteralPath $connPath))

    if (-not $before -and -not (Test-Path -LiteralPath $connPath)) {
        Write-Log 'Nothing to remove - this printer is not present for the user.'
        Write-Log 'REMOVED OK'
        return
    }

    $done = $false
    if (Get-Command Remove-PrinterConnection -ErrorAction SilentlyContinue) {
        try {
            Remove-PrinterConnection -Name $PrinterPath -ErrorAction Stop
            Write-Log 'Remove-PrinterConnection succeeded.'
            $done = $true
        }
        catch {
            Write-Log ('Remove-PrinterConnection failed: {0}' -f $_.Exception.Message)
            Write-Log 'Trying printui.dll /dn instead.'
        }
    }
    # /dn also clears a stale connection key when the printer is not visible.
    $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
            -ArgumentList ('printui.dll,PrintUIEntry /dn /q /n "{0}"' -f $PrinterPath)
    Write-Log ('printui /dn exit code: {0}' -f $p.ExitCode)
    Start-Sleep -Seconds 1

    $afterKey = Test-Path -LiteralPath $connPath
    $afterVis = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $PrinterPath })
    Write-Log ('After - connection key: {0}' -f $afterKey)
    Write-Log ('After - visible to user: {0}' -f [bool]$afterVis)

    if ($afterKey -or $afterVis) {
        throw ('{0} is still present for {1} after the remove.' -f $PrinterPath, $env:USERNAME)
    }
    Write-Log 'REMOVED OK'
}
catch {
    Write-Log ('FAILED: {0}' -f $_.Exception.Message)
    throw
}
'@

$toolDir = 'C:\ProgramData\PrinterToolkit'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $payloadFile = Join-Path $toolDir ('PrinterRemove-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
catch {
    $payloadFile = Join-Path $env:TEMP ('PrinterRemove-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $payloadFile -Value $PayloadText -Encoding UTF8
}
Say ('Payload:  {0}' -f $payloadFile)
Say ('Queue:    {0}' -f $PrinterPath)

$ok = $false
$deferred = $false
$payloadKept = $false
$taskName = $null

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $ident.IsSystem) {
        Say ('Running as {0} - removing directly.' -f $ident.Name)
        try {
            & $payloadFile -PrinterPath $PrinterPath | ForEach-Object { Write-Host '    ' $_ }
            $ok = $true
        }
        catch { Say ('Payload reported: {0}' -f $_.Exception.Message) }
    }
    else {
        $users = @(
            Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
                Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
                Select-Object -ExpandProperty UserName -Unique
        )
        if ($users.Count -eq 0) { throw 'Nobody is logged on. A printer connection belongs to a user session.' }
        if (-not $User) {
            if ($users.Count -gt 1) {
                throw ("More than one user is logged on: {0}. Set `$env:PrinterRemoveUser = 'DOMAIN\name'." -f ($users -join ', '))
            }
            $User = $users[0]
        }
        elseif ($users -notcontains $User) {
            throw ('{0} has no session. Logged on: {1}' -f $User, ($users -join ', '))
        }
        Say ('SYSTEM shell - bridging into {0}' -f $User)

        $taskName = 'PrinterRemove-' + $stamp
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PrinterPath "{1}"' -f $payloadFile, $PrinterPath
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
            -Settings $settings -Force | Out-Null

        Say ('Waiting up to {0}s for the result...' -f $WaitSeconds)
        Write-Host '  If this console is killed first, read the result with:' -ForegroundColor DarkGray
        Write-Host "    `$env:PrinterRemoveRead = 'true'; irm <this gist url> | iex" -ForegroundColor DarkGray
        Write-Host ''
        $runStart = (Get-Date).AddSeconds(-3)
        $raw = $null
        $logFile = $null
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        try {
            Start-ScheduledTask -TaskName $taskName
            do {
                Start-Sleep -Seconds 1
                $logFile = Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Remove-*.log' -ErrorAction SilentlyContinue |
                               Where-Object { $_.LastWriteTime -ge $runStart } |
                               Sort-Object LastWriteTime | Select-Object -Last 1
                if ($logFile) { $raw = Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction SilentlyContinue }
            } while ((-not $raw -or $raw -notmatch 'REMOVED OK|FAILED:') -and (Get-Date) -lt $deadline)
        }
        catch { Say ('Task start failed: {0}' -f $_.Exception.Message) }

        Write-Host ''
        if ($raw -and $raw -match 'REMOVED OK|FAILED:') {
            Say ('Log: {0}' -f $logFile.FullName)
            Get-Content -LiteralPath $logFile.FullName | ForEach-Object { Write-Host '    ' $_ }
            $ok = ($raw -match 'REMOVED OK')
        }
        else {
            $deferred = $true
            $payloadKept = $true
            Say 'Still running - this console is about to be killed.'
            Write-Host "  `$env:PrinterRemoveRead = 'true'; irm <this gist url> | iex" -ForegroundColor Yellow
            Say ('Task: {0}  (cleanup: Unregister-ScheduledTask -TaskName ''{0}'' -Confirm:$false)' -f $taskName)
        }
    }
}
finally {
    if (-not $payloadKept) { Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue }
    if (-not $deferred -and $taskName) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($ok) {
    Write-Host ('RESULT: REMOVED - {0} is no longer on the user''s printer list.' -f $PrinterPath) -ForegroundColor Green
}
elseif (-not $deferred) {
    Write-Host 'RESULT: NOT REMOVED - read the log above for the reason.' -ForegroundColor Red
}
