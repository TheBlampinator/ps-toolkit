#!ps
#timeout=600000
#maxlength=1000000

<#
    ================================================================
      PS TOOLKIT - one paste, then answer questions
    ================================================================

      Paste this file (or the one-line irm form) and it asks what you
      want to do, then asks only the questions that job needs. You
      never edit a script and never remember a variable name.

        1  add a printer for the logged-in user
        2  check which printers they have (read-only)
        3  fix OneDrive (unlink and re-link)

      It does not contain any of that logic itself: it downloads the
      individual tool for the job you pick, so the tested scripts stay
      the single source of truth.

      Requires a console it can ask questions in (Backstage, or an
      interactive PowerShell window). If there is none - some Commands
      tab setups - it prints the ready-made command for each job
      instead of waiting forever on an input prompt.

      The three lines above MUST stay contiguous with no blank line
      between them, or ScreenConnect reads only #!ps and kills the
      command after 10 seconds - which is shorter than answering one
      question.
    ================================================================
#>

$ErrorActionPreference = 'Stop'
$version = '1.0.0'

# ---- published tools this menu drives --------------------------------------
# Pinned to immutable revisions. Update these three lines only when
# republishing a tool, and the menu picks up the new build.
$Urls = [ordered]@{
    PrinterSetup = 'https://gist.githubusercontent.com/TheBlampinator/84923f2c6a155cfa245a353e3e00f995/raw/84c0d270f46e00119d2f60fb3348177a967423e9/Printer-Setup-Paste.ps1'
    PrinterCheck = 'https://gist.githubusercontent.com/TheBlampinator/8905bde8066b4057770126ad5550f0ad/raw/da21a3dc1828eaee7b49b7b5a8f29be69eaaee34/Printer-Check.ps1'
    OneDrive     = 'https://gist.githubusercontent.com/TheBlampinator/4faca813edea0891225baed59a7fb2db/raw/Reset-OneDriveLink-2.ps1'
}

# Set PSToolkitDryRun=1 to see what would run without running it.
$DryRun = [bool]$env:PSToolkitDryRun

# ---- little helpers --------------------------------------------------------
function Line { param([string]$t = '') Write-Host $t }
function Rule { param([string]$c = '-') Write-Host ($c * 60) }
function Head { param([string]$t) Line ''; Rule '='; Write-Host "  $t"; Rule '=' }

function Say { param([string]$m) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $m" }

$script:NoPrompt = $false

# Ask a question. Returns $null once we know there is no console to ask in.
function Ask {
    param([string]$Prompt, [string]$Default = '')
    if ($script:NoPrompt) { return $null }
    try {
        $v = if ($Default) { Read-Host "  $Prompt [$Default]" } else { Read-Host "  $Prompt" }
    }
    catch {
        $script:NoPrompt = $true
        return $null
    }
    if ($null -eq $v) { $script:NoPrompt = $true; return $null }
    $v = ([string]$v).Trim()
    if ($v -eq '' -and $Default) { return $Default }
    return $v
}

# Yes/no with a default. Returns $true/$false, or $null when out of prompts.
function AskYN {
    param([string]$Prompt, [bool]$Default = $true)
    $d = if ($Default) { 'Y' } else { 'N' }
    $v = Ask -Prompt $Prompt -Default $d
    if ($null -eq $v) { return $null }
    return ($v -match '^y')
}

# A printer path, asked until it is valid. Blank is allowed only when
# $AllowBlank is set (the check tool can list everything instead).
function AskQueue {
    param([string]$Why, [switch]$AllowBlank)
    Line ''
    Line "  $Why"
    Line '  It looks like this:  \\SERVER\QUEUE-NAME'
    if ($AllowBlank) { Line '  (Press Enter on its own to show every printer instead.)' }
    for ($i = 0; $i -lt 5; $i++) {
        $v = Ask -Prompt '  Printer'
        if ($null -eq $v) { return $null }
        $v = $v.Trim()
        if ($v -eq '' -and $AllowBlank) { return '' }
        if ($v -eq '') {
            Line '  Nothing entered - that printer address is required here.' -ForegroundColor Yellow
            continue
        }
        if ($v -match '^\\\\[^\\]+\\[^\\]+$') { return $v }
        Line "  '$v' is not in the right form." -ForegroundColor Yellow
        Line '  Use two backslashes, then the server, then one backslash, then the queue.' -ForegroundColor DarkGray
    }
    return $null
}

# Download a tool to TEMP and return its path (or just say what would happen).
function Get-Tool {
    param([string]$Key)
    $name = @{
        PrinterSetup = 'Printer-Setup-Paste.ps1'
        PrinterCheck = 'Printer-Check.ps1'
        OneDrive     = 'Reset-OneDriveLink-2.ps1'
    }[$Key]
    $dest = Join-Path $env:TEMP $name
    if ($DryRun) { Say "DRY RUN - would download $Key to $dest"; return $dest }
    Write-Host '  fetching the tool...' -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $Urls[$Key] -OutFile $dest -UseBasicParsing
    }
    catch {
        Line ''
        Line '  Could not download the tool for this job.' -ForegroundColor Red
        Line "  $($_.Exception.Message)" -ForegroundColor DarkGray
        Line '  Either the PC cannot reach gist.githubusercontent.com, or a proxy is' -ForegroundColor Yellow
        Line '  blocking it. Save the file locally and run it instead.' -ForegroundColor Yellow
        return $null
    }
    return $dest
}

# Clear every variable this toolkit uses, so one job cannot inherit the
# settings of the last one.
function Reset-Env {
    foreach ($n in 'PrinterSetupPath','PrinterSetupDefault','PrinterSetupElevated',
                   'PrinterSetupUser','PrinterSetupRead','PrinterSetupWait',
                   'PrinterCheckPath','PrinterCheckUser','PrinterCheckRead') {
        Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    }
}

function Run-Tool {
    param([string]$Path, [string[]]$Arguments = @())
    if ($DryRun) {
        Say ('DRY RUN - would run: {0} {1}' -f $Path, ($Arguments -join ' '))
        foreach ($n in 'PrinterSetupPath','PrinterSetupDefault','PrinterSetupElevated',
                       'PrinterSetupUser','PrinterCheckPath','PrinterCheckUser') {
            $v = [Environment]::GetEnvironmentVariable($n)
            if ($v) { Say "           $n = $v" }
        }
        return
    }
    & $Path @Arguments
}

# ---- the jobs --------------------------------------------------------------
function Job-AddPrinter {
    Head 'ADD A PRINTER FOR THE PERSON WHO IS LOGGED IN'

    $queue = AskQueue -Why 'Which printer? Type its address.'
    if ($null -eq $queue) { return }

    $isDefault = AskYN -Prompt 'Make it their default printer?' -Default $true
    if ($null -eq $isDefault) { return }

    $elevated = AskYN -Prompt 'Did a previous attempt say "Access is denied"?' -Default $false
    if ($null -eq $elevated) { return }

    $user = Ask -Prompt 'If more than one person is logged on, type DOMAIN\name (else press Enter)'
    if ($null -eq $user) { return }

    $tool = Get-Tool -Key PrinterSetup
    if (-not $tool) { return }

    Reset-Env
    $env:PrinterSetupPath = $queue
    if (-not $isDefault) { $env:PrinterSetupDefault = 'false' }
    if ($elevated)       { $env:PrinterSetupElevated = 'true' }
    if ($user)           { $env:PrinterSetupUser = $user }

    Line ''
    Say "Adding $queue"
    if (-not $isDefault) { Say '  (leaving their current default printer alone)' }
    if ($elevated)       { Say '  (using admin rights, because the driver is missing)' }
    Line ''
    Run-Tool -Path $tool
}

function Job-CheckPrinters {
    Head 'CHECK WHICH PRINTERS THEY HAVE (nothing is changed)'

    $queue = AskQueue -Why 'Which printer do you want to check for?' -AllowBlank
    if ($null -eq $queue) { return }

    $user = Ask -Prompt 'If more than one person is logged on, type DOMAIN\name (else press Enter)'
    if ($null -eq $user) { return }

    $tool = Get-Tool -Key PrinterCheck
    if (-not $tool) { return }

    Reset-Env
    if ($queue) { $env:PrinterCheckPath = $queue } else { $env:PrinterCheckPath = 'list' }
    if ($user)  { $env:PrinterCheckUser = $user }

    Line ''
    Run-Tool -Path $tool
}

function Job-OneDrive {
    Head 'FIX ONEDRIVE (unlink and re-link)'

    Line ''
    Line '  Which account?'
    Line '    1  Work or school  (the usual answer)'
    Line '    2  Personal (Microsoft account)'
    Line '    3  Both'
    $which = Ask -Prompt '  Choose 1-3' -Default '1'
    if ($null -eq $which) { return }
    $account = switch ($which) {
        '2'     { 'Personal' }
        '3'     { 'All' }
        default { 'Business' }
    }

    $restart = AskYN -Prompt 'Start OneDrive again afterwards?' -Default $true
    if ($null -eq $restart) { return }

    Line ''
    if ($restart) {
        Line '  Heads up: unless your organisation turns on silent sign-in, the user' -ForegroundColor Yellow
        Line '  will see a OneDrive sign-in window on their screen. Their files are' -ForegroundColor Yellow
        Line '  not deleted, and no folders are re-downloaded.' -ForegroundColor Yellow
    }

    $tool = Get-Tool -Key OneDrive
    if (-not $tool) { return }

    Reset-Env
    $toolArgs = @('-Account', $account)
    if (-not $restart) { $toolArgs += '-NoRestart' }

    Line ''
    Run-Tool -Path $tool -Arguments $toolArgs
}

# ---- fallback when there is no console to ask in ---------------------------
function Show-Manual {
    Line ''
    Rule '='
    Line '  This console cannot ask questions, so nothing was run.'
    Rule '='
    Line ''
    Line '  Use one of these instead - paste the whole block, and edit only'
    Line '  the \\SERVER\QUEUE-NAME part. Keep the lines tight together.'
    Line ''
    Line '  ADD A PRINTER:'
    Line "    #!ps"
    Line "    #timeout=600000"
    Line "    `$env:PrinterSetupPath = '\\SERVER\QUEUE-NAME'"
    Line "    irm $($Urls.PrinterSetup) | iex"
    Line ''
    Line '  CHECK THEIR PRINTERS:'
    Line "    #!ps"
    Line "    #timeout=600000"
    Line "    `$env:PrinterCheckPath = '\\SERVER\QUEUE-NAME'"
    Line "    irm $($Urls.PrinterCheck) | iex"
    Line ''
    Line '  FIX ONEDRIVE:'
    Line "    #!ps"
    Line "    #timeout=600000"
    Line "    `$f = `"`$env:TEMP\Reset-OneDriveLink-2.ps1`""
    Line "    irm $($Urls.OneDrive) -OutFile `$f"
    Line "    & `$f -Account All"
    Line ''
}

# ---- main ------------------------------------------------------------------
Head "PS TOOLKIT v$version  -  on $env:COMPUTERNAME"
Line ''
Line '  Adds a printer or fixes OneDrive for the person currently logged in,'
Line '  without taking over their screen.'
if ($DryRun) { Line ''; Line '  DRY RUN: nothing will actually be changed.' -ForegroundColor Yellow }

$didSomething = $false

:main while ($true) {
    Line ''
    Rule
    Line '  What do you want to do?'
    Rule
    Line '    1   Add a printer'
    Line '    2   Check which printers they have  (read-only)'
    Line '    3   Fix OneDrive'
    Line '    4   Exit'
    Line ''
    $choice = Ask -Prompt '  Choose 1-4' -Default '4'
    if ($null -eq $choice) { break main }

    switch ($choice) {
        '1' { Line ''; Job-AddPrinter;    $didSomething = $true }
        '2' { Line ''; Job-CheckPrinters; $didSomething = $true }
        '3' { Line ''; Job-OneDrive;      $didSomething = $true }
        '4' { break main }
        default {
            Line ''
            Line '  Please type 1, 2, 3 or 4.' -ForegroundColor Yellow
            continue main
        }
    }

    $again = AskYN -Prompt 'Do something else?' -Default $true
    if ($null -eq $again -or -not $again) { break main }
}

if ($script:NoPrompt) {
    Show-Manual
}
elseif ($didSomething) {
    Line ''
    Rule '='
    Line '  Finished. Each job above printed its own verdict:'
    Line '    PRESENT / CONNECTED  = it worked'
    Line '    ABSENT / FAILED      = it did not, and the message says why'
    Rule '='
}
else {
    Line ''
    Line '  Nothing to do - exiting.'
}
