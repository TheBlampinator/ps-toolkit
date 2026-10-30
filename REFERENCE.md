# PS Toolkit — command reference

Two self-bridging scripts, plus a paste-only variant of the printer one and a read-only
printer check. Run any of them from a SYSTEM shell (ScreenConnect Backstage, Commands
tab, PsExec -s) or directly as the user; they detect which and adapt.

On the endpoint they end up under `C:\ProgramData\PrinterToolkit` (printer) and
`C:\ProgramData\OneDriveRelink` (OneDrive) after the first SYSTEM run — those are the
staged copies the scheduled task executes, not something you place there by hand.

## Start here

| I want to… | Read |
|---|---|
| Do everything from a menu: pick a job, answer questions | [§1d](#1d-start-pstoolkitps1--interactive-menu) |
| Add a printer for the person who is logged in | [§1b](#1b-printer-setup-pasteps1--no-upload-just-paste) paste-and-go, or [§1](#1-add-printerasuserps1) from a saved file |
| Know whether a printer is already there / what they have | [§1c](#1c-printer-checkps1--read-only-paste-and-go) |
| Fix OneDrive that will not sign in or sync | [§2](#2-reset-onedrivelink-2ps1) |
| My command died at 10 seconds / showed nothing | [§0a](#0a-screenconnect-commands-tab-the-10-second-kill) |
| "Running scripts is disabled on this system" | [§0](#0-running-it--getting-past-the-execution-policy) |
| A paste script refused to run and printed a red box | [§0b](#0b-required-environment-variables-paste-ready-scripts) |
| Something is left behind on the PC | [§3](#3-useful-checks-from-a-system-shell) |
| A script said success but the printer is not there | [§4](#4-gotchas) |

Plain-English walkthroughs with no jargon: **[README.md](README.md)**.

---

## 0a. ScreenConnect Commands tab: the 10-second kill

The Commands tab (the web PowerShell box, as opposed to Backstage) **kills any command
after 10 seconds** and truncates output at 10,000 characters. A bridging script looks
like it "hangs and gives no result" when in fact it was killed mid-wait:

```
[14:04:20] Waiting for the user session...
Killed after 10000 milliseconds.
```

The scheduled task it started keeps running (it belongs to the Task Scheduler service),
so the work usually completes — you just lose the report.

Fix: put these three lines at the **very top** of whatever you paste. They are
ScreenConnect hashbang modifiers, read only by the Commands tab (in PowerShell they are
ordinary `#` comments, so they are harmless anywhere else):

```
#!ps
#timeout=600000
#maxlength=1000000
```

`Printer-Setup-Paste.ps1` already includes them at the top. For the file-based scripts,
paste the modifiers on their own lines first, then the command:

```
#!ps
#timeout=600000
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -Verify
```

If a run was killed, clean up after it:

```powershell
Get-ScheduledTask -TaskName 'AddPrinter-*','PrinterSetup-*' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false
Get-ChildItem 'C:\ProgramData\PrinterToolkit' -Filter 'PrinterSetup-*.ps1' |
    Remove-Item -Force
```

---

## 0b. Required environment variables (paste-ready scripts)

`Printer-Setup-Paste.ps1` and `Printer-Check.ps1` have **no printer name in them at all**.
They stop on the first line and print a red box telling you what to type, rather than
guessing or doing the wrong thing. Two reasons it is built this way: the same file works
at any site, and a forgotten value fails loudly instead of silently printing nothing.

Set the value in the same window, on its own line, **before** the command:

```powershell
$env:PrinterSetupPath = '\\PRINTSERVER\QUEUE-NAME'
```

| Variable | Script | Meaning |
|---|---|---|
| `PrinterSetupPath` | setup | **required**; `\\server\queue` |
| `PrinterSetupDefault` | setup | `'false'` leaves their default printer alone |
| `PrinterSetupElevated` | setup | `'true'` only when the driver will not install |
| `PrinterSetupUser` | setup | `'DOMAIN\name'` to choose the user yourself |
| `PrinterSetupRead` | setup | `'true'` prints the last result and stops |
| `PrinterCheckPath` | check | **required**; `\\server\queue`, or `list` |
| `PrinterCheckUser` | check | `'DOMAIN\name'` to choose the user yourself |
| `PrinterCheckRead` | check | `'true'` prints the last result and stops |

The value disappears when that window closes — it is not saved anywhere on the PC.

In the ScreenConnect Commands tab the modifiers must be **contiguous on the first lines**.
A blank line between them and only `#!ps` is applied, which leaves the 10-second kill
running:

```
#!ps
#timeout=600000
$env:PrinterCheckPath = '\\PRINTSERVER\QUEUE-NAME'
irm <gist url> | iex
```

---
## 0. Running it — getting past the execution policy

A `.ps1` **cannot** exempt itself: PowerShell checks the execution policy before it
reads the file, so the bypass has to come from whatever launches the script. Pass it on
the command line:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -SetDefault
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-OneDriveLink-2.ps1 -Account All
```

Or set it for the current window only, as before (resets when the window closes), then
call the scripts directly:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME'
```

Notes:

- **The user-session half never needs any of this.** The scheduled task already invokes
  the staged copy with `-ExecutionPolicy Bypass`.
- **GPO-enforced policy wins.** If `Get-ExecutionPolicy -List` shows
  `MachinePolicy` or `UserPolicy` set, the `-ExecutionPolicy` parameter is ignored and
  `Set-ExecutionPolicy -Scope Process` won't help either — that's a policy change, not a
  script change.
- **Pasting is exempt.** `Printer-Setup-Paste.ps1` goes straight into a console window,
  which isn't subject to the execution policy at all.
- **A file downloaded from a browser or Teams** carries a Mark-of-the-Web and is
  blocked even under `Bypass` on some builds. Clear it once with:
  `Unblock-File .\Add-PrinterAsUser.ps1`
- **AppLocker/WDAC** blocks are a separate control; nothing here bypasses them.

---

## 1. Add-PrinterAsUser.ps1

Adds / removes / verifies a network printer connection **for the logged-on user**.
A connection is per-user data (`HKCU\Printers\Connections`), so running it from a
SYSTEM shell would otherwise create it for the SYSTEM profile and nobody would see it.

### Parameters

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-PrinterPath` | string, **required** | — | UNC queue: `'\\server\printer'`. Backslashes, not forward slashes. |
| `-SetDefault` | switch | off | Make it the user's default after adding (verified). |
| `-Remove` | switch | off | Remove the connection instead of adding it. |
| `-Verify` | switch | off | Change nothing; report whether the connection is present. Exits 1 if not. |
| `-User` | string | auto-detect | `'DOMAIN\name'`. SYSTEM mode only. Required if 2+ users are logged on. |
| `-Elevated` | switch | off | SYSTEM mode only. Run as the user's admin token (`RunLevel Highest`) — needed when the driver isn't installed and Point-and-Print is restricted. |
| `-TimeoutSeconds` | int | 300 | SYSTEM mode only. How long to wait for the user-session run. |
| `-Payload` | switch | — | Internal. Set by the scheduled task. Never pass it. |

`-Remove` and `-Verify` are mutually exclusive.

### Commands

```powershell
# add (the common case)
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME'

# add and make it the default
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -SetDefault

# queue name with spaces — quote it
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -SetDefault

# driver not installed / Point-and-Print blocked
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -Elevated

# remove
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -Remove

# did it work? (read-only, no changes)
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -Verify

# several users logged on — pick one
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -User 'CONTOSO\jsmith'

# short timeout when you know it should be instant
.\Add-PrinterAsUser.ps1 -PrinterPath '\\PRINTSERVER\QUEUE-NAME' -Verify -TimeoutSeconds 60
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Connection confirmed present for that user (add), confirmed gone (remove), or confirmed present (`-Verify`). |
| 1 | Anything else — not added, wrong user, no session, timeout with the payload still running. Reason is in the log. |

---

## 1b. Printer-Setup-Paste.ps1 — no upload, just paste

For when you can't or don't want to get a file onto the box. Paste the entire file into
a PowerShell window (Backstage or the user's own) and press Enter. **Pasting into an
interactive session is not subject to the execution policy**, so there's nothing to
unblock first.

There is **no printer name anywhere in the file**. It stops with a red box until you say
which printer, using an environment variable set in the same window before you paste:

```powershell
$env:PrinterSetupPath = '\\PRINTSERVER\QUEUE-NAME'   # required
```

| Variable | Meaning |
|---|---|
| `PrinterSetupPath` | **required** — `\\server\queue` |
| `PrinterSetupDefault` | `'false'` leaves their current default printer alone |
| `PrinterSetupElevated` | `'true'` only when the driver will not install |
| `PrinterSetupUser` | `'DOMAIN\name'` to choose the user when several are logged on |
| `PrinterSetupRead` | `'true'` prints the last result and stops; needs no queue |
| `PrinterSetupWait` | seconds to wait for the result, default 25 |

What it does:

1. Refuses to continue if the queue is missing or malformed, printing the exact line to
   type. Nothing is changed in that case.
2. Validates `\\server\queue`, then writes a small payload script to
   `C:\ProgramData\PrinterToolkit\PrinterSetup-<stamp>.ps1`.
3. **Already the right user?** Runs the payload in place.
   **In a SYSTEM shell?** Registers a one-shot task owned by the logged-on user, runs the
   payload there, and waits up to 25 s for it.
4. Reads the connection back from `HKCU:\Printers\Connections` and the user's
   `Win32_Printer` list, then prints a green/red `RESULT:` line.
5. Deletes the payload script and the task — unless it deferred to a later read, in which
   case both are kept and their paths printed.

Run it from the Commands tab with the `#timeout` modifiers on the first lines (§0a): the
default 10-second kill is shorter than a first-time driver install.

---

## 1c. Printer-Check.ps1 — read-only, paste and go

Lists what the logged-on user actually has. Changes nothing; the only thing it creates is
a short-lived read task, which it removes.

No printer name is built in. Supply the queue you are checking:

```powershell
$env:PrinterCheckPath = '\\PRINTSERVER\QUEUE-NAME'
```

…or the word `list` to show everything without checking one printer:

```powershell
$env:PrinterCheckPath = 'list'
```

Without it the script stops and prints what to type — it will not guess. `''` cannot be
used to mean "no queue", because assigning an empty string to an environment variable
*deletes* it in PowerShell.

Output:

```
Identity : CONTOSO\jsmith
Machine  : WORKSTATION-01

Printers visible to this user (4):
  [DEFAULT] \\PRINTSERVER\QUEUE-NAME
            driver: Generic Printer Driver | port: \\PRINTSERVER\QUEUE-PORT
  [       ] Microsoft Print to PDF
            ...

Per-user connections in HKCU (2):
  \\PRINTSERVER\QUEUE-NAME
  \\PRINTSERVER\SECOND-QUEUE

Note: built-in, not real printers:
  Microsoft Print to PDF

Checking : \\PRINTSERVER\QUEUE-NAME
  in user printer list : True
  HKCU connection key  : True
  key path             : HKCU:\Printers\Connections\,,PRINTSERVER,QUEUE-NAME
  is default           : True
  driver / port        : Generic Printer Driver / \\PRINTSERVER\QUEUE-PORT
VERDICT: PRESENT
```

`VERDICT:` is one of `PRESENT`, `ABSENT`, or `PARTIAL` — the last means it is listed but
has no HKCU connection key (or the reverse), which is the state that produces "it's
there but won't print". Remove and re-add in that case.

Bridging note: when run from a SYSTEM shell the probe's console output cannot be read
back, so it writes to `%TEMP%\PrinterCheck-<stamp>.txt` in the user's profile and the
outer script reads that file, prints it, then deletes it.

---

## 1d. Start-PSToolkit.ps1 — interactive menu

One paste, then questions. It drives the other tools and contains none of their logic, so
fixing a tool updates the menu too.

```
#!ps
#timeout=600000
irm https://gist.githubusercontent.com/TheBlampinator/e8c8f5e9efb6689f285c9d54ddbfd46d/raw/f69be5e674760fc857b442e9e28712b651b14663/Start-PSToolkit.ps1 | iex
```

Menu: `1` add a printer, `2` check printers, `3` fix OneDrive, `4` exit. After each job it
asks whether to do something else. Prompts are asked with `Read-Host`.

| Variable | Meaning |
|---|---|
| `PSToolkitDryRun` | `1` prints what would run and changes nothing — use it to rehearse |

**No console to prompt in?** The first `Read-Host` that cannot get input sets an internal
flag and the script prints the manual four-line command for every job instead of hanging.
That is what happens in a Commands tab that does not accept typed input.

The tool URLs are pinned in `$Urls` at the top; republishing a tool means updating one
line there.

> **If a gist URL returns 404**, remove the `/raw/<sha>/` segment and use
> `/raw/<file>` instead. GitHub's CDN caches a 404 against a revision-pinned path for a
> gist whose revision it has not indexed yet, and the negative entry sticks. The unpinned
> form always serves the latest published version.


---

## 2. Reset-OneDriveLink-2.ps1

Unlinks and re-links OneDrive for the logged-on user. Local files are never deleted.

### Parameters

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-Account` | enum | `Business` | Which account: `Business` (all work/school), `Personal`, `All`. (`Auto` accepted, behaves as Business.) |
| `-UseReset` | switch | off | Use Microsoft's `OneDrive.exe /reset` instead of removing the account key. Slower, fully supported. |
| `-NoRestart` | switch | off | Unlink only; don't start OneDrive again. |
| `-User` | string | auto-detect | SYSTEM mode only, as above. |
| `-TimeoutSeconds` | int | 300 | SYSTEM mode only. |
| `-Payload` | switch | — | Internal. |

### Commands

```powershell
# unlink + re-link all work/school accounts
.\Reset-OneDriveLink-2.ps1

# both personal and work/school
.\Reset-OneDriveLink-2.ps1 -Account All

# personal only
.\Reset-OneDriveLink-2.ps1 -Account Personal

# official Microsoft reset instead
.\Reset-OneDriveLink-2.ps1 -UseReset

# unlink only, leave OneDrive stopped
.\Reset-OneDriveLink-2.ps1 -Account All -NoRestart

# specific user when several are logged on
.\Reset-OneDriveLink-2.ps1 -Account All -User 'CONTOSO\jsmith'
```

---

## 3. Useful checks from a SYSTEM shell

```powershell
# tail the user's printer log live
Get-Content 'C:\Users\<user>\AppData\Local\PrinterToolkit\AddPrinter-*.log' -Tail 20 -Wait

# tail the user's OneDrive log live
Get-Content 'C:\Users\<user>\AppData\Local\OneDriveRelink\Relink-*.log' -Tail 20 -Wait

# tasks this toolkit created (should be empty when a run finishes cleanly)
Get-ScheduledTask -TaskName 'AddPrinter-*','OneDriveRelink-*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State

# clean up a task left behind by closing the tab mid-run
Unregister-ScheduledTask -TaskName 'AddPrinter-20261030-132940' -Confirm:$false

# who is actually logged on (what auto-detect sees)
Get-Process explorer -IncludeUserName |
    Where-Object UserName -notmatch '\\(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' |
    Select-Object -ExpandProperty UserName -Unique

# list queue names on a print server, to copy into -PrinterPath
Get-Printer -ComputerName PRINTSERVER | Select-Object Name, DriverName, PortName

# the user's own printer list, from inside a user session
Get-Printer | Format-Table Name, DriverName, PortName, Type
```

---

## 4. Gotchas

- **Execution policy**: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` is per-window and resets when the tab closes. The scheduled task already passes `-ExecutionPolicy Bypass`, so the user-session half never needs it.
- **Driver install is the usual failure.** `Access is denied` + `printui /in exit code: 5` means `RestrictDriverInstallationToAdministrators` blocked it — re-run with `-Elevated`.
- **Nobody logged on = nothing to do.** Both scripts refuse rather than acting on SYSTEM's profile.
- **Don't close the tab mid-run.** The task keeps running but the cleanup is skipped; unregister it by name.
- **`-User` matters on RDP-heavy boxes.** Auto-detect refuses to guess when several users have a session.
- **Registry backups (OneDrive)** land in `%LOCALAPPDATA%\OneDriveRelink\*.reg`; revert with `reg import <file>`.
