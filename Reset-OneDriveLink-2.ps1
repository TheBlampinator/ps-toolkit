<#
.SYNOPSIS
    Unlink and re-link OneDrive for the logged-on user. Single file, works from a
    SYSTEM shell (ScreenConnect Backstage / Commands tab) or directly as the user.

.DESCRIPTION
    Automates https://support.microsoft.com/en-us/onedrive/unlink-and-re-link-onedrive

    The script has two halves and picks one automatically:

      * If it is running as the logged-on user (manual run, Intune "logged on
        credentials", GPO logon script) it just does the work.

      * If it is running as NT AUTHORITY\SYSTEM (Backstage, Commands tab, PsExec -s)
        it cannot touch the user's HKCU, so it stages a copy of itself in
        C:\ProgramData\OneDriveRelink and registers a one-shot scheduled task that
        re-invokes that copy with -Payload under the interactive user's token. It
        waits for the task, prints the user-session log, then deletes the task.
        No desktop session, no screen share, no user interruption.

    The work itself:
      1. Stops OneDrive.
      2. Backs up and removes the OneDrive account registration (same effect as
         Settings > Account > "Unlink this PC").
      3. Restarts OneDrive so it re-links. Silent if the SilentAccountConfig policy
         ("Silently sign in users...") is enabled; otherwise the user sees the
         OneDrive sign-in window.

    Local files are NOT deleted. On re-link OneDrive matches the files already on
    disk instead of downloading them again.

.PARAMETER Account
    Which account to unlink: Business (default, all work/school accounts),
    Personal, or All. 'Auto' is accepted for backwards compatibility and behaves
    as Business.

.PARAMETER UseReset
    Use Microsoft's built-in "OneDrive.exe /reset" instead of removing the account
    registration. Resets all sync settings and re-syncs; slower but fully supported.

.PARAMETER NoRestart
    Unlink only; do not start OneDrive again afterwards.

.PARAMETER User
    SYSTEM mode only: DOMAIN\username to target. Omit to auto-detect; the script
    refuses to guess if more than one interactive user is logged on.

.PARAMETER TimeoutSeconds
    SYSTEM mode only: how long to wait for the user-session run. Default 300.

.PARAMETER Payload
    Internal. Set by the scheduled task to mean "do the work now". Do not pass it.

.EXAMPLE
    .\Reset-OneDriveLink.ps1
    From Backstage: bridges into the logged-on user's session, unlinks work/school
    OneDrive and re-links it.

.EXAMPLE
    .\Reset-OneDriveLink.ps1 -Account All
    Both personal and work/school accounts.

.EXAMPLE
    .\Reset-OneDriveLink.ps1 -Account Personal -NoRestart
    Unlink only, leave OneDrive stopped.

.EXAMPLE
    .\Reset-OneDriveLink.ps1 -Account All -User 'CONTOSO\jsmith'
    From Backstage, targeting a specific user when several are logged on.

.EXAMPLE
    .\Reset-OneDriveLink.ps1 -UseReset
    Run the official OneDrive reset instead.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Business', 'Personal', 'All')]
    [string]$Account = 'Business',
    [switch]$UseReset,
    [switch]$NoRestart,
    [string]$User,
    [int]$TimeoutSeconds = 300,
    [switch]$Payload
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile = $null

# Own path, captured at script scope where it is reliable. Needed to re-invoke ourselves.
$script:SelfPath = $PSCommandPath
if (-not $script:SelfPath) { $script:SelfPath = $MyInvocation.MyCommand.Path }

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 's'), $Message
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function Get-OneDriveExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
    )
    $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Stop-OneDrive {
    $procs = Get-Process -Name OneDrive -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Stopping OneDrive (PID $($procs.Id -join ', '))"
        $procs | Stop-Process -Force
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process -Name OneDrive -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
        }
    }
}

# =============================================================================
#  PAYLOAD - the actual work. Must run as the logged-on user.
# =============================================================================
function Invoke-OneDriveWork {
    param(
        [ValidateSet('Auto', 'Business', 'Personal', 'All')][string]$Account = 'Business',
        [switch]$UseReset,
        [switch]$NoRestart
    )

    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Payload must run as the logged-on user, not SYSTEM. In SYSTEM mode this script bridges itself.'
    }
    if ($Account -eq 'Auto') { $Account = 'Business' }

    $logDir = Join-Path $env:LOCALAPPDATA 'OneDriveRelink'
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $script:LogFile = Join-Path $logDir "Relink-$stamp.log"

    Write-Log "OneDrive re-link started for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
    Write-Log "Identity confirmed: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $exe = Get-OneDriveExe
    if (-not $exe) { throw 'OneDrive.exe not found.' }
    Write-Log "OneDrive found at $exe"

    if ($UseReset) {
        Write-Log 'Running OneDrive.exe /reset'
        Start-Process -FilePath $exe -ArgumentList '/reset' -Wait
        Start-Sleep -Seconds 10
    }
    else {
        Stop-OneDrive

        $accountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
        if (-not (Test-Path -LiteralPath $accountsKey)) {
            Write-Log 'No OneDrive accounts are registered; nothing to unlink.'
        }
        else {
            $targets = Get-ChildItem $accountsKey | Where-Object {
                switch ($Account) {
                    'Business' { $_.PSChildName -like 'Business*' }
                    'Personal' { $_.PSChildName -eq 'Personal' }
                    default    { $_.PSChildName -like 'Business*' -or $_.PSChildName -eq 'Personal' }
                }
            }

            if (-not $targets) { Write-Log "No $Account account found to unlink." }

            foreach ($key in $targets) {
                $name  = $key.PSChildName
                $props = Get-ItemProperty $key.PSPath
                Write-Log "Unlinking $name ($($props.UserEmail)) - folder: $($props.UserFolder)"

                $backup = Join-Path $logDir "OneDrive-$name-$stamp.reg"
                & reg.exe export ($key.Name) $backup /y | Out-Null
                Write-Log "  Registry backed up to $backup"

                if ($props.NameSpaceCLSID) {
                    $ns = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$($props.NameSpaceCLSID)"
                    if (Test-Path -LiteralPath $ns) {
                        Remove-Item $ns -Recurse -Force
                        Write-Log "  Removed Explorer namespace $($props.NameSpaceCLSID)"
                    }
                }

                Remove-Item $key.PSPath -Recurse -Force
                Write-Log "  Removed account registration $name"

                $settings = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\settings\$name"
                if (Test-Path -LiteralPath $settings) {
                    Rename-Item $settings "$name.old-$stamp"
                    Write-Log "  Renamed settings folder to $name.old-$stamp"
                }
            }
        }
    }

    if (-not $NoRestart -and -not (Get-Process -Name OneDrive -ErrorAction SilentlyContinue)) {
        Write-Log 'Starting OneDrive to re-link'
        Start-Process -FilePath $exe
    }

    Write-Log 'Completed successfully.'
    Write-Log "Log file: $($script:LogFile)"
}

# =============================================================================
#  BRIDGE - SYSTEM mode. Re-invoke this script as the logged-on user.
# =============================================================================
function Invoke-AsLoggedOnUser {
    param(
        [string]$User,
        [string]$Account,
        [switch]$UseReset,
        [switch]$NoRestart,
        [int]$TimeoutSeconds
    )

    # -- who can we target? ---------------------------------------------------
    $users = @(
        Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
            Select-Object -ExpandProperty UserName -Unique
    )
    if ($users.Count -eq 0) {
        throw 'No interactive user session found. Nobody is logged on; this cannot run unattended.'
    }
    if (-not $User) {
        if ($users.Count -gt 1) {
            throw ("Multiple interactive users logged on: {0}. Re-run with -User 'DOMAIN\name'." -f ($users -join ', '))
        }
        $User = $users[0]
    }
    elseif ($users -notcontains $User) {
        throw ("{0} has no interactive session. Logged on: {1}" -f $User, ($users -join ', '))
    }
    Write-Log "Target user: $User"

    # -- will the user see anything? -----------------------------------------
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    $silent = $null
    if (Test-Path -LiteralPath $policyKey) {
        $silent = (Get-ItemProperty -LiteralPath $policyKey -Name SilentAccountConfig `
                    -ErrorAction SilentlyContinue).SilentAccountConfig
    }
    if ($silent -eq 1) {
        Write-Log 'SilentAccountConfig=1 -> re-link should be silent for the user.'
    }
    else {
        Write-Log 'WARNING: SilentAccountConfig is not enabled -> the user WILL get a OneDrive'
        Write-Log '         sign-in window on their desktop. Nothing else on their screen changes.'
    }

    # -- stage a readable copy of this same file -----------------------------
    $self = $script:SelfPath
    if (-not $self -or -not (Test-Path -LiteralPath $self)) {
        throw 'Cannot determine this script''s own path. Save it as a .ps1 file and run it as a file.'
    }
    $stageDir = 'C:\ProgramData\OneDriveRelink'
    $null = New-Item -ItemType Directory -Path $stageDir -Force
    $staged = $stageDir + '\Reset-OneDriveLink.ps1'
    if ((Resolve-Path -LiteralPath $self).Path -ne $staged) {
        Copy-Item -LiteralPath $self -Destination $staged -Force
        Write-Log "Staged copy: $staged"
    }
    else {
        Write-Log "Already staged at: $staged"
    }

    # -- profile dir of the target (via SID, not C:\Users\<name>) ------------
    $profileDir = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" `
                        -ErrorAction SilentlyContinue).LocalPath
    }
    catch {
        Write-Log "Could not resolve $User to a SID; falling back to a name-based path."
    }
    if (-not $profileDir) { $profileDir = 'C:\Users\' + ($User -split '\\')[-1] }
    Write-Log "Profile: $profileDir"

    # -- register and run the one-shot task ----------------------------------
    $taskName = 'OneDriveRelink-' + $stamp
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $staged), '-Payload', '-Account', $Account
    )
    if ($UseReset) { $argList += '-UseReset' }
    if ($NoRestart) { $argList += '-NoRestart' }
    $argLine = $argList -join ' '

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    # Limited, not Highest: the user's normal token, so the OneDrive.exe the payload
    # restarts runs exactly as it always does. An elevated OneDrive misbehaves.
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    # AllowStartIfOnBatteries matters: tasks do not start on a laptop on battery by default.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Write-Log "Registering task $taskName"
    Write-Log "  powershell.exe $argLine"
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    $startedAt = Get-Date
    # Get-ScheduledTaskInfo truncates LastRunTime to whole seconds, so a task that
    # finishes in under a second never satisfies 'LastRunTime -gt $startedAt' and
    # the wait would run to the full timeout despite success. Allow slack.
    $notBefore = $startedAt.AddSeconds(-5)
    $task = $null
    $info = $null
    $done = $false
    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Log 'Started. Waiting for the user-session run...'

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $lastNote = Get-Date
        do {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
            $done = $task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -ge $notBefore
            if (-not $done -and ((Get-Date) - $lastNote).TotalSeconds -ge 30) {
                Write-Log ('  still waiting - state: {0}, last result: {1}' -f `
                    $task.State, $(if ($info) { $info.LastTaskResult } else { 'n/a' }))
                $lastNote = Get-Date
            }
        } while (-not $done -and (Get-Date) -lt $deadline)

        if (-not $done) {
            Write-Log "TIMED OUT after $TimeoutSeconds s (state: $($task.State)). The payload may still be running."
        }
        elseif ($info.LastTaskResult -eq 0) {
            Write-Log 'Task exit code 0 - payload reported success.'
        }
        elseif ($info.LastTaskResult -eq 1) {
            Write-Log 'Task exit code 1 - payload hit an error, see its log below.'
        }
        else {
            Write-Log ("Task exit code {0} (0x{0:X})" -f $info.LastTaskResult)
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Task removed: $taskName"
    }

    # -- show what the payload logged -----------------------------------------
    $logDir = '{0}\AppData\Local\OneDriveRelink' -f $profileDir
    if (Test-Path -LiteralPath $logDir) {
        $log = Get-ChildItem -LiteralPath $logDir -Filter 'Relink-*.log' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            Write-Log "Log: $($log.FullName)"
            Get-Content -LiteralPath $log.FullName | ForEach-Object { Write-Host "    $_" }
        }
        $backups = Get-ChildItem -LiteralPath $logDir -Filter '*.reg' -ErrorAction SilentlyContinue
        if ($backups) {
            Write-Log 'Registry backups (revert with: reg import <file>):'
            $backups | ForEach-Object { Write-Host "    $($_.FullName)" }
        }
    }
    else {
        Write-Log "No log directory at $logDir - the payload never ran as that user."
    }
}

# =============================================================================
#  MAIN
# =============================================================================
$ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = $ident.IsSystem

try {
    if ($Payload -or -not $isSystem) {
        # Running as the user (or as the scheduled task) - do the work.
        Invoke-OneDriveWork -Account $Account -UseReset:$UseReset -NoRestart:$NoRestart
        exit 0
    }

    # Running as SYSTEM - bridge into the logged-on user's session.
    Write-Log "SYSTEM mode on $env:COMPUTERNAME - bridging into the logged-on user session"
    Invoke-AsLoggedOnUser -User $User -Account $Account -UseReset:$UseReset `
        -NoRestart:$NoRestart -TimeoutSeconds $TimeoutSeconds
    Write-Log 'Completed successfully.'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
