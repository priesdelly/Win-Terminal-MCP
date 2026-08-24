# WinTerminal MCP Server

An MCP server that gives Claude a real, persistent shell session on Windows: it starts a real `cmd.exe`/`pwsh.exe`/`powershell.exe` process attached to its own pseudo console (ConPTY), types commands into it exactly like a person would, reads back what it printed, and can send a genuine Ctrl+C — scoped to that one session only.

## Why this exists instead of using capecoma/winterm-mcp

This project was inspired by [`capecoma/winterm-mcp`](https://github.com/capecoma/winterm-mcp), but contains none of its code — it's a clean-room rewrite, built after reading its source (one file, `src/index.ts`) to understand what it does. Two things in that project are worth knowing about, which is exactly why this one exists:

1. **It never actually controls a persistent shell.** Despite the name, `write_to_terminal` just runs `child_process.spawn('cmd.exe', ['/c', command])` — a brand-new, throwaway shell process for every single call. `cd` on one call has zero effect on the next, because there is no persistent shell at all, real or otherwise.
2. **Its Ctrl+C is dangerous.** `send_control_character` for the letter `C` runs `taskkill /im node.exe /f` — which kills **every `node.exe` process on the entire machine**, not the specific command it meant to interrupt. On a dev machine that's likely to also kill unrelated tools, other MCP servers, VS Code's extension host, or anything else built on Node.

This server fixes both: every session is one real, persistent shell process that stays alive across calls, and Ctrl+`<key>` is the literal control byte written straight into that one session's own input pipe — it physically cannot reach an unrelated process, since there is no keyboard, focus, or window involved at all.

## How it works

Two pieces, talking JSON over stdio:

- **`src/` (Node/TypeScript)** — the MCP server itself. Registers the tools, validates input with Zod, screens commands against a configurable "dangerous pattern" list, writes an audit log, and manages a small child process.
- **`helper/` (PowerShell)** — a long-lived background worker (`daemon.ps1` + `PtySession.psm1`) that does the actual Windows-specific work: creating a Windows pseudo console (ConPTY) via `CreatePseudoConsole`, spawning the shell attached to it, writing bytes to its input pipe, and reading its output pipe in the background into an in-memory transcript.

Each "session" is one real child process, held alive for the daemon's whole lifetime — there is no window to lose track of and re-find, because the daemon holds the live process/pipe handles directly for as long as the session exists.

**Nothing runs unless you call a tool.** There's no telemetry, no auto-update, no network access anywhere in this project (check `package.json` — only `@modelcontextprotocol/sdk` and `zod`), no `eval`, no dynamically-fetched code, no obfuscation. Every file is short enough to read end to end in a few minutes.

## Requirements

- Windows 10 (1809+) or Windows 11 — ConPTY (`CreatePseudoConsole`) ships in the OS itself, no extra install needed
- Node.js 18+
- PowerShell — either the built-in Windows PowerShell 5.1 (`powershell.exe`, always present) or [PowerShell 7+](https://github.com/PowerShell/PowerShell/releases) (`pwsh.exe`). The daemon itself runs under `powershell.exe` by default (guaranteed present); the shell **inside each session** defaults to `pwsh` and automatically falls back to `powershell.exe` if PowerShell 7 isn't installed.

## Install

```powershell
cd path\to\WinTerminalMCP
npm install
npm run build
```

Optionally copy `config.example.json` to `config.json` and adjust (default shell, safety patterns, output limits — see comments inside). `config.json` is gitignored so your local tweaks never get committed.

## Configure Claude Desktop

Add to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "winterminal": {
      "command": "node",
      "args": ["C:\\path\\to\\WinTerminalMCP\\dist\\index.js"],
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

Keep `dist/` and `helper/` together — the built `dist/index.js` locates `helper/daemon.ps1` relative to itself, so don't copy `index.js` out on its own.

## Tools

| Tool | Purpose |
|---|---|
| `list_terminal_sessions` | List known sessions and whether their process is still alive |
| `open_terminal_session` | Start a new named session (shell, starting directory) |
| `write_to_terminal` | Type a command/text into a session, then Enter |
| `read_terminal_output` | Read a session's captured output transcript, optionally waiting for output to go idle |
| `send_control_character` | Send a real Ctrl+`<key>` control byte to a session |
| `close_terminal_session` | Terminate a session's shell process |
| `debug_inspect_sessions` | Dump the daemon's internal session state, for troubleshooting |

You don't have to call `open_terminal_session` first — writing to the session named `default` (the default) creates it automatically with the configured default shell. Use explicit names (`open_terminal_session` with `name: "build"`, `name: "git"`, ...) when you want more than one terminal going at once.

`read_terminal_output` returns the session's captured transcript so far — it does not block by default. Pass `waitForIdleMs` (and optionally `timeoutMs`) to poll until the output stops changing, as a rough "the command has probably finished" signal.

## Safety

- **Dangerous-command screening**: `write_to_terminal` checks the command text against `dangerousPatterns` in `config.json` (things like `Remove-Item -Recurse`, `Format-Volume`, `shutdown`, registry deletes, a fork bomb pattern, ...). A match is blocked with an explanation; resend with `confirm: true` to proceed anyway. Edit the pattern list to taste.
- **`readOnlyMode`**: set `true` in `config.json` to disable `write_to_terminal` entirely (reading and Ctrl+C still work).
- **Scoped interrupts**: Ctrl+`<key>` is a control byte written directly into one session's own input pipe — it cannot affect any other process, window, or session. See "Why this exists" above.
- **Audit log**: every write/interrupt/open/close is appended to `logs/commands.log` (plain JSON lines, one per action, rotated at 5MB) so you can always see exactly what was typed into your terminal and when. Delete the file any time; it just gets recreated.
- **No silent background execution**: the daemon only starts a shell process or writes to an existing session in direct response to a tool call you can see in Claude's transcript.

## Known limitations

- **Not a full terminal screen emulation.** `read_terminal_output` strips VT/ANSI escape codes and collapses carriage-return line-rewrites (progress bars, spinners) to their final state, but it does not track cursor position or repaint state. A full-screen app (vim, htop) that redraws the same screen region repeatedly will show up as a scrolling log of each repaint, not one clean frame.
- **`read_terminal_output` is a growing transcript**, capped at 4MB of captured output per session (oldest bytes dropped first) — not an unlimited history, and not scoped to "what's currently visible" the way a real terminal window is.
- **No visible window.** Sessions run headless via ConPTY — there is nothing to look at on screen. If you want to literally watch commands run in a visible Windows Terminal window, this project intentionally does not do that (an earlier version of this project drove the real `wt.exe` GUI via UI Automation and simulated keystrokes; it was replaced because keystroke injection turned out to be unreliable — see git history for that approach if you need it as a reference).

## Development

```powershell
npm run dev     # tsc -w
```

Parse-check the PowerShell files without running them (useful since the ConPTY/P-Invoke calls only work on Windows):

```powershell
pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("helper/daemon.ps1", [ref]$null, [ref]$null)'
```

## License

MIT — see `LICENSE`.
