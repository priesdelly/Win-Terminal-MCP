# WinTerminalMCP

## What this is

An MCP (Model Context Protocol) server that lets an LLM drive the **real Windows Terminal application** (`wt.exe`) — not a throwaway shell. It opens actual tabs, types into them like a person would, reads back what's rendered on screen, and sends a real Ctrl+`<key>` scoped to one pane, using Windows UI Automation (the same mechanism screen readers use).

It is a clean-room rewrite of `capecoma/winterm-mcp`, built to fix two problems in that project: it never actually controlled a persistent terminal (spawned a throwaway `cmd.exe` per call), and its Ctrl+C ran `taskkill /im node.exe /f`, killing every Node process on the machine.

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
      │  in-memory $script:Sessions: name -> {marker, shell, cwd, hwnd, createdAt}
      ▼
helper/WtControl.psm1   does the real work: UI Automation + Win32 keybd_event/SendKeys
      │
      ▼
wt.exe / Windows Terminal   real GUI window, real tabs
```

Each "session" is one `wt.exe` tab, tagged at creation with a marker in its title (`MCP::<name>::<8-hex-suffix>`) so the daemon can re-find it on later calls without holding stale UI Automation references (Windows Terminal recreates parts of its UI tree on tab switches).

## Key files

| File | Role |
|---|---|
| `src/index.ts` | MCP server entrypoint. Registers all 7 tools, validates input with Zod, calls the daemon, writes audit-log entries. |
| `src/daemonClient.ts` | Spawns and talks to the PowerShell daemon over JSON-lines stdio (`DaemonClient` class). One daemon per server process. |
| `src/config.ts` | Loads optional `config.json` (gitignored) and deep-merges it over `DEFAULT_CONFIG`. |
| `src/constants.ts` | `DEFAULT_CONFIG` — default shells, `dangerousPatterns` list, output/command limits, UIA timing settings. |
| `src/safety.ts` | `checkCommand()` — screens `write_to_terminal`'s `command` text against `dangerousPatterns`. Screens nothing else (not `name`, not `cwd`). |
| `src/logger.ts` | Appends one JSON line per action to `logs/commands.log`, rotates at 5MB. |
| `src/types.ts` | Shared TypeScript interfaces: `AppConfig`, `SessionInfo`/`SessionSummary`, `DaemonRequest`/`DaemonResponse`. |
| `helper/daemon.ps1` | Long-lived PowerShell process. Reads JSON-lines from stdin, dispatches to `Invoke-Action`, writes JSON-lines to stdout. Owns `$script:Sessions`. |
| `helper/WtControl.psm1` | All UI Automation + Win32 logic: open a tab, re-find it, read its text, send keystrokes/Ctrl+`<key>`, close it. |
| `config.example.json` | Template for a local `config.json` (safety patterns, shells, limits, `readOnlyMode`). |
| `test-result/` | QA + Red Team audit findings and tested fixes — **read before assuming this tool works** (see below). |
| `test-case/` | End-to-end test cases for this project. |

## Documentation language

Every document under `test-result/` and `test-case/` (and any similar report/test-case folder added later) must exist in both Thai and English. Follow the naming convention already used in `test-result/`: the Thai version has no suffix (e.g. `basic-session-e2e.md`), the English version has an `-EN` suffix (e.g. `basic-session-e2e-EN.md`). This rule is about docs under this project directory only — it does not apply to `CLAUDE.md` itself, which stays English-only per the user's global instructions.

## Tools exposed

`list_terminal_sessions`, `open_terminal_session`, `write_to_terminal`, `read_terminal_output`, `send_control_character`, `close_terminal_session`, `debug_inspect_windows`. Full schemas and descriptions live in `src/index.ts`.

Writing to session name `"default"` auto-creates it with the configured default shell — `open_terminal_session` only needs to be called explicitly for a second, independently-named session or a non-default shell/cwd.

## Safety mechanisms (as designed — see `test-result/` for real gaps found)

- `dangerousPatterns`: regex blocklist checked against `write_to_terminal`'s `command` text only. A match blocks unless the call is resent with `confirm: true`.
- `readOnlyMode`: disables `write_to_terminal` entirely when `true` in `config.json`.
- Audit log: every write/interrupt/open/close appended to `logs/commands.log` (plain JSON lines).
- Ctrl+`<key>` is a real, focused keystroke sent only to the pane in focus at send time — not a machine-wide kill signal.

## Build & dev

```powershell
npm install
npm run build     # tsc -> dist/
npm run dev       # tsc -w
```

`dist/index.js` locates `helper/daemon.ps1` relative to its own path — keep `dist/` and `helper/` together when deploying; don't copy `index.js` out on its own.

Parse-check the PowerShell files without running them (their UIA/WinForms calls only work on Windows):

```powershell
pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("helper/daemon.ps1", [ref]$null, [ref]$null)'
```

## Current known status — read this before assuming the tool works

A QA + Red Team pass (2026-08-23) found that the server did not function at all with the default config, plus one Critical, live-confirmed security bug. Full root-cause analysis, evidence, and the original tested fixes are written up in `test-result/QA-RedTeam-Report-EN.md` (English, detailed) and `test-result/QA-RedTeam-Report.md` (Thai original) — read that report for background before touching `daemon.ps1`/`WtControl.psm1`/`safety.ts` again.

As of this check (2026-08-23), **all 8 of the report's findings are fixed in the code**:

1. **Fixed** — `helper/daemon.ps1` no longer computes `$ModulePath`'s default from `$PSScriptRoot` inside `param()`; it resolves the path in the script body instead, after the `param()` block finishes.
2. **Fixed** — `open_session` in `daemon.ps1` reads `$Params.timeoutMs` / `$Params.cwd` through `PSObject.Properties[...]` existence checks, so it no longer throws under `Set-StrictMode -Version Latest` when Node omits those keys.
3. **Fixed, both layers** — `Open-WtSession` in `WtControl.psm1` builds its command line through `Format-ArgumentForCommandLine` and starts `wt.exe` via `ProcessStartInfo` instead of unquoted `Start-Process -ArgumentList` (Layer 1). `src/index.ts`'s `name` schema is also now restricted to `^[A-Za-z0-9_-]+$` (Layer 2).
4. **Fixed** — `Bring-WtWindowToForeground` checks `SetForegroundWindow`'s return value and throws if it's `false`, then re-verifies with `GetForegroundWindow()` before returning, instead of sending keystrokes on unconfirmed focus.
5. **Fixed** — the `dangerousPatterns` regexes now compile with the `s` (dotAll) flag, and the pattern list adds alias coverage (`rm`/`ri`/`del`/`erase`) plus a reversed-argument-order variant, closing all three bypasses the report demonstrated.
6. **Fixed** — `Import-Module` in `daemon.ps1` now passes `-WarningAction SilentlyContinue`, so the unapproved-verb warning no longer leaks onto stdout and risks corrupting the JSON-lines protocol.
7. **Fixed** — the report's suggested signal (tab `ProcessId`) turned out not to work: it identifies `WindowsTerminal.exe` itself, which is identical for every tab in one window, so it can't disambiguate a spoofed tab from the real one in the (default, `newWindow:false`) common case. Fixed instead with the UIA `RuntimeId` captured for each tab at session-creation time (`Open-WtSession`, `WtControl.psm1`) and threaded through every re-lookup (`Find-WtTabByMarker`'s new `-ExpectedRuntimeId` param, stored per-session in `daemon.ps1`'s `$script:Sessions` and passed by every dispatch branch). When more than one tab shares a marker title, only the one whose RuntimeId matches is trusted; otherwise the daemon throws instead of guessing.
8. **Fixed** — the auto-create-`"default"`-session path inside `write_to_terminal` (`src/index.ts`) now calls `auditLog(...)` right after the session opens, matching the explicit `open_terminal_session` path.

**Verification status:** #1-#8 were confirmed by driving the real `daemon.ps1` protocol directly over stdin/stdout against a real `wt.exe`/`WindowsTerminal.exe` on this machine (open → write → read → close, with real keystrokes and real UI Automation) — including a live PoC for #7 that opened a second tab in the same window retitled to match an active session's exact marker, and confirmed the daemon kept reading/writing the real tab, never the spoofed one. What is still **not** verified: an actual MCP round-trip through Node. This machine still has no Node.js/npm installed, so `npm run build` and a real client → `dist/index.js` → daemon path have never been executed (`test-case/basic-session-e2e-EN.md` is written for exactly this and has not been run yet). Treat the fixes as "verified at the daemon/PowerShell layer" — not as "verified through the actual MCP tool interface" — until that case is run on a machine with Node.
