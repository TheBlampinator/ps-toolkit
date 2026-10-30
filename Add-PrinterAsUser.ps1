<#
.SYNOPSIS
    Add a network printer as the logged-on user. Single file, works from a SYSTEM
    shell (ScreenConnect Backstage / Commands tab) or directly as the user.

.DESCRIPTION
    Why this needs to be more than "Add-PrinterConnection": a printer connection is
    per-user data. It lives in HKCU\Printers\Connections and in the user's own
    Win32_Printer view. Run the cmdlet from Backstage and it executes as SYSTEM, so
    the connection is created for the SYSTEM profile - the user sees nothing, and
    you'll have "fixed" it while the user still has no printer.

    The script picks its own mode:

      * Running as the logged-on user (manual, Intune "logged on credentials",
        GPO logon script) - adds the printer right there.

      * Running as NT AUTHORITY\SYSTEM (Backstage, Commands tab, PsExec -s) - stages
        a copy of itself in C:\ProgramData\PrinterToolkit and registers a one-shot
        scheduled task that re-invokes it with -Payload under the interactive user's
        token, then waits, verifies, prints the log and deletes the task. No desktop
        session, no screen share.

    The work itself:
      1. Normalises \\server\printer and checks it isn't already present.
      2. Adds the connection (Add-PrinterConnection, falling back to printui.dll).
      3. Optionally sets it as the user's default printer.
      4. VERIFIES from HKCU\Printers\Connections and the user's Win32_Printer list,
         and exits non-zero if the connection really isn't there.

.PARAMETER PrinterPath
    UNC path of the shared printer, e.g. \\print01\FIN-HP4525. Required.

.PARAMETER SetDefault
    Make it the user's default printer after adding.

.PARAMETER User
    SYSTEM mode only: DOMAIN\username to target. Omit to auto-detect; refuses to
    guess when more than one interactive user is logged on.

.PARAMETER Elevated
    SYSTEM mode only: run the task with the user's elevated (administrator) token
    instead of the normal one. Needed when the printer's driver is not already
    installed on the machine and Point-and-Print driver installation is restricted
    (RestrictDriverInstallationToAdministrators). Triggers no UAC prompt.

.PARAMETER Remove
    Remove the connection instead of adding it.

.PARAMETER Verify
    Do not change anything. Report whether the connection is present for the user,
    and exit non-zero if it is not. Use this to answer "did it work?".

.PARAMETER TimeoutSeconds
    SYSTEM mode only: how long to wait. Default 300.

.PARAMETER Payload
    Internal. Set by the scheduled task. Do not pass it.

.EXAMPLE
    .\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525'
    From Backstage: adds it for the logged-on user.

.EXAMPLE
    .\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -SetDefault

.EXAMPLE
    .\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Elevated
    When the driver isn't on the box yet and non-admin driver install is blocked.

.EXAMPLE
    .\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Remove

.EXAMPLE
    .\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -User 'CONTOSO\jsmith'
    From Backstage when several users are logged on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrinterPath,
    [switch]$SetDefault,
    [string]$User,
    [switch]$Elevated,
    [switch]$Remove,
    [switch]$Verify,
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

function Get-ConnectionRegistryName {
    # HKCU\Printers\Connections subkeys look like ",,server,printer"
    param([string]$UncPath)
    $parts = $UncPath.TrimStart('\').Split('\')
    ',,' + ($parts -join ',')
}

# =============================================================================
#  PAYLOAD - the actual work. Must run as the logged-on user.
# =============================================================================
function Invoke-AddPrinterWork {
    param(
        [string]$PrinterPath,
        [switch]$SetDefault,
        [switch]$Remove,
        [switch]$Verify
    )

    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Payload must run as the logged-on user, not SYSTEM. In SYSTEM mode this script bridges itself.'
    }

    if ($Remove -and $Verify) { throw '-Remove and -Verify are mutually exclusive.' }

    $PrinterPath = $PrinterPath.TrimEnd('\')
    if ($PrinterPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
        throw "PrinterPath must look like \\server\printer - got '$PrinterPath'"
    }

    $logDir = '{0}\AppData\Local\PrinterToolkit' -f $env:USERPROFILE
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $script:LogFile = '{0}\AddPrinter-{1}.log' -f $logDir, $stamp

    Write-Log "Add-printer started for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
    Write-Log "Identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Queue:    $PrinterPath"
    Write-Log "Mode:     $(if ($Remove) { 'remove' } else { 'add' })$(if ($SetDefault) { ' + set default' })"

    $connKey = 'HKCU:\Printers\Connections'
    $subKey  = Get-ConnectionRegistryName -UncPath $PrinterPath
    $connPath = $connKey + '\' + $subKey

    $installed = @(
        Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $PrinterPath }
    )
    Write-Log "Visible in the user's printer list before: $([bool]$installed)"
    Write-Log "Per-user connection key before: $(Test-Path -LiteralPath $connPath)"

    if ($Verify) {
        # Read-only: the same checks the add path uses, but nothing is changed.
        $keyPresent = Test-Path -LiteralPath $connPath
        $isDefault  = @($installed | Where-Object { $_.Default }).Count -gt 0
        Write-Log "VERIFY key path       : $connPath"
        Write-Log "VERIFY key present    : $keyPresent"
        Write-Log "VERIFY visible to user: $([bool]$installed)"
        Write-Log "VERIFY is default     : $isDefault"
        if (-not $keyPresent -or -not $installed) {
            throw "NOT CONNECTED: $PrinterPath is not present for $env:USERNAME."
        }
        $conn = $installed | Select-Object -First 1
        Write-Log ('VERIFY queue          : {0}' -f $conn.Name)
        Write-Log ('VERIFY driver / port  : {0} / {1}' -f $conn.DriverName, $conn.PortName)
        Write-Log 'Verified: the connection is present for this user.'
        return
    }

    if ($Remove) {
        if ($installed -and (Get-Command Remove-PrinterConnection -ErrorAction SilentlyContinue)) {
            try {
                Remove-PrinterConnection -Name $PrinterPath -ErrorAction Stop
                Write-Log 'Remove-PrinterConnection succeeded.'
            }
            catch {
                Write-Log "Remove-PrinterConnection failed: $($_.Exception.Message)"
            }
        }
        # /dn also cleans up a stale connection key when the printer is not visible.
        $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                -ArgumentList ('printui.dll,PrintUIEntry /dn /q /n "{0}"' -f $PrinterPath)
        Write-Log "printui /dn exit code: $($p.ExitCode)"
        Start-Sleep -Seconds 1
        $stillThere = Test-Path -LiteralPath $connPath
        Write-Log "Per-user connection key after: $stillThere"
        if ($stillThere) { throw "Printer connection $PrinterPath is still present for $env:USERNAME." }
        Write-Log 'Removed successfully.'
        return
    }

    # ---- add it -------------------------------------------------------------
    if ($installed) {
        Write-Log 'Already connected for this user - not adding again.'
    }
    else {
        $added = $false
        if (Get-Command Add-PrinterConnection -ErrorAction SilentlyContinue) {
            try {
                Add-PrinterConnection -ConnectionName $PrinterPath -ErrorAction Stop
                $added = $true
                Write-Log 'Add-PrinterConnection succeeded.'
            }
            catch {
                Write-Log "Add-PrinterConnection failed: $($_.Exception.Message)"
                Write-Log 'Trying printui.dll next (common cause: driver not installed / Point-and-Print restricted).'
            }
        }
        if (-not $added) {
            $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                    -ArgumentList ('printui.dll,PrintUIEntry /in /q /n "{0}"' -f $PrinterPath)
            Write-Log "printui /in exit code: $($p.ExitCode)"
        }
        Start-Sleep -Seconds 2
    }

    # ---- verify (write, then read back) -------------------------------------
    $present = Test-Path -LiteralPath $connPath
    $visible = @(
        Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $PrinterPath }
    )
    Write-Log "Per-user connection key after: $present"
    Write-Log "Visible in the user's printer list after: $([bool]$visible)"

    if (-not $present -or -not $visible) {
        throw ("Printer $PrinterPath was NOT connected for $env:USERNAME. " +
               'Usually the driver is missing and non-admin driver install is blocked - retry with -Elevated.')
    }

    # ---- default ------------------------------------------------------------
    if ($SetDefault) {
        $target = $visible | Select-Object -First 1
        try {
            Invoke-CimMethod -InputObject $target -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
            Write-Log 'SetDefaultPrinter invoked.'
        }
        catch {
            $p = Start-Process -FilePath 'rundll32.exe' -PassThru -Wait `
                    -ArgumentList ('printui.dll,PrintUIEntry /y /q /n "{0}"' -f $PrinterPath)
            Write-Log "printui /y exit code: $($p.ExitCode)"
        }
        $default = @(
            Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
                Where-Object { $_.Default }
        ) | Select-Object -First 1
        if ($default) { Write-Log "Default printer now: $($default.Name)" }
        if (-not $default -or $default.Name -ne $PrinterPath) {
            throw "Could not confirm $PrinterPath as the default printer for $env:USERNAME."
        }
    }

    Write-Log "All connections for $env:USERNAME now:"
    Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object {
            Write-Log ('  {0}{1}  {2}' -f $_.Name, $(if ($_.Default) { ' [default]' } else { '' }), $_.PortName)
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
        [string]$PrinterPath,
        [switch]$SetDefault,
        [switch]$Remove,
        [switch]$Verify,
        [switch]$Elevated,
        [int]$TimeoutSeconds
    )

    # -- who can we target? ---------------------------------------------------
    $users = @(
        Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -and $_.UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' } |
            Select-Object -ExpandProperty UserName -Unique
    )
    if ($users.Count -eq 0) {
        throw 'No interactive user session found. Nobody is logged on; a printer connection cannot be added for them.'
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

    # -- can we reach the queue at all? --------------------------------------
    $server = $PrinterPath.TrimStart('\').Split('\')[0]
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($server) | Select-Object -First 1
        Write-Log "Print server $server resolves to $($resolved.IPAddressToString)"
    }
    catch {
        Write-Log "WARNING: cannot resolve print server '$server' from here - the add will probably fail."
    }

    # -- stage a readable copy of this same file -----------------------------
    $self = $script:SelfPath
    if (-not $self -or -not (Test-Path -LiteralPath $self)) {
        throw 'Cannot determine this script''s own path. Save it as a .ps1 file and run it as a file.'
    }
    $stageDir = 'C:\ProgramData\PrinterToolkit'
    $null = New-Item -ItemType Directory -Path $stageDir -Force
    $staged = $stageDir + '\Add-PrinterAsUser.ps1'
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
    $taskName = 'AddPrinter-' + $stamp
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $staged), '-Payload',
        '-PrinterPath', ('"{0}"' -f $PrinterPath)
    )
    if ($SetDefault) { $argList += '-SetDefault' }
    if ($Remove) { $argList += '-Remove' }
    if ($Verify) { $argList += '-Verify' }
    $argLine = $argList -join ' '

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    # Limited = the user's normal token, which is what a printer connection should be
    # created with. -Elevated only for driver installation on restricted builds.
    $runLevel  = if ($Elevated) { 'Highest' } else { 'Limited' }
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $runLevel
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                     -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Write-Log "Registering task $taskName (run level $runLevel)"
    Write-Log "  powershell.exe $argLine"
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
        -Settings $settings -Force | Out-Null

    $startedAt = Get-Date
    $task = $null
    $info = $null
    $done = $false
    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Log 'Started. Waiting for the user-session run...'

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) { $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue }
            $done = $task -and $task.State -ne 'Running' -and $info -and $info.LastRunTime -gt $startedAt
        } while (-not $done -and (Get-Date) -lt $deadline)

        if (-not $done) {
            Write-Log "TIMED OUT after $TimeoutSeconds s (state: $($task.State)). The payload may still be running."
        }
        elseif ($info.LastTaskResult -eq 0) {
            Write-Log 'Task exit code 0 - printer connection confirmed.'
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
    $logDir = '{0}\AppData\Local\PrinterToolkit' -f $profileDir
    if (Test-Path -LiteralPath $logDir) {
        $log = Get-ChildItem -LiteralPath $logDir -Filter 'AddPrinter-*.log' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            Write-Log "Log: $($log.FullName)"
            Get-Content -LiteralPath $log.FullName | ForEach-Object { Write-Host "    $_" }
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
        Invoke-AddPrinterWork -PrinterPath $PrinterPath -SetDefault:$SetDefault -Remove:$Remove -Verify:$Verify
        exit 0
    }

    Write-Log "SYSTEM mode on $env:COMPUTERNAME - bridging into the logged-on user session"
    Invoke-AsLoggedOnUser -User $User -PrinterPath $PrinterPath -SetDefault:$SetDefault `
        -Remove:$Remove -Verify:$Verify -Elevated:$Elevated -TimeoutSeconds $TimeoutSeconds
    Write-Log 'Completed successfully.'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
