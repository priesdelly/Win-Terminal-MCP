# WinTerminalMCP

## What this is

An MCP (Model Context Protocol) server that lets an LLM drive a **real, persistent shell process** on Windows — not a throwaway shell. It starts a real `cmd.exe`/`pwsh.exe`/`powershell.exe` process attached to its own Windows pseudo console (ConPTY), types into it like a person would, reads back what it printed, and sends a real Ctrl+`<key>` scoped to one session, by writing the literal control byte into that session's own input pipe.

It is a clean-room rewrite of `capecoma/winterm-mcp`, built to fix two problems in that project: it never actually controlled a persistent terminal (spawned a throwaway `cmd.exe` per call), and its Ctrl+C ran `taskkill /im node.exe /f`, killing every Node process on the machine.

An earlier version of this project drove the real `wt.exe` GUI application via UI Automation and simulated keystrokes, so a human could watch commands run in a visible window. That approach was replaced (2026-08-24) after proving live on this machine that synthetic keystroke injection (`SendInput`/`keybd_event`) is unreliable when the system's active keyboard layout isn't English — see the "Current known status" section below for what was found and why ConPTY was chosen instead.

## Working method

Before starting any non-trivial change, search the web thoroughly first. Gather what you find, weigh it, and settle on one approach before writing code.

A task is not done when the code is written. Test it against the actual expected result. Only report the task complete once that result is confirmed.

## Security — mandatory, never skip

These rules apply every time, without exception. Do not relax them under time pressure, a request to move faster, or user pushback.

- **Source trust.** For any security-relevant code (input handling that reaches a shell, process spawning, session/identity checks, anything near `dangerousPatterns`), reference only official vendor documentation and official sample code (Microsoft Learn, the `microsoft/terminal` repo itself, etc.). Never port code, structure, or patterns from offensive-security tools (reverse shells, C2 frameworks, exploit PoCs) — even when the underlying OS primitives are identical and the intent here is defensive. Matching an offensive tool's code shape is itself a supply-chain and trust risk, independent of what the code does.
- **Red team / blue team gate.** Any change that touches a security-relevant surface (`safety.ts`, text that reaches a shell, process spawning, session/identity handling, `dangerousPatterns`) must be reviewed by two separate agents before it counts as done — not one self-graded pass:
  - Spawn a **red-team agent** whose only job is to attack the change: find a bypass, an injection point, a spoofing angle, a privilege escalation. It should assume nothing works until it fails to break it.
  - Spawn a **blue-team agent** to independently verify, against the real running code (not a read-through), that what red team found is actually closed and nothing that worked before regressed.
  Repeat until red team comes up empty. Write the result to `test-result/` (Thai + English, per the existing convention) the same way `QA-RedTeam-Report` already does.

## Architecture at a glance

Two processes talk newline-delimited JSON over stdio:

```
Claude / MCP client
      │  MCP tool calls (stdio)
      ▼
src/index.ts ──registers──▶ 7 tools (list/open/write/read/send_control_character/close/debug)
      │
      │  JSON-lines over child-process stdio (see src/daemonClient.ts)
      ▼
helper/daemon.ps1   long-lived PowerShell process, one per MCP server instance
      │  in-memory $script:Sessions: name -> {shell, cwd, pid, createdAt, Session}
      ▼
helper/PtySession.psm1   does the real work: Windows Pseudo Console (ConPTY) via
      │                  CreatePseudoConsole/CreateProcess P/Invoke, background
      │                  reader thread per session
      ▼
cmd.exe / pwsh.exe / powershell.exe   real, persistent, headless child process
```

Each "session" is one real child process attached to its own ConPTY, held alive in `$script:Sessions` for the daemon's whole lifetime — there is no window to lose track of and re-find, unlike the earlier UI-Automation-based design.

## Key files

| File | Role |
|---|---|
| `src/index.ts` | MCP server entrypoint. Registers all 7 tools, validates input with Zod, calls the daemon, writes audit-log entries. |
| `src/daemonClient.ts` | Spawns and talks to the PowerShell daemon over JSON-lines stdio (`DaemonClient` class). One daemon per server process. |
| `src/config.ts` | Loads optional `config.json` (gitignored) and deep-merges it over `DEFAULT_CONFIG`. |
| `src/constants.ts` | `DEFAULT_CONFIG` — default shells, `dangerousPatterns` list, output/command limits. |
| `src/safety.ts` | `checkCommand()` — enforces `readOnlyMode` and `maxCommandLength`, then screens `write_to_terminal`'s `command` text against `dangerousPatterns`. Screens nothing else (not `name`, not `cwd`). |
| `src/logger.ts` | Appends one JSON line per action to `logs/commands.log`, rotates at 5MB. |
| `src/types.ts` | Shared TypeScript interfaces: `AppConfig`, `SessionInfo`/`SessionSummary`, `DaemonRequest`/`DaemonResponse`. |
| `helper/daemon.ps1` | Long-lived PowerShell process. Reads JSON-lines from stdin, dispatches to `Invoke-Action`, writes JSON-lines to stdout. Owns `$script:Sessions`. |
| `helper/PtySession.psm1` | All ConPTY/Win32 logic: create a pseudo console, spawn the shell attached to it, write input, read captured output, send Ctrl+`<key>`, terminate it. The P/Invoke signatures and pseudo-console lifecycle are ported from Microsoft's own official sample (`microsoft/terminal/samples/ConPTY/MiniTerm`) — see the Security policy above. |
| `config.example.json` | Template for a local `config.json` (safety patterns, shells, limits, `readOnlyMode`). |
| `test-result/` | Referenced by the status note below but **does not currently exist in this repo** — treat any mention of it as aspirational until it's created. |
| `test-case/` | Same as above — referenced but not present on disk. |

## Documentation language

Every document under `test-result/` and `test-case/` (and any similar report/test-case folder added later) must exist in both Thai and English. Follow the naming convention already used in `test-result/`: the Thai version has no suffix (e.g. `basic-session-e2e.md`), the English version has an `-EN` suffix (e.g. `basic-session-e2e-EN.md`). This rule is about docs under this project directory only — it does not apply to `CLAUDE.md` itself, which stays English-only per the user's global instructions.

## Tools exposed

`list_terminal_sessions`, `open_terminal_session`, `write_to_terminal`, `read_terminal_output`, `send_control_character`, `close_terminal_session`, `debug_inspect_sessions`. Full schemas and descriptions live in `src/index.ts`.

Writing to session name `"default"` auto-creates it with the configured default shell — `open_terminal_session` only needs to be called explicitly for a second, independently-named session or a non-default shell/cwd.

## Safety mechanisms (as designed — see "Current known status" below for real gaps found)

- `dangerousPatterns`: regex blocklist checked against `write_to_terminal`'s `command` text only. A match blocks unless the call is resent with `confirm: true`.
- `readOnlyMode`: disables `write_to_terminal` entirely when `true` in `config.json`.
- `maxCommandLength`: one `write_to_terminal` call is rejected above 4000 characters (default).
- Audit log: every write/interrupt/open/close appended to `logs/commands.log` (plain JSON lines).
- Ctrl+`<key>` is the literal control byte written directly into one session's own ConPTY input pipe — not a machine-wide kill signal, and not a keystroke that could land on an unrelated window.

## Build & dev

```powershell
npm install
npm run build     # tsc -> dist/
npm run dev       # tsc -w
```

`dist/index.js` locates `helper/daemon.ps1` relative to its own path — keep `dist/` and `helper/` together when deploying; don't copy `index.js` out on its own.

Parse-check the PowerShell files without running them (their ConPTY/P-Invoke calls only work on Windows):

```powershell
pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("helper/daemon.ps1", [ref]$null, [ref]$null)'
```

## Current known status

**2026-08-24 — replaced UI Automation with ConPTY.** Simulated keystrokes (`SendInput`/`keybd_event`) were unreliable: this machine's default input layout for new windows is Thai, so typed ASCII came out corrupted regardless of the `KEYEVENTF_UNICODE` workaround, on top of a focus-stealing race. `helper/PtySession.psm1` (ported from Microsoft's official `microsoft/terminal/samples/ConPTY/MiniTerm`) writes bytes directly into the shell's own input pipe instead — no keyboard, focus, or layout involved. Verified via a real `@modelcontextprotocol/sdk` `Client` driven against the built `dist/index.js`, not just the PowerShell layer: full tool round-trip, session persistence, uncorrupted text, dangerous-pattern blocking.

**Red-team/blue-team review (per the Security policy above) found and fixed, all re-verified:**
- `cwd` accepted UNC paths → forced-authentication risk plus a ~21s freeze of the whole daemon (single-threaded dispatch, one call blocks every session). `New-PtySession` now rejects `\\`/`//`-prefixed or nonexistent `cwd` before ever calling `CreateProcess`.
- `dangerousPatterns` bypassed via PowerShell backtick (`` Rem`ove-Item ``, which parses as `Remove-Item`). `checkCommand()` now also matches a backtick-stripped copy — a targeted fix for this one bypass, not a claim of completeness.
- Splitting a dangerous command across two `write_to_terminal` calls (`pressEnter:false` then the rest) defeated the single-call check. `write_to_terminal` now tracks each session's pending unsubmitted line and checks the full accumulated text.
- `daemon.ps1` crashed under `Set-StrictMode` when a request omitted `pressEnter`/`lines`/`shellArgs`. Fixed with `PSObject.Properties[...]` guards.
- `CreateProcess`'s P/Invoke was missing `SetLastError = true`, producing misleading errors. Added.

**Known limitations:**
- Ctrl+C cannot reliably cancel a not-yet-submitted PSReadLine input line (it only delivers conhost's `CTRL_C_EVENT` signal, not the keypress PSReadLine's own key-binding needs) — close and reopen the session instead. Sending it can also inject a stray Thai character (`U+0E41`) into conhost's own VT redraw on this machine.
- `dangerousPatterns` is still a regex blocklist, not a sandbox — only the backtick and split-call bypasses above are closed.
- A local directory symlink pointing at a UNC target slips past the `cwd` check (needs prior shell access to create, so not a new capability).
- `%PATHEXT%` truncated to `.CPL` in this specific sandboxed dev environment made bare `whoami`/`where` fail while builtins and full paths worked — an artifact of this dev environment, not `PtySession.psm1`.

**Not done:** `test-result/`/`test-case/` are referenced elsewhere in this file but don't exist in the repo — nothing has been written up there yet.
