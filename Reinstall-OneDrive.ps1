#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      REINSTALL ONEDRIVE - uninstall OneDrive, then install it again,
      in the logged-on user's session. Paste the whole thing into
      PowerShell.
    ================================================================

      For when OneDrive is corrupt, will not start, or a restart / re-link
      did not fix it. Steps, as the logged-on user:

        1. Get Microsoft's OneDriveSetup.exe (downloaded and checked to be
           signed by Microsoft; falls back to the copy that ships with
           Windows) - BEFORE anything is removed.
        2. Close OneDrive and run  OneDriveSetup.exe /uninstall.
        3. Run  OneDriveSetup.exe /silent  to install the current version.
        4. Verify OneDrive.exe is back and running.

      If the installer cannot be obtained, NOTHING is uninstalled.

      NOT touched: the user's synced files and the OneDrive folders, and
      the account settings. After reinstalling, OneDrive normally picks the
      existing account back up; if the organisation has no silent sign-in
      the user may see a sign-in window.

      Per-user installs only. A per-machine install (Program Files) is
      reported and left alone.

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
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Reinstall-OneDrive v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work must run as the logged-on user: OneDrive is installed per user.
$PayloadText = @'
[CmdletBinding()]
param([string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile
function W { param([string]$m = '') Write-Output $m; if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m } }

try {
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($ident.IsSystem) { W 'FAILED: refusing to run as SYSTEM - OneDrive is per-user.'; return }
    W ('Identity : {0}' -f $ident.Name)
    W ('Machine  : {0}' -f $env:COMPUTERNAME)

    $userExe    = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
    $machineExe = @((Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')) |
                  Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if (-not (Test-Path -LiteralPath $userExe)) {
        if ($machineExe) {
            W 'FAILED: OneDrive is a per-machine install (Program Files). This tool only handles per-user installs - nothing was changed.'
        }
        else {
            W 'NOTHING-TO-DO: OneDrive is not installed for this user.'
        }
        return
    }
    W ('Installed: {0}' -f $userExe)

    # ---- 1. get a trustworthy installer BEFORE removing anything ----------
    $work = Join-Path $env:TEMP ('OneDriveReinstall-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    $null = New-Item -ItemType Directory -Path $work -Force
    $setup = Join-Path $work 'OneDriveSetup.exe'
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
    if (-not $have) { W 'FAILED: no OneDriveSetup.exe available (no internet and none in Windows) - nothing was changed.'; return }

    $sig = Get-AuthenticodeSignature -LiteralPath $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        W ('FAILED: OneDriveSetup.exe is not validly signed by Microsoft ({0}) - nothing was changed.' -f $sig.Status)
        return
    }
    W 'Installer is signed by Microsoft.'

    # ---- 2. uninstall -----------------------------------------------------
    W 'Closing OneDrive ...'
    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    W 'Uninstalling OneDrive ...'
    $p = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru
    W ('  uninstall exit code {0}' -f $p.ExitCode)
    Start-Sleep -Seconds 3
    if (Test-Path -LiteralPath $userExe) {
        W 'PROBLEM: OneDrive.exe is still there after the uninstall.'
    }
    else { W 'OneDrive uninstalled.' }

    # ---- 3. install again ------------------------------------------------
    W 'Installing OneDrive again ...'
    $p = Start-Process -FilePath $setup -ArgumentList '/silent' -Wait -PassThru
    W ('  install exit code {0}' -f $p.ExitCode)

    # ---- 4. verify -------------------------------------------------------
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path -LiteralPath $userExe) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-Path -LiteralPath $userExe)) {
        W 'FAILED: OneDrive.exe is NOT back after the install. Run this tool again, or install OneDrive manually.'
        return
    }
    $running = @()
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $running.Count -and (Get-Date) -lt $deadline) {
        $running = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
        if (-not $running.Count) { Start-Sleep -Seconds 2 }
    }
    if (-not $running.Count) {
        W 'OneDrive.exe is installed but not running - starting it.'
        Start-Process -FilePath $userExe
        Start-Sleep -Seconds 5
        $running = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
    }
    W ('Version  : {0}' -f (Get-Item -LiteralPath $userExe).VersionInfo.FileVersion)
    if ($running.Count) { W 'ONEDRIVE REINSTALLED' }
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

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem
$raw = ''

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
    Say ('SYSTEM shell - reinstalling in {0}''s session' -f $User)

    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    }
    catch { }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

    $outFile  = '{0}\AppData\Local\Temp\OneDriveReinstall-{1}.txt' -f $profileDir, $stamp
    $taskName = 'OneDriveReinstall-' + $stamp
    $argLine  = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}"' -f $probe, $outFile

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    try {
        Start-ScheduledTask -TaskName $taskName
        Say 'Reinstalling (this can take a few minutes)...'
        $deadline = (Get-Date).AddSeconds(480)
        $shown = 0
        while ($raw -notmatch 'END-OF-REPORT' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $outFile) {
                $lines = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
                for ($i = $shown; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -notmatch 'END-OF-REPORT') { Write-Host ('    ' + $lines[$i]) }
                }
                $shown = $lines.Count
                $raw = $lines -join "`n"
            }
        }
    }
    finally {
        if ($raw -match 'END-OF-REPORT') {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    if ($raw -match 'END-OF-REPORT') {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    else {
        Say 'No final report yet - it may still be running in the user''s session.'
        Say ('Progress so far is in {0}' -f $outFile)
        Say ('Scheduled task {0} is left in place; it removes nothing else.' -f $taskName)
        return
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($raw -match 'ONEDRIVE REINSTALLED') {
    Write-Host 'RESULT: REINSTALLED - OneDrive was uninstalled, installed again, and is running.' -ForegroundColor Green
    Write-Host '        Synced files were not touched. The user may see a sign-in window if there is no silent sign-in.'
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
