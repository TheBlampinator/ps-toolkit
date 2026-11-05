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
$scriptVersion = '2.6.0'

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

    # Predict the driver-consent prompt instead of discovering it 36 seconds later.
    # If the queue needs a driver this machine does not have, Windows asks permission to
    # install it - and that ask is what fails when nobody is there to click Install.
    try {
        $srvLeaf = $PrinterPath.TrimStart('\').Split('\')
        $remote  = Get-Printer -ComputerName $srvLeaf[0] -Name $srvLeaf[1] -ErrorAction Stop
        $localDrivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $haveIt = $localDrivers -contains $remote.DriverName
        Write-Log ('Driver needed:    {0}' -f $remote.DriverName)
        Write-Log ('Driver installed: {0}' -f $haveIt)
        if (-not $haveIt) {
            Write-Log 'The SYSTEM step could not install that driver from the print server.'
            Write-Log 'Windows will install it during the connection; the SYSTEM step switched off'
            Write-Log 'the Point and Print prompts for this server, so it should still be silent.'
            Write-Log 'If this fails with 0x800704C7, the prompt appeared anyway - read the console output.'
        }
    }
    catch {
        Write-Log ('Could not compare drivers: {0}' -f $_.Exception.Message)
    }

    if (-not $existing) {
        $added = $false
        Write-Log 'Route 1: Add-PrinterConnection'
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
            Write-Log 'Route 2: wmiclass Win32_Printer'
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

        # Route 2b: Add-Printer -ConnectionName. Survives on builds where
        # Add-PrinterConnection has been removed (Windows 11 24H2+ dropped it while
        # keeping the rest of the PrintManagement module).
        if (-not $added) {
            Write-Log 'Route 3: Add-Printer -ConnectionName'
            if (Get-Command Add-Printer -ErrorAction SilentlyContinue) {
                try {
                    $apSw = [System.Diagnostics.Stopwatch]::StartNew()
                    Add-Printer -ConnectionName $PrinterPath -ErrorAction Stop
                    $apSw.Stop()
                    Write-Log ('Add-Printer -ConnectionName completed after {0:N1}s' -f $apSw.Elapsed.TotalSeconds)
                    $added = $true
                }
                catch {
                    Write-Log ('Add-Printer -ConnectionName failed: {0}' -f $_.Exception.Message)
                }
            }
        }

        # Third route: WScript.Network COM. No WMI and no PrintManagement module - it
        # calls the same Win32 print API the Add Printer wizard uses, throws on failure,
        # and exists on every Windows back to XP. This machine has neither the cmdlet nor
        # the Win32_Printer static method, so it is the most likely remaining path.
        if (-not $added) {
            Write-Log 'Route 4: WScript.Network COM'
            $net = $null
            try {
                $comSw = [System.Diagnostics.Stopwatch]::StartNew()
                $net = New-Object -ComObject WScript.Network
                $net.AddWindowsPrinterConnection($PrinterPath)
                $comSw.Stop()
                Write-Log ('WScript.Network.AddWindowsPrinterConnection completed after {0:N1}s' -f $comSw.Elapsed.TotalSeconds)
                $added = $true
            }
            catch {
                Write-Log ('COM route failed: {0}' -f $_.Exception.Message)
            }
            finally {
                if ($net) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($net) } catch { } }
            }
        }

        if (-not $added) {
            Write-Log 'Route 5: printui.dll'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait -WindowStyle Hidden `
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
        throw ('{0} is not on the printer list. If a driver consent dialog was cancelled (0x800704C7), the printer''s driver is not installed and Windows asked for permission - sign in at the machine and click Install, or have the driver pre-installed. Otherwise set Elevated to true and paste again.' -f $PrinterPath)
    }

    if ($SetDefault) {
        $target = $visible | Select-Object -First 1
        try {
            Invoke-CimMethod -InputObject $target -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
            Write-Log 'SetDefaultPrinter invoked.'
        }
        catch {
            $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait -WindowStyle Hidden `
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
# =====================================================================
#  OPTIONAL: install the printer's driver MACHINE-WIDE before connecting.
#
#  Windows 11 24H2+ asks for consent to install a driver the machine does
#  not have, and a background run cannot answer that dialog - which is why
#  every unattended add fails with 0x800704C7 when the driver is new.
#  Installing it here, as SYSTEM, removes the prompt entirely: by the time
#  the connection is attempted the driver already exists, so no dialog and
#  no user contact are needed.
#
#  Where it looks, in order:
#    $env:PrinterSetupDriverSource      a folder or a single .inf
#    C:\ProgramData\PrinterToolkit\drivers   (default drop folder)
#  Anything with .inf in it is installed. Quiet when there is nothing to do.
# =====================================================================
$DriverSource = $env:PrinterSetupDriverSource
if (-not $DriverSource) {
    $auto = Join-Path 'C:\ProgramData\PrinterToolkit' 'drivers'
    if (Test-Path -LiteralPath $auto) { $DriverSource = $auto }
}

if ($DriverSource -and (Test-Path -LiteralPath $DriverSource)) {
    $infFiles = @()
    if ((Get-Item -LiteralPath $DriverSource -ErrorAction SilentlyContinue).PSIsContainer) {
        $infFiles = @(Get-ChildItem -LiteralPath $DriverSource -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    }
    else { $infFiles = @(Get-Item -LiteralPath $DriverSource) }

    # The model name Windows uses for a connection is the server's DriverName.
    $modelName = $null
    try {
        $sp = $PrinterPath.TrimStart('\').Split('\')
        $modelName = (Get-Printer -ComputerName $sp[0] -Name $sp[1] -ErrorAction Stop).DriverName
    }
    catch { }

    $installedAlready = $false
    if ($modelName) {
        $installedAlready = @(Get-PrinterDriver -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq $modelName }).Count -gt 0
    }

    if ($installedAlready) {
        Write-Host ('  Driver already present: {0}' -f $modelName) -ForegroundColor DarkGray
    }
    elseif (-not $infFiles.Count) {
        Write-Host ('  No .inf file found in {0}' -f $DriverSource) -ForegroundColor Yellow
    }
    else {
        foreach ($inf in $infFiles) {
            Write-Host ('  Installing driver from {0}' -f $inf.Name) -ForegroundColor DarkGray
            $rdArgs = @('printui.dll,PrintUIEntry', '/ia', '/q')
            if ($modelName) { $rdArgs += @('/m', $modelName) }
            $rdArgs += @('/f', $inf.FullName)
            try {
                $drvProc = Start-Process -FilePath 'rundll32.exe' -ArgumentList $rdArgs `
                              -Wait -PassThru -WindowStyle Hidden
                Write-Host ('    printui /ia exit code: {0}' -f $drvProc.ExitCode) -ForegroundColor DarkGray
            }
            catch {
                Write-Host ('    driver install failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds 2
        if ($modelName) {
            $nowInstalled = @(Get-PrinterDriver -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq $modelName }).Count -gt 0
            if ($nowInstalled) { Write-Host ('  Driver installed: {0}' -f $modelName) -ForegroundColor Green }
            else { Write-Host ('  Driver still missing after install attempt: {0}' -f $modelName) -ForegroundColor Yellow
                   Write-Host '  The .inf may not contain that model name, or the package is for another architecture.' -ForegroundColor Yellow }
        }
    }
}

# Install the queue's driver machine-wide straight from the print server, with no
# dialog. Package-aware drivers (nearly every modern one) are published in
# \\SERVER\print$\<arch>\PCC as one .cab per driver package, named after the
# package's DriverStore folder - which the server reports as the driver's InfPath.
# pnputil stages that package; Add-PrinterDriver then registers the printer driver.
# Both steps are needed: pnputil alone only fills the DriverStore, and the spooler
# does not list the driver (so Windows still prompts) until Add-PrinterDriver runs.
function Install-DriverFromPrintShare {
    param([string]$Server, [string]$DriverName)

    $isArm = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
    $arch  = if ($isArm) { 'ARM64' } else { 'x64' }
    $penv  = if ($isArm) { 'Windows ARM64' } else { 'Windows x64' }
    $pcc   = "\\$Server\print`$\$arch\PCC"

    $srvInf = $null
    try {
        $srvInf = @(Get-PrinterDriver -ComputerName $Server -Name $DriverName -PrinterEnvironment $penv -ErrorAction Stop)[0].InfPath
    }
    catch {
        Write-Host ('  Could not read the driver details from {0}: {1}' -f $Server, $_.Exception.Message) -ForegroundColor DarkGray
    }
    if (-not $srvInf) {
        Write-Host ('  The server reports no driver package for {0} ({1}).' -f $DriverName, $penv) -ForegroundColor Yellow
        return $false
    }
    if (-not (Test-Path -LiteralPath $pcc)) {
        Write-Host ('  Driver package share not readable: {0}' -f $pcc) -ForegroundColor Yellow
        return $false
    }

    $pkgFolder = Split-Path -Leaf (Split-Path -Parent $srvInf)    # e.g. brprl19a.inf_amd64_0123abcd
    $infLeaf   = Split-Path -Leaf $srvInf                         # e.g. brprl19a.inf
    $cab = $null
    $exact = Join-Path $pcc ($pkgFolder + '.cab')
    if (Test-Path -LiteralPath $exact) { $cab = Get-Item -LiteralPath $exact }
    else {
        $cab = Get-ChildItem -LiteralPath $pcc -Filter ($infLeaf + '_*.cab') -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime | Select-Object -Last 1
    }
    if (-not $cab) {
        Write-Host ('  No package for {0} in {1} - the server driver is not package-aware.' -f $infLeaf, $pcc) -ForegroundColor Yellow
        return $false
    }

    # Unpack into a folder only SYSTEM and Administrators can write to, so nothing
    # can be slipped in between unpacking and installing.
    $stage = Join-Path $env:windir ('Temp\PrinterToolkit-{0}' -f [guid]::NewGuid().ToString('N'))
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier $sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }

    try {
        $null = [IO.Directory]::CreateDirectory($stage, $acl)
        Write-Host ('  Unpacking {0} from the print server ...' -f $cab.Name) -ForegroundColor DarkGray
        $null = & expand.exe -F:* $cab.FullName $stage 2>&1

        $infs = @(Get-ChildItem -LiteralPath $stage -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
        $inf = @(@($infs | Where-Object { $_.Name -eq $infLeaf }) + $infs) | Select-Object -First 1
        if (-not $inf) {
            Write-Host ('  No .inf inside {0}.' -f $cab.Name) -ForegroundColor Yellow
            return $false
        }

        $null = & pnputil.exe /add-driver $inf.FullName 2>&1
        Write-Host ('  pnputil /add-driver {0} exit code: {1}' -f $inf.Name, $LASTEXITCODE) -ForegroundColor DarkGray

        try { Add-PrinterDriver -Name $DriverName -ErrorAction Stop }
        catch {
            try { Add-PrinterDriver -Name $DriverName -InfPath $inf.FullName -ErrorAction Stop }
            catch { Write-Host ('  Add-PrinterDriver failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
        }
        return (@(Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $DriverName }).Count -gt 0)
    }
    catch {
        Write-Host ('  Installing from the print server failed: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
#  LAST RESORT: let Point and Print install the driver - SILENTLY.
#
#  Reached only when the driver could not be installed above (the server's
#  driver is not package-aware, or its print$ share is not readable).
#  Windows then installs it during the connection, as the user, and three
#  values decide whether that shows a dialog:
#    RestrictDriverInstallationToAdministrators = 0   non-admins may install
#    NoWarningNoElevationOnInstall              = 1   no "Install driver?" prompt
#    UpdatePromptSettings                       = 2   no prompt for an update
#  Setting only the first (as v2.5 and earlier did) still shows the prompt,
#  and an unattended run fails with 0x800704C7 because nobody clicks it.
#  TrustedServers + ServerList limit this to the one print server.
#
#  Every value is put back exactly as it was: by the finally block when the
#  result arrives in time, otherwise by a one-shot SYSTEM task that waits
#  for the user-session log (max 20 min). So the policy is restored even if
#  this console is killed before the connection finishes.
#
#  Skipped entirely when the driver is already installed.
# =====================================================================
$script:PolicyPath     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
$script:PolicySaved    = $null     # name -> @{ Value; Kind }, or $null where the value did not exist
$script:PolicyKeyNew   = $false
$script:PolicyRestore  = $null     # PowerShell text that puts every value back
$script:PolicyWatchdog = $null

function ConvertTo-PsLiteral {
    param($Value)
    if ($Value -is [array]) { return '@(' + ((@($Value) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') + ')' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32]) { return [string]$Value }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Open-SilentPointAndPrint {
    param([string]$Server)

    # Only create the key when it is missing: New-Item -Force on an EXISTING registry
    # key deletes and recreates it, wiping every value a GPO put there.
    $script:PolicyKeyNew = -not (Test-Path -LiteralPath $script:PolicyPath)
    if ($script:PolicyKeyNew) { $null = New-Item -Path $script:PolicyPath -Force }
    $key = Get-Item -LiteralPath $script:PolicyPath

    # Keep any servers a GPO already trusts; just add this one.
    $servers = @()
    if ($key.GetValue('TrustedServers', 0) -eq 1) {
        $servers = @(([string]$key.GetValue('ServerList', '')).Split(';') | Where-Object { $_ })
    }
    if ($servers -notcontains $Server) { $servers += $Server }

    $want = [ordered]@{
        RestrictDriverInstallationToAdministrators = @(0, 'DWord')
        NoWarningNoElevationOnInstall              = @(1, 'DWord')
        UpdatePromptSettings                       = @(2, 'DWord')
        TrustedServers                             = @(1, 'DWord')
        ServerList                                 = @(($servers -join ';'), 'String')
    }

    $saved = [ordered]@{}
    foreach ($name in $want.Keys) {
        if ($key.GetValueNames() -contains $name) {
            $saved[$name] = @{ Value = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
                               Kind  = [string]$key.GetValueKind($name) }
        }
        else { $saved[$name] = $null }
    }
    $script:PolicySaved = $saved

    $lines = @("`$p = '{0}'" -f $script:PolicyPath)
    foreach ($name in $saved.Keys) {
        $s = $saved[$name]
        if ($null -eq $s) {
            $lines += "Remove-ItemProperty -LiteralPath `$p -Name '$name' -ErrorAction SilentlyContinue"
        }
        else {
            $lines += "Set-ItemProperty -LiteralPath `$p -Name '$name' -Value $(ConvertTo-PsLiteral $s.Value) -Type $($s.Kind) -Force"
        }
    }
    if ($script:PolicyKeyNew) {
        $lines += "if (-not @((Get-Item -LiteralPath `$p).GetValueNames()).Count) { Remove-Item -LiteralPath `$p -Force }"
    }
    $script:PolicyRestore = $lines -join "`r`n"

    # Arm the watchdog BEFORE opening the gate, so there is never a moment where
    # the policy is open with nothing scheduled to close it.
    $since = (Get-Date).AddSeconds(-3).Ticks
    $taskName = 'PrinterSetup-RestorePolicy-' + $stamp
    $watch = @"
`$since = New-Object DateTime $since
`$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt `$deadline) {
    `$done = Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Setup-*.log' -ErrorAction SilentlyContinue |
                Where-Object { `$_.LastWriteTime -ge `$since } |
                Where-Object { (Get-Content -LiteralPath `$_.FullName -Raw -ErrorAction SilentlyContinue) -match 'CONNECTED OK|FAILED:' }
    if (`$done) { break }
    Start-Sleep -Seconds 5
}
$($script:PolicyRestore)
Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watch))
    try {
        $wAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                          -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {0}' -f $enc)
        $wPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $wSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                          -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $taskName -Action $wAction -Principal $wPrincipal `
            -Settings $wSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $script:PolicyWatchdog = $taskName
    }
    catch {
        Write-Host ('  Could not schedule the policy restore task: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    foreach ($name in $want.Keys) {
        Set-ItemProperty -LiteralPath $script:PolicyPath -Name $name -Value $want[$name][0] -Type $want[$name][1] -Force
    }
}

$queueDriver = $null
try {
    $qp = $PrinterPath.TrimStart('\').Split('\')
    $queueDriver = (Get-Printer -ComputerName $qp[0] -Name $qp[1] -ErrorAction Stop).DriverName
}
catch {
    Write-Host ('  Could not ask the server for the driver name: {0}' -f $_.Exception.Message) -ForegroundColor DarkGray
}

if ($queueDriver) {
    $haveDriver = @(Get-PrinterDriver -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq $queueDriver }).Count -gt 0

    if ($haveDriver) {
        Write-Host ('  Driver already present: {0}' -f $queueDriver) -ForegroundColor DarkGray
    }
    else {
        $isAdminish = $false
        try {
            $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
            $isAdminish = $wi.IsSystem -or (New-Object Security.Principal.WindowsPrincipal($wi)).IsInRole(
                            [Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { $isAdminish = $false }

        if (-not $isAdminish) {
            Write-Host '  Driver missing and this shell is not elevated - it can only be installed by the user, which is not possible unattended.' -ForegroundColor Yellow
        }
        else {
            # Attempt 1: install it ourselves from the print server's print$ share.
            Write-Host ('  Driver missing ({0}) - installing it from the print server.' -f $queueDriver) -ForegroundColor DarkGray
            $gotIt = Install-DriverFromPrintShare -Server $qp[0] -DriverName $queueDriver
            if ($gotIt) {
                Write-Host ('  Driver installed from the print server: {0}' -f $queueDriver) -ForegroundColor Green
            }
            else {
                # Attempt 2: let Point and Print install it, with every prompt switched off.
                try {
                    Open-SilentPointAndPrint -Server $qp[0]
                    Write-Host '  Point and Print opened silently for this server for this run.' -ForegroundColor DarkGray
                    Write-Host '  (the previous policy values are restored when this finishes)' -ForegroundColor DarkGray
                }
                catch {
                    Write-Host ('  Could not set the PointAndPrint policy: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }
    }
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
        $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -PrinterPath "{1}"{2}' -f `
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
        # Print the read-back help BEFORE the wait, not only after it. The Commands tab kills
        # this console at 10s - inside the wait loop - so anything printed after the loop is
        # never seen on a first-time driver install. (Printer-Check.ps1 does the same.)
        Write-Host '  If this console is killed before a result appears, read it in a few' -ForegroundColor DarkGray
        Write-Host '  seconds with either of these (both are safe to repeat):' -ForegroundColor DarkGray
        Write-Host "    Get-Content (Get-ChildItem 'C:\Users\*\AppData\Local\PrinterToolkit\Setup-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Tail 25" -ForegroundColor DarkGray
        Write-Host "    `$env:PrinterSetupRead = 'true'; irm <this gist url> | iex" -ForegroundColor DarkGray
        Write-Host ''
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
    # Put the PointAndPrint policy back exactly as it was. When the connection is still
    # running (deferred), the watchdog task does it once the user-session log has a
    # result - closing the gate now would bring the prompt straight back.
    if ($script:PolicySaved) {
        if ($deferred -and $script:PolicyWatchdog) {
            Write-Host ('  PointAndPrint policy is restored by task {0} when the connection finishes (max 20 min).' -f $script:PolicyWatchdog) -ForegroundColor DarkGray
        }
        else {
            try {
                & ([scriptblock]::Create($script:PolicyRestore))
                Write-Host '  PointAndPrint policy restored.' -ForegroundColor DarkGray
            }
            catch {
                Write-Host ('  WARNING: could not restore the PointAndPrint policy: {0}' -f $_.Exception.Message) -ForegroundColor Red
                Write-Host '  Reset it by hand with:' -ForegroundColor Red
                Write-Host $script:PolicyRestore -ForegroundColor Red
            }
            if ($script:PolicyWatchdog) {
                Stop-ScheduledTask -TaskName $script:PolicyWatchdog -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $script:PolicyWatchdog -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }
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
