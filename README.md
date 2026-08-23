# WinTerminal MCP Server

An MCP server that drives the **real Windows Terminal application** (`wt.exe`) so Claude can open a tab you can see, type commands into it exactly like a person would, read back what's on screen, and send a genuine Ctrl+C — scoped to that one pane only.

## Why this exists instead of using capecoma/winterm-mcp

This project was inspired by [`capecoma/winterm-mcp`](https://github.com/capecoma/winterm-mcp), but contains none of its code — it's a clean-room rewrite, built after reading its source (one file, `src/index.ts`) to understand what it does. Two things in that project are worth knowing about, which is exactly why this one exists:

1. **It never actually controls Windows Terminal.** Despite the name, `write_to_terminal` just runs `child_process.spawn('cmd.exe', ['/c', command])` — a brand-new, throwaway shell process for every single call. `cd` on one call has zero effect on the next, because there is no persistent shell at all, real or otherwise.
2. **Its Ctrl+C is dangerous.** `send_control_character` for the letter `C` runs `taskkill /im node.exe /f` — which kills **every `node.exe` process on the entire machine**, not the specific command it meant to interrupt. On a dev machine that's likely to also kill unrelated tools, other MCP servers, VS Code's extension host, or anything else built on Node.

This server fixes both: it opens and tracks real, named Windows Terminal tabs via UI Automation, and Ctrl+`<key>` is a genuine simulated keystroke sent only to the pane that's focused when it's sent — it physically cannot reach an unrelated process.

## How it works

Two pieces, talking JSON over stdio:

- **`src/` (Node/TypeScript)** — the MCP server itself. Registers the tools, validates input with Zod, screens commands against a configurable "dangerous pattern" list, writes an audit log, and manages a small child process.
- **`helper/` (PowerShell)** — a long-lived background worker (`daemon.ps1` + `WtControl.psm1`) that does the actual Windows-specific work: launching `wt.exe` tabs, finding them again via UI Automation (`System.Windows.Automation`), reading on-screen text through the accessibility Text pattern, and sending keystrokes via `SendKeys` / `keybd_event`.

Each "session" is one `wt.exe` tab, tagged at creation with a unique, invisible title marker (e.g. `MCP::build::a1b2c3d4`) so the daemon can find it again on later calls — even across tab switches — without holding onto fragile in-memory references.

**Nothing runs unless you call a tool.** There's no telemetry, no auto-update, no network access anywhere in this project (check `package.json` — only `@modelcontextprotocol/sdk` and `zod`), no `eval`, no dynamically-fetched code, no obfuscation. Every file is short enough to read end to end in a few minutes.

## Requirements

- Windows 10/11
- [Windows Terminal](https://apps.microsoft.com/detail/9n0dx20hk701) installed and on `PATH` as `wt.exe` (true by default from the Microsoft Store install)
- Node.js 18+
- PowerShell — either the built-in Windows PowerShell 5.1 (`powershell.exe`, always present) or [PowerShell 7+](https://github.com/PowerShell/PowerShell/releases) (`pwsh.exe`). The daemon itself runs under `powershell.exe` by default (guaranteed present); the shell **inside the terminal tabs it opens** defaults to `pwsh` and automatically falls back to `powershell.exe` if PowerShell 7 isn't installed.

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
| `list_terminal_sessions` | List known sessions and whether their tab is still open |
| `open_terminal_session` | Open a new named tab (shell, starting directory, new window or not) |
| `write_to_terminal` | Type a command/text into a session, then Enter |
| `read_terminal_output` | Read what's currently visible in a session, optionally waiting for output to go idle |
| `send_control_character` | Send a real Ctrl+`<key>` (or Ctrl+Break) to a session |
| `close_terminal_session` | Close a session's tab |
| `debug_inspect_windows` | Dump everything UI Automation can see, for troubleshooting |

You don't have to call `open_terminal_session` first — writing to the session named `default` (the default) creates it automatically with the configured default shell. Use explicit names (`open_terminal_session` with `name: "build"`, `name: "git"`, ...) when you want more than one terminal going at once.

`read_terminal_output` returns whatever's currently rendered — it does not block by default. Pass `waitForIdleMs` (and optionally `timeoutMs`) to poll until the visible text stops changing, as a rough "the command has probably finished" signal.

## Safety

- **Dangerous-command screening**: `write_to_terminal` checks the command text against `dangerousPatterns` in `config.json` (things like `Remove-Item -Recurse`, `Format-Volume`, `shutdown`, registry deletes, a fork bomb pattern, ...). A match is blocked with an explanation; resend with `confirm: true` to proceed anyway. Edit the pattern list to taste.
- **`readOnlyMode`**: set `true` in `config.json` to disable `write_to_terminal` entirely (reading and Ctrl+C still work).
- **Scoped interrupts**: Ctrl+`<key>` only ever reaches the focused pane — see "Why this exists" above.
- **Audit log**: every write/interrupt/open/close is appended to `logs/commands.log` (plain JSON lines, one per action, rotated at 5MB) so you can always see exactly what was typed into your terminal and when. Delete the file any time; it just gets recreated.
- **No silent background execution**: the daemon only launches `wt.exe` or types into an existing tab in direct response to a tool call you can see in Claude's transcript.

## Known limitations (UI-Automation-based control is inherently a bit fragile)

Windows Terminal doesn't expose a supported API for "attach to this pane and pipe stdin/stdout to me" — `wt.exe`'s CLI only launches/arranges tabs and returns immediately. Reading and writing here work by automating the real GUI (UI Automation for reading text, simulated keystrokes for writing), the same mechanism screen readers use. That means:

- **Bringing a pane to the foreground is required** to type into it or read a fresh Ctrl+C signal reliably — the target window will briefly come to the front. If you're actively using another window, you'll see focus move.
- **`read_terminal_output` reflects the visible viewport/scrollback**, not an unlimited log of everything ever printed.
- **Split panes within one tab**: the content-detection heuristic picks the largest text-capable element, which is usually right for a single-pane tab but is only a best guess if you've split a tab into multiple panes by hand.
- These heuristics (window class name `CASCADIA_HOSTING_WINDOW_CLASS`, UIA `TabItem`/text-pattern search) are based on Windows Terminal's documented accessibility support, but weren't tested against every WT version/Windows build. If session lookups fail, run `debug_inspect_windows` and compare what it found against what you expect — that's exactly what it's for.

If any of this proves unreliable in practice, the architecture has a clean extension point: `helper/WtControl.psm1`'s functions could be swapped for a `node-pty`-backed session (a real pseudo-console per session, no UI Automation needed) — at the cost of the terminal windows no longer being the actual Windows Terminal app. Not implemented here since real Windows Terminal control was the point.

## Development

```powershell
npm run dev     # tsc -w
```

Parse-check the PowerShell files without running them (useful since the UIA/WinForms calls only work on Windows):

```powershell
pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("helper/daemon.ps1", [ref]$null, [ref]$null)'
```

## License

MIT — see `LICENSE`.
