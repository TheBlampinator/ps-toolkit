# ps-toolkit

Small scripts for helping someone who is already logged in to their own PC — adding a
printer to their account, or fixing OneDrive for them — **without** asking them to stop
working while you take over their screen.

You run one command from your remote-support tool. The script does the rest.

---

## Which one do I want?

| If you want to… | Use this | Page |
|---|---|---|
| **Do all of the above from one menu** | `Start-PSToolkit.ps1` | [one paste, then answer questions](#one-paste-then-answer-questions-the-easiest-way) |
| Add a printer for the person who is logged in | `Printer-Setup-Paste.ps1` | [step-by-step](#add-a-printer-the-whole-procedure) |
| Check which printers they have, and whether one is missing | `Printer-Check.ps1` | [step-by-step](#check-what-printers-they-have) |
| Fix OneDrive that will not sync / sign in | `Reset-OneDriveLink-2.ps1` | [step-by-step](#fix-onedrive) |
| **Check whether OneDrive is actually working** | `OneDrive-Check.ps1` | [check if OneDrive is working](#check-if-onedrive-is-working) |
| Do any of the above from a saved file, with options | `Add-PrinterAsUser.ps1` | [REFERENCE.md](REFERENCE.md) |

The printer scripts and the checker are also runnable by **copying and pasting** — no
file to upload, nothing to install.

---

## Before you start

You need two things:

1. **The printer's address**, which looks like `\\SERVER\QUEUE`.
   For example `\\PRINTSERVER\QUEUE-NAME`. If you do not know it, someone in IT can
   give it to you, or you can list them (see [Check what printers they have](#check-what-printers-they-have)).
2. **The person logged in to the PC** — the script works on whoever is logged on, so do
   not run it while nobody is signed in.

---

## One paste, then answer questions (the easiest way)

Paste these three lines and the script asks you what you want to do:

```
#!ps
#timeout=600000
irm https://gist.githubusercontent.com/TheBlampinator/e8c8f5e9efb6689f285c9d54ddbfd46d/raw/d42bfc2ef9fa4c82c2b518eadf0a4b514291f676/Start-PSToolkit.ps1 | iex
```

```
------------------------------------------------------------
  What do you want to do?
------------------------------------------------------------
    1   Add a printer
    2   Check which printers they have  (read-only)
    3   Fix OneDrive
    4   Check OneDrive  (read-only)
    5   Exit

  Choose 1-5:
```

Type `1` and it asks only the questions that job needs — the printer address, whether to
make it their default, whether a previous attempt said "Access is denied". You never type
a variable name and you never edit a file. Then it asks "do something else?" so one paste
can cover a whole ticket.

Two things worth knowing:

- **It needs somewhere to ask questions.** In Backstage or a normal PowerShell window that
  is fine. If your Commands tab cannot accept typed input, it prints the ready-made
  command for each job instead of waiting forever on a prompt.
- **It downloads the individual tool for the job you pick**, so it runs exactly the same
  tested code as the four-line commands further down this page. Nothing is duplicated.

---

## Add a printer: the whole procedure

**Step 1.** Open your remote-support tool (ScreenConnect / ConnectWise Control) and go
to the **Commands** tab.

**Step 2.** Copy these four lines. Change only the part inside the quotes on line 3 —
put your printer's address there.

```
#!ps
#timeout=600000
$env:PrinterSetupPath = '\\PRINTSERVER\QUEUE-NAME'
irm https://gist.githubusercontent.com/TheBlampinator/84923f2c6a155cfa245a353e3e00f995/raw/7066414df24068a10dd6483986cf7ea889a8e501/Printer-Setup-Paste.ps1 | iex
```

**Step 3.** Paste all four lines into the Commands box and run it.

**Step 4.** Wait for it. If the PC has never printed to that queue, the tool installs the
printer's driver first — automatically, from the print server, with no window to click. That
can take a minute the first time on each PC, and seconds after that.

**Step 5.** Read the result. It will say one of these:

```
[14:02:13] RESULT: CONNECTED - \\PRINTSERVER\QUEUE-NAME is on the printer list.
           It is set as the default printer.
```
That is success. The printer is on the user's list; they may need to reopen the print
dialog to see it.

or

```
############################################################
#  STOPPED - NO PRINTER WAS ADDED. NOTHING WAS CHANGED.    #
############################################################
```
You forgot line 3, or spelled the address wrongly. The message tells you what to type.
Nothing was changed, so it is safe to fix and run again.

or

```
ERROR: ... Access is denied ...
```
The printer's software (the "driver") is not on this PC **and** the tool could not install
it by itself.

Usually you will never see this: the tool copies the driver from the print server
(`\\SERVER\print$`) and installs it before connecting, with no dialog and no input from
you. This message means that failed — the server's driver share is not readable, or its
`.inf` is not there. Re-run with this extra line second from the top:

```
$env:PrinterSetupElevated = 'true'
```

If it still fails, the driver has to be put on the machine once by other means — see
[REFERENCE.md §1b](REFERENCE.md#1b-printer-setup-pasteps1--no-upload-just-paste).

### The four lines, explained

| Line | What it does |
|---|---|
| `#!ps` | "Run this as PowerShell, not as old-style DOS commands." |
| `#timeout=600000` | "Do not kill this after 10 seconds; give it 10 minutes." |
| `$env:PrinterSetupPath = '...'` | Tells the script **which** printer. It has no printer name built in. |
| `irm ... \| iex` | Downloads the script and runs it in memory. Nothing is saved to the PC. |

> **These four lines must sit together with no blank line between them.** If there is a
> blank line, ScreenConnect only reads the first special line and still kills the command
> after 10 seconds. This is the single most common way this goes wrong.

---

## Check what printers they have

Same idea, four lines, and this one only *looks* — it never changes anything.

```
#!ps
#timeout=600000
$env:PrinterCheckPath = '\\PRINTSERVER\QUEUE-NAME'
irm https://gist.githubusercontent.com/TheBlampinator/8905bde8066b4057770126ad5550f0ad/raw/23ff3dbaedf1bb36af2b261d337164c937894fd1/Printer-Check.ps1 | iex
```

Put the printer you are looking for on line 3, or the word `list` to see everything
without checking one particular printer.

You get a list like this:

```
Identity : CONTOSO\jsmith
Printers visible to this user (4):
  [DEFAULT] \\PRINTSERVER\QUEUE-NAME
            driver: HP LaserJet 4525 PCL6 | port: \\PRINTSERVER\HP4525_FIN
  [       ] Microsoft Print to PDF
Per-user connections in HKCU (2):
  \\PRINTSERVER\QUEUE-NAME

Checking : \\PRINTSERVER\QUEUE-NAME
  in user printer list : True
  HKCU connection key  : True
  is default           : True
VERDICT: PRESENT
```

`VERDICT` is the answer:

| Verdict | Means | Do this |
|---|---|---|
| `PRESENT` | All good. | Nothing. |
| `ABSENT` | The printer is not there. | Add it (previous section). |
| `PARTIAL` | Half-installed — it appears but will not print. | Remove and add again. |

---

## Fix OneDrive

For a user whose OneDrive will not sync, keeps asking to sign in, or shows the wrong
account. This un-links and re-links it. **Their files are not deleted.**

> ### Read this first: work accounts need a sign-in
>
> Unlinking a **work/school** account does not sign it back in. After the fix, OneDrive must
> sign in again, and it will only do that by itself if your organisation has enabled the
> silent sign-in policy (`SilentAccountConfig=1`). Without it, the person will get a OneDrive
> sign-in window — so this is not a hands-off fix for work accounts until that policy is on.
>
> **Personal** accounts usually sign back in on their own.

```
#!ps
#timeout=600000
$f = "$env:TEMP\Reset-OneDriveLink-2.ps1"
irm https://gist.githubusercontent.com/TheBlampinator/4faca813edea0891225baed59a7fb2db/raw/d005b0ee99d7d06753a21d95dacedfc76d24cb59/Reset-OneDriveLink-2.ps1 -OutFile $f
& $f -Account All
```

`-Account All` means every account the person has. Use `-Account Business` or `-Account
Personal` to touch only one kind.

You get **live output as it happens** — every line the work writes appears in your console
as it is written, from inside the user's session:

```
[09:42:39] Stopping OneDrive (PID 28940)
[09:42:40] Unlinking Business1 (david@example.com) - folder: C:\Users\David\OneDrive - Example
[09:42:40]   Registry backed up to ...\OneDrive-Business1-....reg
[09:42:40]   Removed account registration Business1
[09:42:41] Starting OneDrive to re-link
[09:42:41] Waiting up to 120s for OneDrive to sign back in and re-register 1 account(s): Business1
[09:42:44]   Business1: signed back in  (david@example.com)
[09:42:44] VERIFIED-COMPLETE: all 1 account(s) signed back in and re-registered.
```

**The `RESULT:` line is the answer — read only that:**

| Result | Means | Do this |
|---|---|---|
| `VERIFIED` (green) | Every real account came back | nothing |
| `PARTIAL` (yellow) | Some did; the log names the missing ones | sign the missing account in, or enable silent sign-in |
| `NOT VERIFIED` (yellow) | Nothing came back within 2 minutes | a sign-in window is probably waiting on their desktop |
| `NOTHING TO DO` (yellow) | No real account was unlinked | the OneDrive may not be signed in at all — sign in first |

Each account is checked **individually** in the user's own registry, so `VERIFIED` means all
of them returned, not just one. Empty leftover registrations (no folder, no email) are
cleaned up but never counted as failures.

Nothing on the person's screen is taken over, and the script does not close your console
when it finishes. A `.reg` backup of every removed account is kept in
`%LOCALAPPDATA%\OneDriveRelink` on their machine, so any of this can be reverted with
`reg import`.

---

## Check if OneDrive is working

Read-only. Answers "is it running, is it signed in, and is it actually doing anything" — and
changes nothing, so it is safe to run before deciding whether to re-link.

```
#!ps
#timeout=600000
$f = "$env:TEMP\OneDrive-Check.ps1"
irm https://gist.githubusercontent.com/TheBlampinator/cba2dc56424f35868221f9aeed2cc0a7/raw/e668f0872dd62074d77265be9e26902d67f29c74/OneDrive-Check.ps1 -OutFile $f
& $f
```

```
Identity : AzureAD\DavidTeasdale
Machine  : LAPTOP-HGS5N3AF

Process  : running (1 instance(s), PID 28940)
Version  : 24.151.0728.0003
Uptime   : 0d 2h 14m
Accounts : 2 registered
  Business1
    user   : david@example.com
    folder : C:\Users\David\OneDrive - Example
    exists : True
  Personal
    user   : (no email recorded)
    folder : (none) - leftover registration, not a live account

Log      : last written 1 min ago (Business1-20261103_0942.odl)
Recent log lines worth reading: none of error/failed/quota/blocked in the last 400

Business1: 12 item(s) at the top level, 4 cloud-only placeholder(s)

VERDICT: HEALTHY

RESULT: HEALTHY - OneDrive is running, signed in and writing to its log.
```

| Result | Means | What to do |
|---|---|---|
| `HEALTHY` | running, signed in, log is being written | nothing |
| `DEGRADED` | signed in, but the log has not moved for 15+ min — idle or stuck | restart OneDrive, or re-link |
| `FAILED` | not running, not signed in, or a sync folder is missing | fix the named PROBLEM line first |

**What it cannot do:** quota, and whether one particular file has uploaded. Those need
OneDrive's own UI or the Microsoft APIs — this only reports what can be established on the
machine without credentials.

---

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `Killed after 10000 milliseconds` | ScreenConnect stopped the command after 10 seconds. | Check the four lines have no blank line between them. The work may still have happened — read the result (below). |
| `STOPPED - ... NOTHING WAS CHANGED` | A setting was missing or the address was malformed. | Read the message, it shows the exact line to type. |
| `Missing type name after '['` | You pasted *output* instead of the script. | The real script starts with `#!ps`. Clear the box and paste again. |
| `Access is denied` | The driver could not be installed automatically. | Add `$env:PrinterSetupElevated = 'true'`. |
| `0x800704C7` / "canceled by the user" | Windows asked for permission to install the driver and nobody was there to click. | Should no longer happen — the tool installs the driver itself. If it does, the print server's `print$` share is not readable. |
| `More than one user is logged on` | Two people are signed in; the script will not guess. | Add `$env:PrinterSetupUser = 'DOMAIN\name'`. |
| `Nobody is logged on` | There is no user session to fix. | Ask them to sign in first. |
| `VERDICT: ABSENT` | The printer really is not there. | Add it. |
| OneDrive `RESULT: DEGRADED` | Running but its log is stale — idle or stuck | restart OneDrive, or re-link |
| `RESULT: PARTIAL` (OneDrive) | Some accounts did not sign back in. | Sign the named account in; or enable silent sign-in. |

### Read the result without running anything again

If a command was killed before it printed, the work usually still finished. This prints
the last result — it changes nothing:

```
#!ps
$f = Get-ChildItem 'C:\Users\*\AppData\Local\Temp\PrinterCheck-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($f) { Get-Content $f.FullName } else { 'nothing yet - give it a few seconds' }
```

---

## Words used on this page

| Word | Plain meaning |
|---|---|
| **Queue** | The printer's own name on the server. The last part of `\\server\queue`. |
| **Server** | The machine that shares the printer. The first part of `\\server\queue`. |
| **Driver** | The small piece of software Windows needs before it can talk to a printer. |
| **SYSTEM** | The invisible Windows account your remote tool runs as. Printers it adds go to SYSTEM, not to the person — which is the whole problem these scripts solve. |
| **Environment variable** (`$env:...`) | A temporary named value in the window you are typing in. It disappears when that window closes. Used here so no printer name is written into the script. |
| **HKCU** | The part of the Windows settings store that belongs to *one person*. Everything a user "has" — printers, OneDrive — is recorded there. |
| `irm` / `iex` | `irm` downloads a web page; `iex` runs what it downloaded. Together: "run this script from the internet without saving it". |

---

## How it works (one paragraph)

Printers and OneDrive settings belong to a person, not to the PC. Your remote tool runs
as SYSTEM, so a printer added there would vanish into SYSTEM's own settings and the user
would never see it. These scripts detect that situation and start a short-lived scheduled
task **owned by the person who is logged in**, so the work happens in their account.
Nothing appears on their screen and you never take over their desktop.

---

## For whoever maintains this

- Full command reference and every option: **[REFERENCE.md](REFERENCE.md)**
- Run by the logged-on user (Intune "logged on credentials", GPO logon script, or a
  normal console) and the scripts skip the scheduling step and just do the work.
- Exit code **0** means verified: the script reads the per-user store back
  (`HKCU:\Printers\Connections\...` or the OneDrive `Accounts` key) and fails if the
  change is not there. Exit **1** always carries a reason in the log.
- Logs: `C:\Users\<user>\AppData\Local\PrinterToolkit\` and `...\OneDriveRelink\`.
- Tests (mock harnesses, run anywhere including Linux + PowerShell 7):
  `pwsh -File tests/test-printer.ps1` (26 assertions) and
  `pwsh -File tests/test-bridge.ps1` (14 assertions). Both exit non-zero on any failure.
- Not code-signed. Add your own signing step if your environment requires it.
- Requires outbound HTTPS to `gist.githubusercontent.com` for the paste-one-liners; on a
  box behind a strict egress proxy, save the file locally and run it instead.
