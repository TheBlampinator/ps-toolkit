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

      Nothing is ever written to disk and nothing is ever run as a
      .ps1 file, so this works on PCs where the execution policy
      blocks scripts - the policy applies to files, not to code that
      only ever existed as text.

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
$version = '1.1.0'

# ---- published tools this menu drives --------------------------------------
# Pinned to immutable revisions. Update these three lines only when
# republishing a tool, and the menu picks up the new build.
$Urls = [ordered]@{
    PrinterSetup = 'https://gist.githubusercontent.com/TheBlampinator/84923f2c6a155cfa245a353e3e00f995/raw/7066414df24068a10dd6483986cf7ea889a8e501/Printer-Setup-Paste.ps1'
    PrinterCheck = 'https://gist.githubusercontent.com/TheBlampinator/8905bde8066b4057770126ad5550f0ad/raw/23ff3dbaedf1bb36af2b261d337164c937894fd1/Printer-Check.ps1'
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
        if ($v -match '^\\\\[^\\]+\\[^\\]+$') {
            # Catch a typo in the server name now, not after a 25-second wait.
            $server = ($v.TrimStart('\\') -split '\\')[0]
            $ok = $null
            try { $ok = [System.Net.Dns]::GetHostAddresses($server)[0].IPAddressToString } catch { $ok = $null }
            if ($ok) {
                Line "  server $server = $ok" -ForegroundColor DarkGray
                # A 150-second printui stall is what a missing queue looks like, so
                # ask the server what it actually publishes before running anything.
                $leaf = ($v.TrimStart('\\') -split '\\')[1]
                $shared = @()
                try {
                    $shared = @(Get-Printer -ComputerName $server -ErrorAction Stop |
                                    Select-Object -ExpandProperty Name)
                }
                catch { $shared = @() }

                if ($shared.Count -and ($shared -notcontains $leaf)) {
                    Line ''
                    Line "  '$server' does not share a queue called '$leaf'." -ForegroundColor Red
                    Line '  It shares these:' -ForegroundColor Yellow
                    $shared | Sort-Object | ForEach-Object { Line "    $_" -ForegroundColor Yellow }
                    $anyway = AskYN -Prompt '  Use your address anyway?' -Default $false
                    if ($null -eq $anyway) { return $null }
                    if ($anyway) { return $v }
                    continue
                }
                if ($shared.Count) { Line "  queue '$leaf' confirmed on $server" -ForegroundColor DarkGray }
                return $v
            }
            Line ''
            Line "  '$server' does not resolve to anything on this network." -ForegroundColor Red
            Line '  That is usually a typo in the server name - check it against a printer' -ForegroundColor Yellow
            Line '  they already have, or ask IT for the exact address.' -ForegroundColor Yellow
            $anyway = AskYN -Prompt "  Use '$v' anyway?" -Default $false
            if ($null -eq $anyway) { return $null }
            if ($anyway) { return $v }
            continue
        }
        Line "  '$v' is not in the right form." -ForegroundColor Yellow
        Line '  Use two backslashes, then the server, then one backslash, then the queue.' -ForegroundColor DarkGray
    }
    return $null
}

# Fetch a tool as TEXT. Never write it to disk: a .ps1 file is subject to the
# execution policy, but code that never existed as a file is not - which is the
# same reason pasting this menu works on a machine that blocks scripts.
function Get-ToolText {
    param([string]$Key)
    if ($DryRun) {
        Say ('DRY RUN - would fetch ' + $Key)
        # A stub so the job continues and Run-ToolText can report what it would do.
        # It is never executed: Run-ToolText returns before creating the block.
        return "param([string]`$Account, [switch]`$NoRestart) 'stub'"
    }
    Write-Host '  fetching the tool...' -ForegroundColor DarkGray
    try {
        return (Invoke-RestMethod -Uri $Urls[$Key])
    }
    catch {
        Line ''
        Line '  Could not download the tool for this job.' -ForegroundColor Red
        Line "  $($_.Exception.Message)" -ForegroundColor DarkGray
        Line '  Either the PC cannot reach gist.githubusercontent.com, or a proxy is' -ForegroundColor Yellow
        Line '  blocking it.' -ForegroundColor Yellow
        return $null
    }
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

function Run-ToolText {
    param([string]$Text, [string]$Account, [switch]$NoRestart)
    if ($DryRun) {
        $shown = ''
        if ($Account)  { $shown = "-Account $Account" }
        if ($NoRestart) { $shown = ($shown + ' -NoRestart').Trim() }
        Say ('DRY RUN - would run the {0} tool {1}' -f $script:CurrentTool, $shown)
        foreach ($n in 'PrinterSetupPath','PrinterSetupDefault','PrinterSetupElevated',
                       'PrinterSetupUser','PrinterCheckPath','PrinterCheckUser') {
            $v = [Environment]::GetEnvironmentVariable($n)
            if ($v) { Say "           $n = $v" }
        }
        return
    }
    # Created from text, so there is no file and no execution-policy check.
    # Parameters are passed by name here rather than splatted: a hashtable
    # splat on a scriptblock invocation binds as ONE positional argument.
    $block = [scriptblock]::Create($Text)
    if ($Account) {
        if ($NoRestart) { & $block -Account $Account -NoRestart }
        else            { & $block -Account $Account }
    }
    else { & $block }
}


# Print the newest log a job wrote, so the outcome is visible without a follow-up
# command. Runs as SYSTEM and reads across every profile, which is what makes it
# useful - the log itself belongs to the user.
function Show-LatestLog {
    param([string]$Subfolder, [string]$Filter, [string]$SuccessPattern, [string]$Label)
    $logs = @(Get-ChildItem "C:\Users\*\AppData\Local\$Subfolder\$Filter" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime)
    if (-not $logs.Count) {
        Line '  No log found - the job may not have reached the user session.'
        return
    }
    $f = $logs[-1]
    Line ''
    Line ('  {0}  ({1})' -f $f.FullName, $f.LastWriteTime.ToString('HH:mm:ss'))
    Line ''
    Get-Content -LiteralPath $f.FullName -Tail 25 | ForEach-Object { Line "    $_" }
    Line ''
    $raw = Get-Content -LiteralPath $f.FullName -Raw
    if ($SuccessPattern -and $raw -match $SuccessPattern) {
        Line ('  VERDICT: {0} - it worked.' -f $Label) -ForegroundColor Green
    }
    elseif ($raw -match 'FAILED|not connected|ERROR|Access is denied|cannot') {
        Line '  VERDICT: FAILED - the reason is in the lines above.' -ForegroundColor Red
    }
    else {
        Line '  VERDICT: still running, or it stopped without reporting.' -ForegroundColor Yellow
    }
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

    $script:CurrentTool = 'printer setup'
    $text = Get-ToolText -Key PrinterSetup
    if (-not $text) { return }

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
    Run-ToolText -Text $text

    if (-not $DryRun) {
        $show = AskYN -Prompt 'Show the latest setup log now?' -Default $true
        if ($show) { Show-LatestLog -Subfolder 'PrinterToolkit' -Filter 'Setup-*.log' -SuccessPattern 'CONNECTED OK' -Label 'PRESENT' }
    }
}

function Job-CheckPrinters {
    Head 'CHECK WHICH PRINTERS THEY HAVE (nothing is changed)'

    $queue = AskQueue -Why 'Which printer do you want to check for?' -AllowBlank
    if ($null -eq $queue) { return }

    $user = Ask -Prompt 'If more than one person is logged on, type DOMAIN\name (else press Enter)'
    if ($null -eq $user) { return }

    $script:CurrentTool = 'printer check'
    $text = Get-ToolText -Key PrinterCheck
    if (-not $text) { return }

    Reset-Env
    if ($queue) { $env:PrinterCheckPath = $queue } else { $env:PrinterCheckPath = 'list' }
    if ($user)  { $env:PrinterCheckUser = $user }

    Line ''
    Run-ToolText -Text $text
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

    $script:CurrentTool = 'OneDrive'
    $text = Get-ToolText -Key OneDrive
    if (-not $text) { return }

    Reset-Env
    Line ''
    Run-ToolText -Text $text -Account $account -NoRestart:(-not $restart)

    if (-not $DryRun) {
        $show = AskYN -Prompt 'Show the latest OneDrive log now?' -Default $true
        if ($show) { Show-LatestLog -Subfolder 'OneDriveRelink' -Filter 'Relink-*.log' -SuccessPattern 'Completed successfully' -Label 'RE-LINKED' }
    }
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
