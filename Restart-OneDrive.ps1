#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      RESTART ONEDRIVE - stop OneDrive and start it again, in the
      logged-on user's session. Paste the whole thing into PowerShell.
    ================================================================

      The light-touch fix for "OneDrive is not running" or "it is stuck":
      it just stops and starts OneDrive.exe for the person who is logged
      in. It does NOT unlink, reset or touch any account - for that use
      Reset-OneDriveLink-2.ps1.

      Runs pasted into the ScreenConnect Commands tab, from Backstage, or
      in the user's own PowerShell window. When run as SYSTEM it bridges
      into the logged-on user's session automatically - a printer or
      OneDrive started as SYSTEM would not be the user's.

      No configuration. Optional:
        $env:OneDriveRestartUser = 'DOMAIN\name'   # pick the user yourself

      The hashbang lines at the top must stay contiguous - a blank line
      between them and ScreenConnect keeps its 10-second kill.
    ================================================================
#>

$User = ''
if ($env:OneDriveRestartUser) { $User = $env:OneDriveRestartUser }

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Restart-OneDrive v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work that must run as the logged-on user: OneDrive.exe is per-user, and a copy
# started by SYSTEM would not be theirs.
$PayloadText = @'
[CmdletBinding()]
param([string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile
function W { param([string]$m = '') Write-Output $m; if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m } }

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { W 'FAILED: refusing to run as SYSTEM - OneDrive would not be the user''s.'; W 'END-OF-REPORT'; return }

W ('Identity : {0}' -f $ident.Name)
W ('Machine  : {0}' -f $env:COMPUTERNAME)

function Get-OneDriveExe {
    $c = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
    )
    $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

$exe = Get-OneDriveExe
if (-not $exe) { W 'FAILED: OneDrive.exe not found for this user.'; W 'END-OF-REPORT'; return }
W ('OneDrive : {0}' -f $exe)

$before = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
W ('Before   : {0} instance(s) running' -f $before.Count)

if ($before.Count) {
    W 'Stopping OneDrive...'
    $before | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Process -Name OneDrive -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process -Name OneDrive -ErrorAction SilentlyContinue) { W '  (some instances did not stop within 20s)' }
}

W 'Starting OneDrive...'
Start-Process -FilePath $exe

# Verify it actually came up. OneDrive can take a few seconds to register its process.
$deadline = (Get-Date).AddSeconds(25)
$after = @()
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $after = @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)
    if ($after.Count) { break }
}
W ('After    : {0} instance(s) running' -f $after.Count)
if ($after.Count) {
    $p = $after | Sort-Object StartTime | Select-Object -First 1
    W ('PID      : {0}' -f $p.Id)
    W 'ONEDRIVE RUNNING'
}
else {
    W 'FAILED: OneDrive did not start within 25s. A sign-in window may be waiting on the desktop.'
}
W 'END-OF-REPORT'
'@

$toolDir = 'C:\ProgramData\OneDriveRestart'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $probe = Join-Path $toolDir ('Restart-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}
catch {
    $probe = Join-Path $env:TEMP ('Restart-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem
$ok = $false

if (-not $isSystem) {
    Say ('Running as {0} - restarting in place.' -f $ident.Name)
    $out = Join-Path $env:TEMP ('OneDriveRestart-{0}.txt' -f $stamp)
    & $probe -OutFile $out | ForEach-Object { Write-Host '    ' $_ }
    if (Test-Path -LiteralPath $out) {
        $raw = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        $ok = ($raw -match 'ONEDRIVE RUNNING')
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
        Say 'Nobody is logged on - there is no OneDrive session to restart.'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not $User) {
        if ($users.Count -gt 1) {
            Say ('More than one user is logged on: {0}' -f ($users -join ', '))
            Say 'Set $env:OneDriveRestartUser = ''DOMAIN\name'' and run again.'
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
    Say ('SYSTEM shell - restarting in {0}''s session' -f $User)

    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    }
    catch { }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

    $outFile  = '{0}\AppData\Local\Temp\OneDriveRestart-{1}.txt' -f $profileDir, $stamp
    $taskName = 'OneDriveRestart-' + $stamp
    $argLine  = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}"' -f $probe, $outFile

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    $raw = ''
    try {
        Start-ScheduledTask -TaskName $taskName
        Say 'Restarting...'
        $deadline = (Get-Date).AddSeconds(60)
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
            ForEach-Object { Write-Host '    ' $_ }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        $ok = ($raw -match 'ONEDRIVE RUNNING')
    }
    else {
        Say 'No report came back - the restart may not have run as that user.'
        Say ('Probe kept at {0}' -f $probe)
        return
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($ok) {
    Write-Host 'RESULT: RUNNING - OneDrive was restarted and is running again.' -ForegroundColor Green
}
else {
    Write-Host 'RESULT: NOT RUNNING - OneDrive did not come back up.' -ForegroundColor Yellow
    Write-Host '        A sign-in window may be waiting on the desktop, or the account needs re-linking.'
}
