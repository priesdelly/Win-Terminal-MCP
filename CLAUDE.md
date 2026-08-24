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
| `src/safety.ts` | `checkCommand()` — screens `write_to_terminal`'s `command` text against `dangerousPatterns`. Screens nothing else (not `name`, not `cwd`). |
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

## Safety mechanisms (as designed — see `test-result/` for real gaps found)

- `dangerousPatterns`: regex blocklist checked against `write_to_terminal`'s `command` text only. A match blocks unless the call is resent with `confirm: true`.
- `readOnlyMode`: disables `write_to_terminal` entirely when `true` in `config.json`.
- Audit log: every write/interrupt/open/close appended to `logs/commands.log` (plain JSON lines).
- Ctrl+`<key>` is the literal control byte written directly into one session's own ConPTY input pipe — not a machine-wide kill signal, and not a keystroke that could land on an unrelated window.

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

**2026-08-24: the terminal-control approach was rewritten from UI Automation to ConPTY.** A user testing the previous (UI-Automation + simulated-keystroke) version through Claude Desktop reported that typed text wasn't landing on the real `wt.exe` window at all. Investigating on this machine found two real, distinct bugs, both fixed in that architecture at the time:

1. A race between `SendInput`'s asynchronous key delivery and a `Restore-ForegroundWindow` call that stole focus back immediately afterward, before Windows Terminal's message loop had dispatched the queued keystrokes.
2. More fundamentally: `SendInput`+`KEYEVENTF_UNICODE` does not reliably bypass the active keyboard layout on this machine. This machine's fresh-window default input layout is Thai (`0x041E`, confirmed via `GetKeyboardLayout`), and typed ASCII text came out corrupted (verified with a live Notepad test) regardless of the Unicode-packet approach.

Rather than keep fighting the OS input stack (focus-stealing, IME/layout dependence, no reliable way to guarantee delivery), the whole keystroke-injection design was replaced with ConPTY (`helper/PtySession.psm1`, ported from Microsoft's official `microsoft/terminal/samples/ConPTY/MiniTerm` sample — see the Security policy above for why only that source was used). This trades away the "watch it happen in a real visible `wt.exe` window" feature for a fundamentally more reliable transport: text is written as raw bytes into the child process's own input pipe, with no keyboard, focus, or window involved at all.

**A second real bug was found and fixed during the ConPTY port itself**, worth recording because it is not obvious from the official sample: when the *calling* process's own stdio is redirected/piped (true for a daemon with no real console of its own — confirmed live on this machine, including with a from-scratch `dotnet run` reproduction outside PowerShell entirely, to rule out a PowerShell-hosting artifact), Windows duplicates those redirected handles into the ConPTY-attached child regardless of `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, so the child's output leaks to wherever the parent's redirected stdout points instead of the pseudo console. The fix (confirmed by a `microsoft/terminal` maintainer, https://github.com/microsoft/terminal/discussions/15814) is `STARTF_USESTDHANDLES` set on the child's `STARTUPINFOEX.dwFlags`, with the std handles themselves left null — see the comment at that exact line in `PtySession.psm1`.

**Verification status:** this pass went further than any previous one — it includes a real, full MCP round-trip. Node.js/npm are now installed on this machine (`npm install && npm run build` succeeds with no TypeScript errors), and a real `@modelcontextprotocol/sdk` `Client` was driven against the actual built `dist/index.js` over real stdio: `tools/list`, `open_terminal_session`, `write_to_terminal`, `read_terminal_output`, `send_control_character`, `list_terminal_sessions`, `debug_inspect_sessions`, `close_terminal_session`, and the `dangerousPatterns` block-then-`confirm:true` flow all worked correctly end to end, including a session-persistence check (`cd`-equivalent state, i.e. one `whoami`/`echo` pair in the same session sharing history) and a check that ASCII text written into the pty comes back uncorrupted (the Thai-layout bug from the old approach does not reproduce here, since no keyboard layout is involved at all).

**Known non-issue, in case it resurfaces:** during this same testing, external `.exe` commands (`whoami`, `where`) inside a session failed with "not recognized" while cmd.exe builtins (`echo`) worked fine. Traced to `%PATHEXT%` being truncated to just `.CPL` in this specific sandboxed dev environment's own process environment (confirmed via `echo %PATHEXT%` inside a live session, and confirmed the full path / explicit `.exe` extension both work) — not a bug in `PtySession.psm1`. A normal Windows environment (and Claude Desktop's own process environment) will not have this problem.

**Red-team/blue-team review was run for this change** (per the Security policy above) and found real, live-confirmed issues, all now fixed and independently re-verified except two left deliberately open:

- **Fixed** — `open_terminal_session`'s `cwd` reached `CreateProcess`'s `lpCurrentDirectory` with no validation. A UNC path caused real SMB negotiation (forced-authentication risk) and blocked the daemon's single-threaded synchronous dispatch loop for ~21s against an unreachable host - a DoS against every other open session from one call. `New-PtySession` (`PtySession.psm1`) now rejects any `cwd` starting with `\\`/`//` and requires the path to exist locally, before ever calling `CreateProcess`. Verified: UNC input now throws in single-digit ms instead of ~21s; a local directory *symlink* pointing at a UNC target does slip past this check (flagged, not fixed - it needs local shell access to create first, at which point `cd \\host\share` directly is no new capability).
- **Fixed** — `dangerousPatterns` in `src/safety.ts` was trivially bypassed with a PowerShell backtick (`` Rem`ove-Item `` parses and runs as `Remove-Item` but doesn't match the pattern). `checkCommand()` now also matches a backtick-stripped copy of the command. This is a narrow, targeted fix for the one demonstrated bypass, not a claim of completeness - a regex blocklist cannot cover every way to spell a command in a Turing-complete shell.
- **Fixed** — splitting a dangerous command across two `write_to_terminal` calls (`pressEnter:false` then the rest) defeated the single-call check, since each half looks safe alone. `src/index.ts` now tracks each session's not-yet-submitted line (`pendingLine`) and checks the full accumulated text on every call, clearing it when the line is actually submitted or the shell's line is otherwise reset (Ctrl+`<key>`, session open/close).
- **Fixed** — `daemon.ps1` used unguarded `$Params.pressEnter`/`$Params.lines`/`$Params.shellArgs` access, which throws under `Set-StrictMode` if a caller omits the key (not reachable through the shipped Zod schemas today, but latent). All three now check `$Params.PSObject.Properties[...]` first, matching the pattern the `cwd`/`timeoutMs` fix from the old UI-Automation era used.
- **Fixed, incidentally** — `CreateProcess`'s P/Invoke declaration in `PtySession.psm1` was missing `SetLastError = true` (unlike every other kernel32 import in the file), which produced misleading `GetLastWin32Error()` values after a real failure. Added.

**Discovered while fixing the above, left open, real UX limitation:** the fix for the split-command bypass initially tried to auto-clear the stuck unsent fragment with Ctrl+C when a block occurred. That doesn't work reliably: sending Ctrl+C over this ConPTY transport only delivers conhost's `CTRL_C_EVENT` *signal* (which does nothing to an idle prompt - confirmed, matches expected behavior), not the distinct "Ctrl+C as a keypress" that PSReadLine's own key-binding needs to cancel an in-progress, not-yet-submitted line - so the stuck fragment stays put, and on top of that, sending it measurably injects a stray character (`U+0E41`, a Thai letter - the same Thai-locale quirk from the keystroke-injection era, this time inside conhost's own VT redraw, not our code) into the session's output. The auto-clear was removed; `write_to_terminal`'s blocked-response now tells the caller there is no reliable way to clear just that line and to close/reopen the session instead. `send_control_character`'s tool description was updated to say the same thing plainly.

**Verification status:** this pass went further than any previous one — it includes a real, full MCP round-trip. Node.js/npm are now installed on this machine (`npm install && npm run build` succeeds with no TypeScript errors), and a real `@modelcontextprotocol/sdk` `Client` was driven against the actual built `dist/index.js` over real stdio: `tools/list`, `open_terminal_session`, `write_to_terminal`, `read_terminal_output`, `send_control_character`, `list_terminal_sessions`, `debug_inspect_sessions`, `close_terminal_session`, the `dangerousPatterns` block-then-`confirm:true` flow, and all five red-team/blue-team fixes above were verified through this same real client-to-built-server path (not just at the PowerShell layer) — including a session-persistence check (`cd`-equivalent state, i.e. one `whoami`/`echo` pair in the same session sharing history) and a check that ASCII text written into the pty comes back uncorrupted (the Thai-layout bug from the old keystroke-injection approach does not reproduce for typed text here, since no keyboard layout is involved in that path at all - only the separate Ctrl+C-echo quirk noted above does).

**Known non-issue, in case it resurfaces:** during this same testing, external `.exe` commands (`whoami`, `where`) inside a session failed with "not recognized" while cmd.exe builtins (`echo`) worked fine. Traced to `%PATHEXT%` being truncated to just `.CPL` in this specific sandboxed dev environment's own process environment (confirmed via `echo %PATHEXT%` inside a live session, and confirmed the full path / explicit `.exe` extension both work) — not a bug in `PtySession.psm1`. A normal Windows environment (and Claude Desktop's own process environment) will not have this problem.

**Not yet done:** `test-result/` and `test-case/` are referenced elsewhere in this file but do not exist in the repo — this session's red-team/blue-team findings above have not been written up there (Thai + English) per the existing convention.
