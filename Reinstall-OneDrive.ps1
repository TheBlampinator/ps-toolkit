#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      REINSTALL ONEDRIVE - uninstall OneDrive, then install it again,
      for the logged-on user. Paste the whole thing into PowerShell.
    ================================================================

      For when OneDrive is corrupt, will not start, or a restart / re-link
      did not fix it. Steps:

        1. Get Microsoft's OneDriveSetup.exe (downloaded and checked to be
           signed by Microsoft; falls back to the copy that ships with
           Windows) - BEFORE anything is removed.
        2. Close OneDrive and run  OneDriveSetup.exe /uninstall.
        3. Run  OneDriveSetup.exe /silent  to install the current version.
        4. Start OneDrive in the user's session and verify it is running.

      If the installer cannot be obtained, NOTHING is uninstalled.

      NOT touched: the user's synced files and the OneDrive folders, and
      the account settings. After reinstalling, OneDrive normally picks the
      existing account back up; if the organisation has no silent sign-in
      the user may see a sign-in window.

      Both install types are handled:
        per-user     %LOCALAPPDATA%\Microsoft\OneDrive   reinstalled AS THE USER
        per-machine  C:\Program Files\Microsoft OneDrive  reinstalled with
                     admin rights (/allusers), then started as the user.
      A per-machine reinstall needs an admin shell: the ScreenConnect
      Commands tab (SYSTEM) or an elevated PowerShell. From a plain user
      shell it is reported and left alone.

      Runs pasted into the ScreenConnect Commands tab, from Backstage, or
      in the user's own PowerShell window. When run as SYSTEM it bridges
      into the logged-on user's session automatically.

      Optional:
        $env:OneDriveReinstallUser = 'DOMAIN\name'   # pick the user yourself

      The hashbang lines at the top must stay contiguous - a blank line
      between them and ScreenConnect keeps its 10-second kill.
    ================================================================
#>

$User = ''
if ($env:OneDriveReinstallUser) { $User = $env:OneDriveReinstallUser }

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.1.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Reinstall-OneDrive v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The payload. Mode decides what it does:
#   Auto       detect the install type and reinstall it (per-user: must run as the
#              user; per-machine: must run with admin rights)
#   Machine    per-machine reinstall only, as SYSTEM/admin; does NOT start OneDrive
#   StartOnly  start OneDrive as the user and check it runs (after a Machine run)
$PayloadText = @'
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [ValidateSet('Auto', 'Machine', 'StartOnly')][string]$Mode = 'Auto'
)
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile
function W { param([string]$m = '') Write-Output $m; if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m } }

function Find-MachineExe {
    @((Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

# Get a trustworthy OneDriveSetup.exe into $Work. Returns its path, or $null after
# writing a FAILED line. Nothing is removed until this has succeeded.
function Get-Installer {
    param([string]$Work)
    $setup = Join-Path $Work 'OneDriveSetup.exe'
    $have = $false
    try {
        W 'Downloading OneDriveSetup.exe from Microsoft ...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=248256' -OutFile $setup -UseBasicParsing
        $have = $true
    }
    catch { W ('  download failed: {0}' -f $_.Exception.Message) }

    if (-not $have) {
        $sys = @((Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
                 (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe')) |
               Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($sys) { Copy-Item -LiteralPath $sys -Destination $setup -Force; $have = $true; W ('Using the copy that ships with Windows: {0}' -f $sys) }
    }
    if (-not $have) { W 'FAILED: no OneDriveSetup.exe available (no internet and none in Windows) - nothing was changed.'; return $null }

    $sig = Get-AuthenticodeSignature -LiteralPath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        W ('FAILED: OneDriveSetup.exe is not validly signed by Microsoft ({0}) - nothing was changed.' -f $sig.Status)
        return $null
    }
    W 'Installer is signed by Microsoft.'
    return $setup
}

# Make sure OneDrive.exe is running as the current user. Returns $true when it is.
function Start-OneDriveAndCheck {
    param([string]$Exe)
    $running = @()
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $running.Count -and (Get-Date) -lt $deadline) {
        $running = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
        if (-not $running.Count) { Start-Sleep -Seconds 2 }
    }
    if (-not $running.Count) {
        W 'OneDrive.exe is installed but not running - starting it.'
        Start-Process -FilePath $Exe
        Start-Sleep -Seconds 5
        $running = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
    }
    return [bool]$running.Count
}

$work = $null
try {
    $ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $ident.IsSystem
    $isAdmin  = $isSystem
    if (-not $isAdmin) {
        try { $isAdmin = (New-Object Security.Principal.WindowsPrincipal($ident)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        catch { $isAdmin = $false }
    }
    W ('Identity : {0}' -f $ident.Name)
    W ('Machine  : {0}' -f $env:COMPUTERNAME)

    $userExe    = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    $machineExe = Find-MachineExe

    # ---- StartOnly: the per-machine reinstall already happened as SYSTEM -------
    if ($Mode -eq 'StartOnly') {
        if ($isSystem) { W 'FAILED: StartOnly must run as the user, not SYSTEM.'; return }
        $exe = if ($machineExe) { $machineExe } elseif (Test-Path -LiteralPath $userExe) { $userExe } else { $null }
        if (-not $exe) { W 'FAILED: OneDrive.exe is not installed - nothing to start.'; return }
        W ('Version  : {0}' -f (Get-Item -LiteralPath $exe).VersionInfo.FileVersion)
        if (Start-OneDriveAndCheck -Exe $exe) { W 'ONEDRIVE RUNNING' }
        else { W 'FAILED: OneDrive is installed but did not start. A sign-in window may be waiting on the desktop.' }
        return
    }

    # ---- which kind of install is this? ---------------------------------------
    $perMachine = $false
    if ($Mode -eq 'Machine') {
        if (-not $machineExe) { W 'FAILED: no per-machine OneDrive (Program Files) was found - nothing was changed.'; return }
        $perMachine = $true
    }
    elseif (Test-Path -LiteralPath $userExe) { $perMachine = $false }
    elseif ($machineExe)                     { $perMachine = $true }
    else {
        W 'NOTHING-TO-DO: OneDrive is not installed for this user.'
        return
    }

    if ($perMachine) {
        if (-not $isAdmin) {
            W 'FAILED: OneDrive is installed per-machine (Program Files), which only an administrator can reinstall.'
            W '        Run this from the ScreenConnect Commands tab (SYSTEM) or an elevated PowerShell - nothing was changed.'
            return
        }
        W ('Installed: {0}  (per-machine)' -f $machineExe)
    }
    else {
        if ($isSystem) { W 'FAILED: a per-user OneDrive must be reinstalled as the user, not SYSTEM - nothing was changed.'; return }
        W ('Installed: {0}  (per-user)' -f $userExe)
    }

    # ---- 1. get a trustworthy installer BEFORE removing anything --------------
    $work = Join-Path $env:TEMP ('OneDriveReinstall-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    $null = New-Item -ItemType Directory -Path $work -Force
    $setup = Get-Installer -Work $work
    if (-not $setup) { return }

    # ---- 2. uninstall ---------------------------------------------------------
    W 'Closing OneDrive ...'
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $unArgs = if ($perMachine) { '/uninstall /allusers' } else { '/uninstall' }
    $inArgs = if ($perMachine) { '/silent /allusers' }    else { '/silent' }
    $target = if ($perMachine) { $machineExe } else { $userExe }

    W ('Uninstalling OneDrive ({0}) ...' -f $unArgs)
    $p = Start-Process -FilePath $setup -ArgumentList $unArgs -Wait -PassThru
    W ('  uninstall exit code {0}' -f $p.ExitCode)
    Start-Sleep -Seconds 3
    if (Test-Path -LiteralPath $target) { W 'PROBLEM: OneDrive.exe is still there after the uninstall.' }
    else { W 'OneDrive uninstalled.' }

    # ---- 3. install again -----------------------------------------------------
    W ('Installing OneDrive again ({0}) ...' -f $inArgs)
    $p = Start-Process -FilePath $setup -ArgumentList $inArgs -Wait -PassThru
    W ('  install exit code {0}' -f $p.ExitCode)

    # ---- 4. verify the file is back -------------------------------------------
    $back = $null
    $deadline = (Get-Date).AddSeconds(120)
    while (-not $back -and (Get-Date) -lt $deadline) {
        $back = if ($perMachine) { Find-MachineExe } elseif (Test-Path -LiteralPath $userExe) { $userExe } else { $null }
        if (-not $back) { Start-Sleep -Seconds 2 }
    }
    if (-not $back) {
        W 'FAILED: OneDrive.exe is NOT back after the install. Run this tool again, or install OneDrive manually.'
        return
    }
    W ('Version  : {0}' -f (Get-Item -LiteralPath $back).VersionInfo.FileVersion)

    if ($isSystem) {
        # SYSTEM cannot start OneDrive on the user's desktop; the caller bridges a
        # StartOnly run into the user's session for that.
        W 'MACHINE REINSTALL DONE'
        return
    }
    if (Start-OneDriveAndCheck -Exe $back) { W 'ONEDRIVE REINSTALLED' }
    else { W 'FAILED: OneDrive is installed but did not start. A sign-in window may be waiting on the desktop.' }
}
catch {
    W ('FAILED: {0}' -f $_.Exception.Message)
}
finally {
    if ($work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    W 'END-OF-REPORT'
}
'@

$toolDir = 'C:\ProgramData\OneDriveReinstall'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $probe = Join-Path $toolDir ('Reinstall-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}
catch {
    $probe = Join-Path $env:TEMP ('Reinstall-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}

# Run the payload in the logged-on user's session through a scheduled task and
# stream its report. Returns the report text; '' (and $script:Deferred = $true)
# when it had not finished within $WaitSeconds.
function Invoke-InUserSession {
    param([string]$User, [string]$ProfileDir, [string]$Mode, [int]$WaitSeconds)

    $outFile  = '{0}\AppData\Local\Temp\OneDriveReinstall-{1}-{2}.txt' -f $ProfileDir, $Mode, $stamp
    $taskName = 'OneDriveReinstall-{0}-{1}' -f $Mode, $stamp
    $argLine  = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}" -Mode {2}' -f $probe, $outFile, $Mode

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    $text = ''
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $shown = 0
        while ($text -notmatch 'END-OF-REPORT' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $outFile) {
                $lines = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
                for ($i = $shown; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -notmatch 'END-OF-REPORT') { Write-Host ('    ' + $lines[$i]) }
                }
                $shown = $lines.Count
                $text = $lines -join "`n"
            }
        }
    }
    finally {
        if ($text -match 'END-OF-REPORT') {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($text -notmatch 'END-OF-REPORT') {
        Write-Host ''
        Say 'No final report yet - it may still be running in the user''s session.'
        Say ('Progress so far is in {0}' -f $outFile)
        Say ('Scheduled task {0} is left in place; it removes nothing else.' -f $taskName)
        $script:Deferred = $true
        return ''
    }
    return $text
}

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem
$raw = ''
$machineRaw = ''
$script:Deferred = $false

if (-not $isSystem) {
    Say ('Running as {0} - reinstalling in place.' -f $ident.Name)
    $out = Join-Path $env:TEMP ('OneDriveReinstall-{0}.txt' -f $stamp)
    & $probe -OutFile $out | ForEach-Object { Write-Host '    ' $_ }
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
        Say 'Nobody is logged on - there is no OneDrive session to reinstall.'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not $User) {
        if ($users.Count -gt 1) {
            Say ('More than one user is logged on: {0}' -f ($users -join ', '))
            Say 'Set $env:OneDriveReinstallUser = ''DOMAIN\name'' and run again.'
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

    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    }
    catch { }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

    # Per-user or per-machine? Look from SYSTEM's side, in the user's profile.
    $userExe    = Join-Path $profileDir 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'
    $machineExe = @((Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')) |
                  Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $perMachine = (-not (Test-Path -LiteralPath $userExe)) -and $machineExe

    if ($perMachine) {
        # Admin work here as SYSTEM; the user's session only has to start OneDrive.
        Say ('SYSTEM shell - OneDrive is installed per-machine ({0}).' -f $machineExe)
        Say 'Reinstalling it as SYSTEM (this can take a few minutes)...'
        $out = Join-Path $env:TEMP ('OneDriveReinstall-{0}.txt' -f $stamp)
        & $probe -OutFile $out -Mode Machine | ForEach-Object { Write-Host '    ' $_ }
        if (Test-Path -LiteralPath $out) {
            $machineRaw = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
        if ($machineRaw -match 'MACHINE REINSTALL DONE') {
            Say ('Starting OneDrive in {0}''s session...' -f $User)
            $raw = Invoke-InUserSession -User $User -ProfileDir $profileDir -Mode StartOnly -WaitSeconds 120
        }
        else {
            $raw = $machineRaw
        }
    }
    else {
        Say ('SYSTEM shell - reinstalling in {0}''s session' -f $User)
        Say 'Reinstalling (this can take a few minutes)...'
        $raw = Invoke-InUserSession -User $User -ProfileDir $profileDir -Mode Auto -WaitSeconds 480
    }

    if ($script:Deferred) { return }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($raw -match 'ONEDRIVE REINSTALLED' -or ($machineRaw -match 'MACHINE REINSTALL DONE' -and $raw -match 'ONEDRIVE RUNNING')) {
    Write-Host 'RESULT: REINSTALLED - OneDrive was uninstalled, installed again, and is running.' -ForegroundColor Green
    Write-Host '        Synced files were not touched. The user may see a sign-in window if there is no silent sign-in.'
}
elseif ($machineRaw -match 'MACHINE REINSTALL DONE') {
    Write-Host 'RESULT: REINSTALLED BUT NOT RUNNING - OneDrive was reinstalled per-machine, but did not start in the user''s session.' -ForegroundColor Yellow
    Write-Host '        See the lines above. It usually starts at the next sign-in, or the user can open OneDrive from the Start menu.'
}
elseif ($raw -match 'NOTHING-TO-DO') {
    Write-Host 'RESULT: NOTHING TO DO - OneDrive is not installed for this user.' -ForegroundColor Yellow
}
elseif ($raw -match 'FAILED:') {
    Write-Host 'RESULT: FAILED - see the FAILED line above. If it failed before "Uninstalling", nothing was changed.' -ForegroundColor Red
}
else {
    Write-Host 'RESULT: UNKNOWN - no verdict in the report.' -ForegroundColor Yellow
}
