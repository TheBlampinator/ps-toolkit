#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      MAP NETWORK DRIVE - map (or unmap) a drive letter to a share
      FOR THE LOGGED-ON USER. Paste the whole thing into PowerShell.
    ================================================================

      A mapped drive is per-user data (HKCU\Network), so mapping one from
      a SYSTEM shell would map it for SYSTEM and the person would never
      see it - the same trap the printer tools solve. This bridges into
      the logged-on user's session and maps it there, persistently.

      NOTHING IS BUILT IN. Set the letter and the share:

        $env:MapDriveLetter = 'Z'                 # required; a single letter
        $env:MapDrivePath   = '\\SERVER\SHARE'    # required to map

      Optional:
        $env:MapDriveRemove     = 'true'          # UNMAP the letter instead
        $env:MapDrivePersistent = 'false'         # map for this session only
        $env:MapDriveUser       = 'DOMAIN\name'   # pick the user yourself

      It does NOT pass credentials - the share must be reachable with the
      user's own identity (the usual case for domain / Entra-joined PCs).

      The hashbang lines at the top must stay contiguous - a blank line
      between them and ScreenConnect keeps its 10-second kill.
    ================================================================
#>

$User       = ''
$Persistent = $true
$Remove     = $false
$WaitSeconds = 25
if ($env:MapDriveUser)                   { $User       = $env:MapDriveUser }
if ($env:MapDrivePersistent -eq 'false') { $Persistent = $false }
if ($env:MapDriveRemove -eq 'true')      { $Remove     = $true }
if ($env:MapDriveWait)                   { $WaitSeconds = [int]$env:MapDriveWait }

# Normalise the letter: accept 'Z', 'Z:' or 'Z:\'.
$Letter = ''
if ($env:MapDriveLetter) { $Letter = ([string]$env:MapDriveLetter).TrimEnd('\').TrimEnd(':').Trim().ToUpper() }

function Stop-Box {
    param([string[]]$Lines)
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host '#  STOPPED - NOTHING WAS CHANGED.                          #' -ForegroundColor Red
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
    foreach ($l in $Lines) { Write-Host "  $l" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "      `$env:MapDriveLetter = 'Z'" -ForegroundColor Cyan
    Write-Host "      `$env:MapDrivePath   = '\\SERVER\SHARE'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  To unmap instead:' -ForegroundColor White
    Write-Host "      `$env:MapDriveLetter = 'Z'; `$env:MapDriveRemove = 'true'" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Red
    Write-Host ''
}

if (-not $Letter -or $Letter -notmatch '^[A-Z]$') {
    Stop-Box @('A drive letter is required, e.g. Z. $env:MapDriveLetter is not set or not a single letter.')
    return
}
# $env:MapDrivePath DELETES the var when set to '' in PowerShell, so a missing value is $null.
if (-not $Remove -and -not $env:MapDrivePath) {
    Stop-Box @('A share path is required to map a drive. $env:MapDrivePath is not set.',
               'If you meant to UNMAP, set $env:MapDriveRemove = ''true''.')
    return
}
$SharePath = ''
if ($env:MapDrivePath) { $SharePath = ([string]$env:MapDrivePath).TrimEnd('\') }
if (-not $Remove -and $SharePath -notmatch '^\\\\[^\\]+\\.+') {
    Stop-Box @(("The share path is not in the right form. Got: {0}" -f $SharePath),
               'Expected \\SERVER\SHARE (two backslashes, then server, then the share).')
    return
}

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptVersion = '1.0.0'

function Say { param([string]$m) Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

Say ('Map-NetworkDrive v{0} starting on {1}' -f $scriptVersion, $env:COMPUTERNAME)

# The work must run as the logged-on user: WScript.Network maps into THEIR session and,
# when persistent, writes HKCU\Network so the mapping survives the next logon.
$PayloadText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Letter,
    [string]$SharePath = '',
    [switch]$Persistent,
    [switch]$Remove,
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
$script:Out = $OutFile
function W { param([string]$m = '') Write-Output $m; if ($script:Out) { Add-Content -LiteralPath $script:Out -Value $m } }

$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($ident.IsSystem) { W 'FAILED: refusing to run as SYSTEM - the mapping would be SYSTEM''s, not the user''s.'; W 'END-OF-REPORT'; return }

$dev = $Letter.ToUpper() + ':'
W ('Identity : {0}' -f $ident.Name)
W ('Machine  : {0}' -f $env:COMPUTERNAME)
W ('Letter   : {0}' -f $dev)
$regKey = 'HKCU:\Network\' + $Letter.ToUpper()

$net = $null
try {
    $net = New-Object -ComObject WScript.Network

    if ($Remove) {
        W ('Action   : unmap {0}' -f $dev)
        try { $net.RemoveNetworkDrive($dev, $true, $true) } catch { W ('  RemoveNetworkDrive: {0}' -f $_.Exception.Message) }
        Start-Sleep -Seconds 1
        if (Test-Path -LiteralPath $regKey) {
            W ('FAILED: {0} is still mapped (HKCU\Network key present).' -f $dev)
        }
        else {
            W ('Unmapped : {0}' -f $dev)
            W 'MAP OK'
        }
        W 'END-OF-REPORT'
        return
    }

    W ('Action   : map {0} -> {1}  (persistent: {2})' -f $dev, $SharePath, [bool]$Persistent)

    # If the letter is already mapped elsewhere, clear it first so the new target takes.
    $existing = $null
    try { $existing = (Get-ItemProperty -LiteralPath $regKey -Name RemotePath -ErrorAction SilentlyContinue).RemotePath } catch { }
    if ($existing) {
        W ('  {0} already maps to {1} - replacing it.' -f $dev, $existing)
        try { $net.RemoveNetworkDrive($dev, $true, $true) } catch { }
        Start-Sleep -Milliseconds 500
    }

    $net.MapNetworkDrive($dev, $SharePath, [bool]$Persistent)
    Start-Sleep -Seconds 1

    # Verify: for a persistent map the HKCU\Network key is the durable proof; for a
    # session-only map the drive shows in the current provider list.
    $mappedTo = $null
    try { $mappedTo = (Get-ItemProperty -LiteralPath $regKey -Name RemotePath -ErrorAction SilentlyContinue).RemotePath } catch { }
    $live = @(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$dev'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.ProviderName })
    if ($mappedTo) { W ('Verified : HKCU\Network\{0} -> {1}' -f $Letter.ToUpper(), $mappedTo) }
    if ($live.Count) { W ('Live     : {0} -> {1}' -f $dev, $live[0].ProviderName) }

    if (($Persistent -and $mappedTo -eq $SharePath) -or (-not $Persistent -and $live.Count)) {
        W 'MAP OK'
    }
    elseif ($mappedTo -or $live.Count) {
        W 'MAP OK'
    }
    else {
        W ('FAILED: {0} did not map to {1}. The share may be unreachable with the user''s identity.' -f $dev, $SharePath)
    }
}
catch {
    W ('FAILED: {0}' -f $_.Exception.Message)
}
finally {
    if ($net) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($net) } catch { } }
}
W 'END-OF-REPORT'
'@

$toolDir = 'C:\ProgramData\MapDrive'
try {
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $probe = Join-Path $toolDir ('Map-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}
catch {
    $probe = Join-Path $env:TEMP ('Map-{0}.ps1' -f $stamp)
    Set-Content -LiteralPath $probe -Value $PayloadText -Encoding UTF8
}

$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem
$ok = $false

# Build the argument list once, used for both the direct call and the task.
$common = @('-Letter', $Letter)
if ($SharePath)   { $common += @('-SharePath', $SharePath) }
if ($Persistent)  { $common += '-Persistent' }
if ($Remove)      { $common += '-Remove' }

if (-not $isSystem) {
    Say ('Running as {0} - mapping in place.' -f $ident.Name)
    $out = Join-Path $env:TEMP ('MapDrive-{0}.txt' -f $stamp)
    & $probe @common -OutFile $out | ForEach-Object { Write-Host '    ' $_ }
    if (Test-Path -LiteralPath $out) {
        $raw = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        $ok = ($raw -match 'MAP OK')
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
        Say 'Nobody is logged on - a mapped drive needs a user session.'
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not $User) {
        if ($users.Count -gt 1) {
            Say ('More than one user is logged on: {0}' -f ($users -join ', '))
            Say 'Set $env:MapDriveUser = ''DOMAIN\name'' and run again.'
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
    Say ('SYSTEM shell - mapping in {0}''s session' -f $User)

    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue).LocalPath
    }
    catch { }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }

    $outFile  = '{0}\AppData\Local\Temp\MapDrive-{1}.txt' -f $profileDir, $stamp
    $taskName = 'MapDrive-' + $stamp
    $argParts = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $probe))
    $argParts += @('-Letter', $Letter)
    if ($SharePath)  { $argParts += @('-SharePath', ('"{0}"' -f $SharePath)) }
    if ($Persistent) { $argParts += '-Persistent' }
    if ($Remove)     { $argParts += '-Remove' }
    $argParts += @('-OutFile', ('"{0}"' -f $outFile))
    $argLine = $argParts -join ' '

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    $raw = ''
    try {
        Start-ScheduledTask -TaskName $taskName
        Say ('Waiting up to {0}s for the result...' -f $WaitSeconds)
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
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
        $ok = ($raw -match 'MAP OK')
    }
    else {
        Say 'No report came back - the mapping may not have run as that user.'
        Say ('Probe kept at {0}' -f $probe)
        return
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($ok -and $Remove) {
    Write-Host ('RESULT: UNMAPPED - {0}: is no longer mapped for the user.' -f $Letter) -ForegroundColor Green
}
elseif ($ok) {
    Write-Host ('RESULT: MAPPED - {0}: now points to {1} for the user.' -f $Letter, $SharePath) -ForegroundColor Green
    if ($Persistent) { Write-Host '        It is persistent and will reconnect at next sign-in.' }
}
else {
    Write-Host 'RESULT: FAILED - read the log above for the reason.' -ForegroundColor Red
    if (-not $Remove) { Write-Host '        Usually the share is not reachable with the user''s identity.' }
}
