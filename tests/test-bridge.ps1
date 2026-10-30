# Mock harness: exercises the SYSTEM-mode bridge of Reset-OneDriveLink-2.ps1 against
# stubbed Windows cmdlets. Proves control flow and argument construction only -
# it says nothing about real Task Scheduler / OneDrive behaviour.

$ErrorActionPreference = 'Stop'
$Rec = @{ registered = $null; started = $false; unregistered = $false; action = $null;
          principal = $null; settings = $null; copied = $null; cimi = $null }

function Get-Process {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [switch]$IncludeUserName)
    if ($Name -eq 'explorer') { return [pscustomobject]@{ UserName = 'CONTOSO\jsmith'; Id = 4242 } }
    return $null
}
function Start-Sleep { [CmdletBinding()] param([int]$Seconds) }
function Test-Path  { [CmdletBinding()] param([string]$LiteralPath, [string]$Path) return $true }
function New-Item   { [CmdletBinding()] param([string]$ItemType, [string]$Path, [switch]$Force) return $null }
function Copy-Item  { [CmdletBinding()] param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                      $Rec.copied = "$LiteralPath -> $Destination" }
function Resolve-Path { [CmdletBinding()] param([string]$LiteralPath)
                      [pscustomobject]@{ Path = $LiteralPath } }
function Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
    [pscustomobject]@{ SilentAccountConfig = 1 }
}
function Get-CimInstance {
    [CmdletBinding()] param([string]$ClassName, [string]$Filter)
    $Rec.cimi = $Filter
    [pscustomobject]@{ LocalPath = 'C:\Users\jsmith' }
}
function Get-ChildItem {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Filter)
    switch ($Filter) {
        'Relink-*.log' { [pscustomobject]@{ FullName = 'C:\Users\jsmith\AppData\Local\OneDriveRelink\Relink-20261030-120000.log';
                                            LastWriteTime = Get-Date } }
        '*.reg'        { [pscustomobject]@{ FullName = 'C:\Users\jsmith\AppData\Local\OneDriveRelink\OneDrive-Business1-20261030-120000.reg' } }
        default        { $null }
    }
}
function Get-Content { [CmdletBinding()] param([string]$LiteralPath)
    @('2026-10-30T12:00:01  OneDrive re-link started for CONTOSO\jsmith on PC01',
      '2026-10-30T12:00:02  Unlinking Business1 (jsmith@contoso.com)',
      '2026-10-30T12:00:04  Completed successfully.') }

# --- Task Scheduler surface -------------------------------------------------
function New-ScheduledTaskAction {
    [CmdletBinding()] param([string]$Execute, [string]$Argument)
    $Rec.action = [pscustomobject]@{ Execute = $Execute; Argument = $Argument }; $Rec.action
}
function New-ScheduledTaskPrincipal {
    [CmdletBinding()] param([string]$UserId, [string]$LogonType, [string]$RunLevel)
    $Rec.principal = [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    $Rec.principal
}
function New-ScheduledTaskSettingsSet {
    [CmdletBinding()] param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries,
                             [switch]$StartWhenAvailable, $ExecutionTimeLimit)
    $Rec.settings = [pscustomobject]@{ AllowStartIfOnBatteries = [bool]$AllowStartIfOnBatteries
                                       StartWhenAvailable      = [bool]$StartWhenAvailable
                                       ExecutionTimeLimit      = $ExecutionTimeLimit }
    $Rec.settings
}
function Register-ScheduledTask {
    [CmdletBinding()] param($TaskName, $Action, $Principal, $Settings, [switch]$Force)
    $Rec.registered = $TaskName
}
function Start-ScheduledTask { [CmdletBinding()] param($TaskName); $Rec.started = $true }
function Get-ScheduledTask {
    [CmdletBinding()] param($TaskName)
    [pscustomobject]@{ TaskName = $TaskName; State = 'Ready' }
}
function Get-ScheduledTaskInfo {
    [CmdletBinding()] param($TaskName)
    [pscustomobject]@{ LastTaskResult = 0; LastRunTime = (Get-Date).AddSeconds(5) }
}
function Unregister-ScheduledTask {
    [CmdletBinding()] param($TaskName, [switch]$Confirm)
    $Rec.unregistered = $true
}

# --- load ONLY the function definitions from the real script ----------------
$src  = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Reset-OneDriveLink-2.ps1'))
$cut  = $src.IndexOf('#  MAIN')
$body = $src.Substring(0, $src.LastIndexOf('# ====', $cut))
Invoke-Expression $body

Write-Host "`n================ BRIDGE RUN ================`n"
Invoke-AsLoggedOnUser -User $null -Account 'All' -TimeoutSeconds 30

Write-Host "`n================ ASSERTIONS ================`n"
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" } else { Write-Host "  FAIL  $name"; $script:fail++ }
}
Check 'target user auto-detected'          ($Rec.principal.UserId -eq 'CONTOSO\jsmith')
Check 'logon type Interactive'             ($Rec.principal.LogonType -eq 'Interactive')
Check 'run level Limited (not elevated)'   ($Rec.principal.RunLevel -eq 'Limited')
Check 'runs on battery'                    ($Rec.settings.AllowStartIfOnBatteries)
Check 'executable is powershell.exe'       ($Rec.action.Execute -eq 'powershell.exe')
Check 'arg has -Payload'                   ($Rec.action.Argument -match '-Payload')
Check 'arg has -Account All'               ($Rec.action.Argument -match '-Account All')
Check 'arg has -File "staged path"'        ($Rec.action.Argument -match '-File "C:\\ProgramData\\OneDriveRelink\\Reset-OneDriveLink\.ps1"')
Check 'task registered'                    ($null -ne $Rec.registered)
Check 'task started'                       ($Rec.started)
Check 'task cleaned up'                    ($Rec.unregistered)
Check 'profile resolved by SID filter'     ($Rec.cimi -match "SID='S-1-5-21")
Write-Host "`n  argument line:`n    $($Rec.action.Argument)"
Write-Host "`n  failures: $fail"
exit $fail
