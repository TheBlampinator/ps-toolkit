# ps-toolkit

Two self-bridging PowerShell scripts that fix **per-user** state on Windows when your
only shell is `NT AUTHORITY\SYSTEM` — ScreenConnect Backstage, the ConnectWise Control
Commands tab or Toolbox, `PsExec -s`, most RMM agents. Plus a paste-only variant of the
printer script for when nothing can be uploaded, and a read-only checker that reports
what the logged-on user actually has.

| Script | Does |
|---|---|
| [`Add-PrinterAsUser.ps1`](Add-PrinterAsUser.ps1) | Adds / removes / verifies a network printer connection for the logged-on user |
| [`Reset-OneDriveLink-2.ps1`](Reset-OneDriveLink-2.ps1) | Unlinks and re-links OneDrive for the logged-on user |
| [`Printer-Setup-Paste.ps1`](Printer-Setup-Paste.ps1) | Same printer job, zero install: edit 4 lines at the top, paste the whole file into PowerShell |
| [`Printer-Check.ps1`](Printer-Check.ps1) | Read-only: lists the logged-on user's printers, marks the default, and reports whether a specific queue is present |

Full command reference: **[REFERENCE.md](REFERENCE.md)**

> ### Blocked by the execution policy?
>
> PowerShell checks the policy before it reads the file, so the bypass has to come from
> whatever launches the script. Put it on the command line:
>
> ```powershell
> powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 `
>     -PrinterPath '\\print01\FIN-HP4525'
> ```
>
> Or set it for the current window only (resets when the window closes):
>
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```
>
> Details and caveats: [REFERENCE.md §0](REFERENCE.md#0-running-it--getting-past-the-execution-policy).

## The problem these solve

A printer connection lives in `HKCU\Printers\Connections`. OneDrive's account
registration lives in `HKCU\Software\Microsoft\OneDrive\Accounts`. Both are per-user.

Run `Add-PrinterConnection` from a SYSTEM shell and it succeeds — into the SYSTEM
profile. The user sees nothing, and you've marked the ticket resolved. That's the
silent failure these scripts exist to prevent.

## How they work

Each script is a single file that picks its own mode:

- **Run as the logged-on user** (manual run, Intune "logged on credentials", GPO logon
  script) → it just does the work.
- **Run as SYSTEM** → it stages a copy of itself in `C:\ProgramData\<Tool>\`, registers
  a one-shot scheduled task owned by the interactive user with
  `-LogonType Interactive`, re-invokes itself there with `-Payload`, waits, prints the
  user-session log, and removes the task.

No desktop session, no screen share, no interruption. The scheduled task is the
bridge; SYSTEM is only the launcher.

## Quick start

PowerShell checks the execution policy before it reads a script, so a `.ps1` can't
exempt itself — the bypass has to come from the command line:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 `
    -PrinterPath '\\print01\FIN-HP4525' -SetDefault

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 `
    -PrinterPath '\\print01\FIN-HP4525' -Verify

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-OneDriveLink-2.ps1 -Account All
```

Already in a PowerShell window you control? Unblock the window once, then call the
scripts directly:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Add-PrinterAsUser.ps1 -PrinterPath '\\print01\FIN-HP4525' -SetDefault
```

No file on the box at all? Paste `Printer-Setup-Paste.ps1` into an interactive
session — typing into the console isn't subject to the execution policy.

Both scripts refuse to run rather than degrading to SYSTEM: the payload throws if it finds
itself as SYSTEM, and `-Verify` checks the *user's* hive, not SYSTEM's.

## Exit 0 means verified

Neither script trusts the cmdlet's return. The payload reads the per-user store back
(`HKCU:\Printers\Connections\,,server,queue`, or the OneDrive `Accounts` key) and
throws if the state isn't there — so exit 0 from the bridge means the change actually
landed for that user, and exit 1 always carries a reason in the log.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- A logged-on interactive user. Nothing here works unattended — a per-user fix needs a
  session to fix.
- `Get-Process -IncludeUserName` needs elevation, which a SYSTEM shell already has.
- Printer driver: if it isn't on the machine and
  `RestrictDriverInstallationToAdministrators=1` blocks install, use `-Elevated`.

## Tests

`tests/` holds mock harnesses that execute the scripts' real function bodies against
stubbed Windows cmdlets — they prove syntax, control flow and argument construction on
any platform, including Linux with PowerShell 7. They cannot prove Task Scheduler,
registry or spooler behaviour; that needs an endpoint.

```powershell
pwsh -NoProfile -File tests/test-printer.ps1   # 24 assertions
pwsh -NoProfile -File tests/test-bridge.ps1    # 12 assertions (1 needs Windows)
```

## Caveats

- Auto-detect reads `explorer.exe` owners, so it sees every interactive session. It
  **refuses to guess** when more than one is logged on — pass `-User 'DOMAIN\name'`.
- Closing the Backstage tab mid-run leaves the scheduled task registered; the payload
  still completes, but remove it with `Unregister-ScheduledTask`.
- These scripts are not signed. Add your own code-signing step if your environment
  requires it.
