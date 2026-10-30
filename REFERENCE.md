# PS Toolkit — command reference

Two self-bridging scripts. Run either from a SYSTEM shell (ScreenConnect Backstage,
Commands tab, PsExec -s) or directly as the user; they detect which and adapt.

Location on this Mac/PC: `~/Downloads/PSToolkit` (Linux) — on Windows, wherever you
uploaded them, typically `C:\ProgramData\PrinterToolkit` after the first run.

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
.\Add-PrinterAsUser.ps1 -PrinterPath '\\IBNPS01\Reception printer' -Verify
```

If a run was killed, clean up after it:

```powershell
Get-ScheduledTask -TaskName 'AddPrinter-*','PrinterSetup-*' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false
Get-ChildItem 'C:\ProgramData\PrinterToolkit' -Filter 'PrinterSetup-*.ps1' |
    Remove-Item -Force
```

---

## 0. Running it — no `Set-ExecutionPolicy` step needed

A `.ps1` **cannot** exempt itself: PowerShell checks the execution policy before it
reads the file, so the restriction is applied by whatever launches the script. Use the
`.cmd` launcher next to each script, which passes `-ExecutionPolicy Bypass` on the
command line and forwards your arguments and exit code:

```bat
Add-PrinterAsUser.cmd -PrinterPath '\\IBNPS01\Reception printer' -SetDefault
Reset-OneDriveLink.cmd  -Account All
```

Equivalent one-liner if you'd rather not use the launcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 -PrinterPath '\\IBNPS01\Reception printer'
```

Or set it for the current window only, as before (resets when the window closes):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Notes:

- **The user-session half never needs any of this.** The scheduled task already invokes
  the staged copy with `-ExecutionPolicy Bypass`.
- **GPO-enforced policy wins.** If `Get-ExecutionPolicy -List` shows
  `MachinePolicy` or `UserPolicy` set, the `-ExecutionPolicy` parameter is ignored and
  the `.cmd` won't help — that's a policy change, not a script change.
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
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525'

# add and make it the default
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -SetDefault

# queue name with spaces — quote it
.\Add-PrinterAsUser.ps1 -PrinterPath '\\IBNPS01\Reception printer' -SetDefault

# driver not installed / Point-and-Print blocked
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Elevated

# remove
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Remove

# did it work? (read-only, no changes)
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Verify

# several users logged on — pick one
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -User 'IBN\gnorfor'

# short timeout when you know it should be instant
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -Verify -TimeoutSeconds 60
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

Edit only the config block at the top:

```powershell
$PrinterPath = '\\IBNPS01\Reception printer'   # \\server\printer
$SetDefault  = $true                            # make it the user's default
$Elevated    = $false                           # $true only if the driver won't install
$User        = ''                               # blank = whoever is logged on
```

Then paste everything below it. What it does:

1. Validates the path (`\\server\printer`), then writes a small payload script to
   `C:\ProgramData\PrinterToolkit\PrinterSetup-<stamp>.ps1`.
2. **Already the right user?** Runs the payload in place.
   **In a SYSTEM shell?** Registers a one-shot task as the logged-on user, runs the
   payload there, waits (180 s, heartbeat every 30 s), prints the user-session log.
3. Reads the connection back from `HKCU:\Printers\Connections` and the user's
   `Win32_Printer` list, then prints a green/red `RESULT:` line.
4. Deletes the payload script and the task — unless it timed out, in which case the
   payload is kept and its path printed.

No parameters, no switches. The four config variables are the whole interface.

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
.\Reset-OneDriveLink-2.ps1 -Account All -User 'IBN\gnorfor'
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
Get-Printer -ComputerName print01 | Select-Object Name, DriverName, PortName

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
