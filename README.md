# ps-toolkit

Two PowerShell scripts that fix **per-user** state on Windows when your only shell is
`NT AUTHORITY\SYSTEM` — ScreenConnect Backstage, the ConnectWise Control Commands tab
or Toolbox, `PsExec -s`, most RMM agents.

| Script | Does |
|---|---|
| [`Add-PrinterAsUser.ps1`](Add-PrinterAsUser.ps1) | Adds / removes / verifies a network printer connection for the logged-on user |
| [`Reset-OneDriveLink-2.ps1`](Reset-OneDriveLink-2.ps1) | Unlinks and re-links OneDrive for the logged-on user |

Full command reference: **[REFERENCE.md](REFERENCE.md)**

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

Use the `.cmd` launcher next to each script — it applies
`-ExecutionPolicy Bypass` for you, so there is no `Set-ExecutionPolicy` step:

```bat
Add-PrinterAsUser.cmd -PrinterPath '\\print01\FIN-HP4525' -SetDefault
Add-PrinterAsUser.cmd -PrinterPath '\\print01\FIN-HP4525' -Verify
Reset-OneDriveLink.cmd -Account All
```

Or call the `.ps1` directly with the bypass explicit (a script cannot exempt itself —
the policy is applied before the file is read):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Add-PrinterAsUser.ps1 `
    -PrinterPath '\\print01\FIN-HP4525' -SetDefault
```

Both refuse to run rather than degrading to SYSTEM: the payload throws if it finds
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
