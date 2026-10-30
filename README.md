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
irm https://gist.githubusercontent.com/TheBlampinator/e8c8f5e9efb6689f285c9d54ddbfd46d/raw/Start-PSToolkit.ps1 | iex
```

```
------------------------------------------------------------
  What do you want to do?
------------------------------------------------------------
    1   Add a printer
    2   Check which printers they have  (read-only)
    3   Fix OneDrive
    4   Exit

  Choose 1-4:
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
irm https://gist.githubusercontent.com/TheBlampinator/84923f2c6a155cfa245a353e3e00f995/raw/84c0d270f46e00119d2f60fb3348177a967423e9/Printer-Setup-Paste.ps1 | iex
```

**Step 3.** Paste all four lines into the Commands box and run it.

**Step 4.** Read the result. It will say one of these:

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
The printer's software (the "driver") is not on this PC and Windows will not let a
normal user install it. Re-run with this extra line second from the top:

```
$env:PrinterSetupElevated = 'true'
```

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
irm https://gist.githubusercontent.com/TheBlampinator/8905bde8066b4057770126ad5550f0ad/raw/da21a3dc1828eaee7b49b7b5a8f29be69eaaee34/Printer-Check.ps1 | iex
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

```
#!ps
#timeout=600000
$f = "$env:TEMP\Reset-OneDriveLink-2.ps1"
irm https://gist.githubusercontent.com/TheBlampinator/4faca813edea0891225baed59a7fb2db/raw/Reset-OneDriveLink-2.ps1 -OutFile $f
& $f -Account All
```

If the person uses only a work/school account you can leave `-Account All` off.

OneDrive restarts by itself. If your organisation has not turned on "silently sign in",
the user will see a OneDrive sign-in window — tell them it is coming, or run this while
they are at lunch.

---

## If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `Killed after 10000 milliseconds` | ScreenConnect stopped the command after 10 seconds. | Check the four lines have no blank line between them. The work may still have happened — read the result (below). |
| `STOPPED - ... NOTHING WAS CHANGED` | A setting was missing or the address was malformed. | Read the message, it shows the exact line to type. |
| `Missing type name after '['` | You pasted *output* instead of the script. | The real script starts with `#!ps`. Clear the box and paste again. |
| `Access is denied` | The printer's driver cannot be installed by a normal user. | Add the `$env:PrinterSetupElevated = 'true'` line. |
| `More than one user is logged on` | Two people are signed in; the script will not guess. | Add `$env:PrinterSetupUser = 'DOMAIN\name'`. |
| `Nobody is logged on` | There is no user session to fix. | Ask them to sign in first. |
| `VERDICT: ABSENT` | The printer really is not there. | Add it. |

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
  `pwsh -File tests/test-bridge.ps1` (14 assertions, 1 requires Windows).
- Not code-signed. Add your own signing step if your environment requires it.
- Requires outbound HTTPS to `gist.githubusercontent.com` for the paste-one-liners; on a
  box behind a strict egress proxy, save the file locally and run it instead.
