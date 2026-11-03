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

# The source text of whatever is running. Needed when this file was not run from disk -
# pasted, or fetched as text and executed in memory by the menu - because the scheduled
# task requires a real file to execute.
$script:SelfText = $null
try { $script:SelfText = $MyInvocation.MyCommand.ScriptBlock.ToString() } catch { }

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
        $removed = @()
        $removedFolder = @{}
        if (-not (Test-Path -LiteralPath $accountsKey)) {
            Write-Log 'No OneDrive accounts are registered; nothing to unlink.'
            Write-Log 'NOTHING-TO-DO: this user has no OneDrive account registered.'
        }
        else {
            $targets = Get-ChildItem $accountsKey | Where-Object {
                switch ($Account) {
                    'Business' { $_.PSChildName -like 'Business*' }
                    'Personal' { $_.PSChildName -eq 'Personal' }
                    default    { $_.PSChildName -like 'Business*' -or $_.PSChildName -eq 'Personal' }
                }
            }

            # 'All' should mean all. If the names do not match Business*/Personal - which
            # happens with some Azure AD builds - fall back to every registered account
            # rather than doing nothing and claiming success.
            if (-not $targets -and $Account -eq 'All') {
                $allKeys = @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue)
                if ($allKeys.Count) {
                    Write-Log ('No Business*/Personal key matched - treating every registered account as a target: {0}' -f `
                                (($allKeys | Select-Object -ExpandProperty PSChildName) -join ', '))
                    $targets = $allKeys
                }
            }

            if (-not $targets) {
                # Say exactly what IS registered - "no account found" alone is useless.
                $present = @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue |
                                Select-Object -ExpandProperty PSChildName)
                Write-Log ('Accounts registered for this user: {0}' -f $(if ($present.Count) { $present -join ', ' } else { '(none)' }))
                Write-Log ('No account matched ''{0}'' - nothing was unlinked.' -f $Account)
            }

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
                $removed += $name
                $removedFolder[$name] = [string]$props.UserFolder

                $settings = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\settings\$name"
                if (Test-Path -LiteralPath $settings) {
                    Rename-Item $settings "$name.old-$stamp"
                    Write-Log "  Renamed settings folder to $name.old-$stamp"
                }
            }
        }
    }

    if ($NoRestart) {
        Write-Log 'OneDrive left stopped (-NoRestart) - nothing to verify.'
        Write-Log 'VERIFICATION SKIPPED'
        return
    }

    if (-not (Get-Process -Name OneDrive -ErrorAction SilentlyContinue)) {
        Write-Log 'Starting OneDrive to re-link'
        Start-Process -FilePath $exe
    }

    if (-not $removed -or -not $removed.Count) {
        # Nothing was unlinked, so there is nothing to verify. Reporting VERIFIED here
        # would be a lie: it would tell the operator the fix worked when it never ran.
        # If no accounts were registered at all, that is a different, expected outcome.
        if (-not (Test-Path -LiteralPath $accountsKey)) {
            Write-Log 'NOTHING-TO-DO: no OneDrive account is registered for this user.'
        }
        else {
            Write-Log 'NOTHING-TO-DO: an account is registered but it did not match the requested one.'
        }
        return
    }

    # ---- verification ------------------------------------------------------
    # The only proof that the fix worked is OneDrive signing back in by itself and
    # re-creating the account registration. Watch for it in the user's own hive.
    # Only accounts that had a folder were real. Empty registrations (no folder, no email)
    # are leftovers; OneDrive will never re-create them, so requiring them back would make
    # every run look like a partial failure.
    $required = @($removed | Where-Object { $removedFolder[$_] })
    $ghosts   = @($removed | Where-Object { -not $removedFolder[$_] })
    if ($ghosts.Count) {
        Write-Log ('Removed {0} empty leftover registration(s) that will not come back: {1}' -f `
                    $ghosts.Count, ($ghosts -join ', '))
    }
    if (-not $required.Count) {
        Write-Log 'NOTHING-TO-DO: only empty registrations were found; no real account was unlinked.'
        return
    }

    $waitSeconds = 120
    Write-Log ('Waiting up to {0}s for OneDrive to sign back in and re-register {1} account(s): {2}' -f `
                $waitSeconds, $required.Count, ($required -join ', '))
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    $returned = @()
    $lastNote = Get-Date
    while ($returned.Count -lt $required.Count -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $accountsKey) {
            $present = @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty PSChildName)
            $returned = @($required | Where-Object { $present -contains $_ })
        }
        if ($returned.Count -lt $required.Count -and ((Get-Date) - $lastNote).TotalSeconds -ge 15) {
            $missingNow = @($required | Where-Object { $returned -notcontains $_ })
            Write-Log ('  still waiting - back: {0} | not back: {1}' -f `
                        $(if ($returned.Count) { $returned -join ', ' } else { 'none' }), ($missingNow -join ', '))
            $lastNote = Get-Date
        }
    }

    # Per-account truth. Any single account returning is NOT success - unlinking three and
    # getting one back leaves the other two broken, which is exactly what must not be
    # reported as verified.
    foreach ($n in $required) {
        if ($returned -contains $n) {
            $k = Get-ItemProperty ("HKCU:\Software\Microsoft\OneDrive\Accounts\$n") -ErrorAction SilentlyContinue
            Write-Log ('  {0}: signed back in  ({1})' -f $n, $(if ($k.UserEmail) { $k.UserEmail } else { 'no email recorded' }))
        }
        else {
            Write-Log ('  {0}: NOT signed back in' -f $n)
        }
    }

    if ($returned.Count -eq 0) {
        Write-Log 'VERIFICATION FAILED: no account signed back in.'
        Write-Log '  A OneDrive sign-in window is probably waiting on the user desktop.'
    }
    elseif ($returned.Count -lt $removed.Count) {
        $missing = @($removed | Where-Object { $returned -notcontains $_ })
        Write-Log ('PARTIAL-RESTORED: {0} of {1} accounts signed back in. Still missing: {2}' -f `
                    $returned.Count, $required.Count, ($missing -join ', '))
        Write-Log '  Those accounts need a sign-in (user action), or SilentAccountConfig enabled.'
    }
    else {
        Write-Log ('VERIFIED-COMPLETE: all {0} account(s) signed back in and re-registered.' -f $required.Count)
    }
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
    $haveFile = $self -and (Test-Path -LiteralPath $self)
    if (-not $haveFile -and -not $script:SelfText) {
        throw 'Cannot determine this script''s own source. Save it as a .ps1 file and run it as a file.'
    }
    $stageDir = 'C:\ProgramData\OneDriveRelink'
    $null = New-Item -ItemType Directory -Path $stageDir -Force
    $staged = $stageDir + '\Reset-OneDriveLink.ps1'
    if ($haveFile -and (Resolve-Path -LiteralPath $self).Path -eq $staged) {
        Write-Log "Already staged at: $staged"
    }
    elseif ($haveFile) {
        Copy-Item -LiteralPath $self -Destination $staged -Force
        Write-Log "Staged copy: $staged"
    }
    else {
        # Running from text: write the text back out so the task has something to run.
        Set-Content -LiteralPath $staged -Value $script:SelfText -Encoding UTF8
        Write-Log "Staged a copy of the running script text: $staged"
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
    $runStart  = (Get-Date).AddSeconds(-3)
    $logDir    = '{0}\AppData\Local\OneDriveRelink' -f $profileDir
    $task = $null
    $info = $null
    $logPath = $null
    $shown = 0
    $allText = ''
    $script:Verified = $false

    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Log 'Started. Live output from the user session follows.'
        Write-Host ''

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $lastNote = Get-Date
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 700

            # pick up the payload's log as soon as it exists, then stream it
            if (-not $logPath) {
                $cand = Get-ChildItem -LiteralPath $logDir -Filter 'Relink-*.log' -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -ge $runStart } |
                            Sort-Object LastWriteTime | Select-Object -Last 1
                if ($cand) {
                    $logPath = $cand.FullName
                    Write-Log ('Live log: {0}' -f $logPath)
                }
            }
            if ($logPath -and (Test-Path -LiteralPath $logPath)) {
                $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $shown) {
                    $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host ('    {0}' -f $_) }
                    $shown = $lines.Count
                    $allText = $lines -join "`n"
                }
            }

            if ($allText -match '(?m).*(VERIFIED-COMPLETE|VERIFICATION FAILED|VERIFICATION SKIPPED|NOTHING-TO-DO)') { break }

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
            # Task finished but nothing terminal was written: give it a moment, then stop.
            if ($task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -ge $notBefore) {
                Start-Sleep -Milliseconds 800
                if ($logPath -and (Test-Path -LiteralPath $logPath)) {
                    $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
                    if ($lines.Count -gt $shown) {
                        $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host ('    {0}' -f $_) }
                        $shown = $lines.Count
                        $allText = $lines -join "`n"
                    }
                }
                if ($allText -match 'VERIFIED-COMPLETE|VERIFICATION FAILED|VERIFICATION SKIPPED|NOTHING-TO-DO') { break }
                Write-Log 'Payload exited without reporting a verdict.'
                break
            }

            if (((Get-Date) - $lastNote).TotalSeconds -ge 30) {
                Write-Log ('  still working - {0}s elapsed' -f [int](((Get-Date) - $startedAt).TotalSeconds))
                $lastNote = Get-Date
            }
        }

        if ($allText -match 'VERIFIED-COMPLETE') {
            $script:Verified = $true
            Write-Log 'Payload verified the re-link.'
        }
        elseif ($allText -match 'VERIFICATION SKIPPED') {
            Write-Log 'Payload skipped verification (-NoRestart).'
        }
        elseif ($allText -match 'PARTIAL-RESTORED') {
            $script:Partial = $true
            Write-Log 'Only some accounts signed back in.'
        }
        elseif ($allText -match 'NOTHING-TO-DO') {
            $script:Nothing = $true
            Write-Log 'Payload found nothing to unlink.'
        }
        elseif ($allText -match 'VERIFICATION FAILED') {
            Write-Log 'Payload could not confirm the re-link.'
        }
        else {
            Write-Log ('No verdict after {0}s (task state: {1}). The payload may still be running.' -f `
                        $TimeoutSeconds, $(if ($task) { $task.State } else { 'unknown' }))
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Task removed: $taskName"
    }

    # -- where to look afterwards ---------------------------------------------
    if ($logPath) { Write-Log "Log kept at: $logPath" }
    $backups = Get-ChildItem -LiteralPath $logDir -Filter '*.reg' -ErrorAction SilentlyContinue
    if ($backups) {
        Write-Log 'Registry backups (revert with: reg import <file>):'
        $backups | Sort-Object LastWriteTime -Descending | Select-Object -First 3 |
            ForEach-Object { Write-Host ('    {0}' -f $_.FullName) }
    }
}

# =============================================================================
#  MAIN
# =============================================================================
$script:Verified = $false
$script:Nothing  = $false
$script:Partial  = $false
$script:ExitCode = 0

# NOTE: never 'exit' here. This script is run from text (pasted, or fetched and invoked
# in memory), and 'exit' in that context terminates the host - which closes the console
# the operator is working in. A return code is set instead and the caller decides.
try {
    $ident    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $ident.IsSystem

    if ($Payload -or -not $isSystem) {
        # Running as the user (or as the scheduled task) - do the work.
        Invoke-OneDriveWork -Account $Account -UseReset:$UseReset -NoRestart:$NoRestart
    }
    else {
        # Running as SYSTEM - bridge into the logged-on user's session.
        Write-Log "SYSTEM mode on $env:COMPUTERNAME - bridging into the logged-on user session"
        Invoke-AsLoggedOnUser -User $User -Account $Account -UseReset:$UseReset `
            -NoRestart:$NoRestart -TimeoutSeconds $TimeoutSeconds
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    $script:ExitCode = 1
    $script:Verified = $false
}

Write-Host ''
if ($script:ExitCode -ne 0) {
    Write-Host 'RESULT: FAILED - see the message above.' -ForegroundColor Red
}
elseif ($script:Verified) {
    Write-Host 'RESULT: VERIFIED - OneDrive is unlinked, re-linked and signed back in.' -ForegroundColor Green
    Write-Host '        The account re-registered itself; no further action needed.'
}
elseif ($Script:Partial) {
    Write-Host 'RESULT: PARTIAL - some accounts did not sign back in.' -ForegroundColor Yellow
    Write-Host '        The log lists each account and whether it returned. Missing ones need a'
    Write-Host '        sign-in, or SilentAccountConfig enabled.'
}
elseif ($Script:Nothing) {
    Write-Host 'RESULT: NOTHING TO DO - no OneDrive account matched, so nothing was unlinked.' -ForegroundColor Yellow
    Write-Host '        The log lists the accounts that ARE registered, if any.'
}
elseif ($NoRestart) {
    Write-Host 'RESULT: UNLINKED - OneDrive left stopped (-NoRestart), so nothing was re-linked.' -ForegroundColor Yellow
}
else {
    Write-Host 'RESULT: NOT VERIFIED - OneDrive did not re-register within the wait.' -ForegroundColor Yellow
    Write-Host '        If a sign-in window is open on the user desktop, it needs answering.'
    Write-Host '        Re-run to check again, or read the log named above.'
}
