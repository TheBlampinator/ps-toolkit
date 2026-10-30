# Mock harness for Add-PrinterAsUser.ps1: exercises the SYSTEM-mode bridge plus the
# pure-logic helpers against stubbed Windows cmdlets. Proves control flow and argument
# construction only - nothing about real printer/registry/Point-and-Print behaviour.

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
function Get-CimInstance {
    [CmdletBinding()] param([string]$ClassName, [string]$Filter)
    if ($ClassName -eq 'Win32_UserProfile') { $Rec.cimi = $Filter; return [pscustomobject]@{ LocalPath = 'C:\Users\jsmith' } }
}
function Get-ChildItem {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Filter)
    if ($Filter -eq 'AddPrinter-*.log') {
        [pscustomobject]@{ FullName = 'C:\Users\jsmith\AppData\Local\PrinterToolkit\AddPrinter-20261030-120000.log'
                           LastWriteTime = Get-Date }
    }
}
function Get-Content { [CmdletBinding()] param([string]$LiteralPath)
    @('2026-10-30T12:00:01  Add-printer started for CONTOSO\jsmith on PC01',
      '2026-10-30T12:00:02  Add-PrinterConnection succeeded.',
      '2026-10-30T12:00:03  Per-user connection key after: True',
      '2026-10-30T12:00:04  Completed successfully.') }
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
                                       ExecutionTimeLimit      = $ExecutionTimeLimit }
    $Rec.settings
}
function Register-ScheduledTask { [CmdletBinding()] param($TaskName, $Action, $Principal, $Settings, [switch]$Force)
                                  $Rec.registered = $TaskName }
function Start-ScheduledTask { [CmdletBinding()] param($TaskName); $Rec.started = $true }
function Get-ScheduledTask { [CmdletBinding()] param($TaskName)
                             [pscustomobject]@{ TaskName = $TaskName; State = 'Ready' } }
function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskName)
                                 [pscustomobject]@{ LastTaskResult = 0; LastRunTime = (Get-Date).AddSeconds(5) } }
function Unregister-ScheduledTask { [CmdletBinding()] param($TaskName, [switch]$Confirm); $Rec.unregistered = $true }

# --- load ONLY the function definitions from the real script ----------------
$src  = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Add-PrinterAsUser.ps1'))
$cut  = $src.IndexOf('#  MAIN')
$body = $src.Substring(0, $src.LastIndexOf('# ====', $cut))
Invoke-Expression $body

Write-Host "`n============ PURE-LOGIC HELPERS ============`n"
$fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { Write-Host "  PASS  $name" }
    else { Write-Host "  FAIL  $name  $(if ($detail) { '-> ' + $detail })"; $script:fail++ }
}

Check 'reg name \\print01\FIN-HP4525' `
    ((Get-ConnectionRegistryName -UncPath '\\print01\FIN-HP4525') -eq ',,print01,FIN-HP4525') `
    (Get-ConnectionRegistryName -UncPath '\\print01\FIN-HP4525')
Check 'reg name with spaces' `
    ((Get-ConnectionRegistryName -UncPath '\\PRINT-SRV\Canon iR-ADV C5535') -eq ',,PRINT-SRV,Canon iR-ADV C5535')
Check 'regex accepts \\srv\queue'  ('\\print01\FIN-HP4525' -match '^\\\\[^\\]+\\[^\\]+$')
Check 'regex rejects bare host'    ('print01' -notmatch '^\\\\[^\\]+\\[^\\]+$')
Check 'regex rejects single UNC'   ('\\print01' -notmatch '^\\\\[^\\]+\\[^\\]+$')
Check 'regex rejects subst path'   ('\\print01\q\sub' -notmatch '^\\\\[^\\]+\\[^\\]+$')
Check 'TrimEnd removes trailing \' (('\\print01\FIN-HP4525\').TrimEnd('\') -eq '\\print01\FIN-HP4525')

Write-Host "`n============ BRIDGE RUN ============`n"
Invoke-AsLoggedOnUser -User $null -PrinterPath '\\print01\FIN-HP4525' -SetDefault -TimeoutSeconds 30

Write-Host "`n============ BRIDGE ASSERTIONS ============`n"
Check 'target user auto-detected'        ($Rec.principal.UserId -eq 'CONTOSO\jsmith')
Check 'logon type Interactive'           ($Rec.principal.LogonType -eq 'Interactive')
Check 'run level Limited by default'     ($Rec.principal.RunLevel -eq 'Limited')
Check 'runs on battery'                  ($Rec.settings.AllowStartIfOnBatteries)
Check 'executable powershell.exe'        ($Rec.action.Execute -eq 'powershell.exe')
Check 'arg has -Payload'                 ($Rec.action.Argument -match '-Payload')
Check 'printer path quoted in arg'       ($Rec.action.Argument -match '-PrinterPath "\\\\print01\\FIN-HP4525"')
Check 'arg has -SetDefault'              ($Rec.action.Argument -match '-SetDefault')
Check 'no -Remove when adding'           ($Rec.action.Argument -notmatch '-Remove')
Check 'task registered'                  ($null -ne $Rec.registered)
Check 'task started'                     ($Rec.started)
Check 'task cleaned up'                  ($Rec.unregistered)
Check 'self staged to ProgramData'       ($Rec.copied -match 'ProgramData\\PrinterToolkit\\Add-PrinterAsUser\.ps1')

Write-Host "`n  argument line:`n    $($Rec.action.Argument)"

# --- -Elevated must flip the run level --------------------------------------
$Rec.principal = $null
Invoke-AsLoggedOnUser -User 'CONTOSO\jsmith' -PrinterPath '\\print01\FIN-HP4525' -Elevated -TimeoutSeconds 30 | Out-Null
Check 'Elevated -> RunLevel Highest'     ($Rec.principal.RunLevel -eq 'Highest')

# --- -Verify must propagate to the user-session payload ---------------------
$Rec.action = $null
Invoke-AsLoggedOnUser -User 'CONTOSO\jsmith' -PrinterPath '\\print01\FIN-HP4525' -Verify -TimeoutSeconds 30 | Out-Null
Check 'arg has -Verify'                  ($Rec.action.Argument -match '-Verify')
Check 'Verify still marks -Payload'      ($Rec.action.Argument -match '-Payload')
Check 'Verify carries printer path'      ($Rec.action.Argument -match 'FIN-HP4525')

Write-Host "`n  failures: $fail`n"
exit $fail
