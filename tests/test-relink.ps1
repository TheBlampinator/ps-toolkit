# Mock harness for the payload half of Reset-OneDriveLink-2.ps1 (Invoke-OneDriveWork):
# account matching and the verdict markers, against a throwaway registry key under
# HKCU:\Software\PsToolkitTest. Proves control flow only - it says nothing about real
# OneDrive behaviour. The key and the temp folder are removed at the end.

$ErrorActionPreference = 'Stop'
$testRoot = 'HKCU:\Software\PsToolkitTest'
$accounts = "$testRoot\OneDrive\Accounts"
$work = Join-Path $env:TEMP ('PsToolkitTest-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$env:LOCALAPPDATA = $work          # the payload logs under LOCALAPPDATA\OneDriveRelink

# --- load ONLY the function definitions, with the accounts key and the wait rewired ---
$src  = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Reset-OneDriveLink-2.ps1'))
$cut  = $src.IndexOf('#  MAIN')
$body = $src.Substring(0, $src.LastIndexOf('# ====', $cut))
$body = $body.Replace("'HKCU:\Software\Microsoft\OneDrive\Accounts'", "'$accounts'")
$body = $body.Replace('"HKCU:\Software\Microsoft\OneDrive\Accounts\$n"', ('"' + $accounts + '\$n"'))
$body = $body.Replace('$waitSeconds = 120', '$waitSeconds = 1')
Invoke-Expression $body

# --- stubs for everything that touches the real machine ---------------------------
function Get-OneDriveExe { 'C:\fake\OneDrive.exe' }
function Stop-OneDrive   { }
function Start-Sleep     { [CmdletBinding()] param([int]$Seconds, [int]$Milliseconds) }
function Get-Process     { [CmdletBinding()] param([string]$Name) $null }
function reg.exe         { $global:LASTEXITCODE = 0 }
$script:SignBackIn = $null       # set to an account name to make "OneDrive" re-register it
function Start-Process {
    [CmdletBinding()] param([string]$FilePath, $ArgumentList, [switch]$Wait)
    if ($script:SignBackIn) {
        $null = New-Item -Path "$accounts\$($script:SignBackIn)" -Force
        New-ItemProperty -Path "$accounts\$($script:SignBackIn)" -Name UserEmail -Value 'back@contoso.com' -PropertyType String | Out-Null
    }
}

function Seed {
    param([hashtable]$Accts)
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path $accounts -Force
    foreach ($n in $Accts.Keys) {
        $null = New-Item -Path "$accounts\$n" -Force
        foreach ($p in $Accts[$n].Keys) {
            New-ItemProperty -Path "$accounts\$n" -Name $p -Value $Accts[$n][$p] -PropertyType String | Out-Null
        }
    }
}
function Run {
    param([string]$Account)
    $script:stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Invoke-OneDriveWork -Account $Account *>&1 | Out-Null
    [IO.File]::ReadAllText($script:LogFile)
}
function Has { param([string]$Name) Test-Path -LiteralPath "$accounts\$Name" }

$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" } else { Write-Host "  FAIL  $name"; $script:fail++ }
}

# The real-world case: a signed-in work account with no folder yet, plus two empty
# leftovers. "Work or school" must unlink the work accounts and leave Personal alone.
$motrad = @{ Business1 = @{ UserEmail = 'mo.trad@projxco.com' }; Business2 = @{}; Personal = @{} }

Seed $motrad
$log = Run 'Business'
Check 'Business: unlinks Business1'                 ($log -match 'Unlinking Business1 \(mo\.trad@projxco\.com\)')
Check 'Business: Business2 flagged as leftover'     ($log -match 'Unlinking Business2 .*empty leftover')
Check 'Business: leaves Personal alone'             ($log -notmatch 'Unlinking Personal' -and (Has 'Personal'))
Check 'Business: email-only account counts as real' ($log -match 'VERIFICATION FAILED' -and $log -notmatch 'NOTHING-TO-DO|CLEANED-UP')
Check 'Business: no "no account matched"'           ($log -notmatch 'No account matched')

Seed $motrad
$log = Run 'All'
Check 'All: unlinks all three'                      ($log -match 'Unlinking Business1' -and $log -match 'Unlinking Business2' -and $log -match 'Unlinking Personal')
Check 'All: no fallback needed'                     ($log -notmatch 'treating every registered account')
Check 'All: waits for the real one, not "nothing"'  ($log -match 'VERIFICATION FAILED' -and $log -notmatch 'NOTHING-TO-DO')

Seed $motrad
$log = Run 'Personal'
Check 'Personal: only Personal removed'             ($log -match 'Unlinking Personal' -and $log -notmatch 'Unlinking Business' -and (Has 'Business1'))
Check 'Personal: leftover-only run says CLEANED-UP' ($log -match 'CLEANED-UP: removed 1 empty' -and $log -notmatch 'NOTHING-TO-DO')

Seed @{ Personal = @{ UserEmail = 'me@outlook.com'; UserFolder = 'C:\Users\x\OneDrive' } }
$log = Run 'Business'
Check 'no match: says which accounts exist'         ($log -match "Accounts registered for this user: Personal" -and $log -match "No account matched 'Business'")
Check 'no match: NOTHING-TO-DO, nothing removed'    ($log -match 'NOTHING-TO-DO' -and (Has 'Personal'))

Seed @{ Business1 = @{ UserEmail = 'j@contoso.com'; UserFolder = 'C:\Users\j\OneDrive - Contoso' } }
$script:SignBackIn = 'Business1'
$log = Run 'Business'
$script:SignBackIn = $null
Check 'signed back in: VERIFIED-COMPLETE'           ($log -match 'VERIFIED-COMPLETE: all 1 account')

Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n  failures: $fail"
exit $fail
