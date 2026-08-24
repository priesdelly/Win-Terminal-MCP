#!/usr/bin/env node
/**
 * winterminal-mcp-server
 *
 * An MCP server that drives a real, persistent shell process (cmd.exe/pwsh.exe/
 * powershell.exe) through the Windows Pseudo Console API (ConPTY): it writes
 * bytes to the shell's input exactly like a terminal would, reads its output
 * back, and can send a real Ctrl+<key> control byte straight into that one
 * session's own input pipe.
 *
 * This is a clean-room implementation. It was written after reviewing (but
 * copying no code from) https://github.com/capecoma/winterm-mcp, to fix two
 * things about that project: it spawned a brand-new, non-persistent shell
 * process for every single command (so `cd` never stuck between calls), and
 * its "send_control_character" for Ctrl+C actually ran
 * `taskkill /im node.exe /f`, which kills every node.exe process on the
 * whole machine, not just the one command it meant to interrupt.
 *
 * Here, each session is one real, persistent child process attached to its
 * own pseudo console, and Ctrl+<key> is the literal control byte written into
 * that one session's own input pipe - it physically cannot reach any other
 * process, since there is no keyboard/focus involved at all.
 */

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { DaemonClient } from './daemonClient.js';
import { loadConfig } from './config.js';
import { checkCommand } from './safety.js';
import { auditLog } from './logger.js';
import { SERVER_NAME, SERVER_VERSION, DEFAULT_SESSION_NAME } from './constants.js';
import type { SessionInfo, SessionSummary } from './types.js';

const config = loadConfig();
const daemon = new DaemonClient(config.daemonHostExe);

/**
 * Text sent to a session with pressEnter:false sits at the shell's prompt,
 * unexecuted, until a later call presses Enter. checkCommand() only ever sees
 * one call's text, so splitting a dangerous command across two calls (each
 * half individually harmless-looking) would defeat it. This tracks each
 * session's not-yet-submitted line so every check runs against the full
 * accumulated line, not just the latest fragment. Cleared whenever the line
 * is actually submitted (pressEnter:true) or the shell's current line is
 * otherwise reset (Ctrl+<key>, session open/close).
 */
const pendingLine = new Map<string, string>();

function textResult(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function truncate(text: string): { text: string; truncated: boolean } {
  if (text.length <= config.maxOutputChars) return { text, truncated: false };
  return {
    text: text.slice(text.length - config.maxOutputChars),
    truncated: true,
  };
}

async function sessionExistsAndAlive(name: string): Promise<boolean> {
  const sessions = await daemon.call<SessionSummary[]>('list_sessions', {});
  return sessions.some((s) => s.name === name && s.alive);
}

function resolveShellExe(shellName: string): { exe: string; args: string[] } {
  const shell = config.shells[shellName];
  if (!shell) {
    const known = Object.keys(config.shells).join(', ');
    throw new Error(`Unknown shell '${shellName}'. Configured shells: ${known}.`);
  }
  return { exe: shell.exe, args: shell.args };
}

/**
 * Resolves a shell name to exe/args, falling back from pwsh -> powershell if
 * pwsh.exe isn't actually installed. Shared by open_terminal_session and the
 * auto-create-"default"-session path in write_to_terminal, so both behave
 * identically instead of one silently skipping the fallback.
 */
async function resolveShellWithFallback(shellName: string): Promise<{ exe: string; args: string[]; warning: string }> {
  let { exe, args } = resolveShellExe(shellName);
  let warning = '';
  if (shellName === 'pwsh' && !(await checkExeOnPath(exe))) {
    const fallback = resolveShellExe('powershell');
    exe = fallback.exe;
    args = fallback.args;
    warning =
      'Note: pwsh.exe (PowerShell 7) was not found on PATH, so this session was started with the built-in powershell.exe (5.1) instead. Install PowerShell 7 to use pwsh.\n\n';
  }
  return { exe, args, warning };
}

const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

// ---------------------------------------------------------------------------
// list_terminal_sessions
// ---------------------------------------------------------------------------
server.registerTool(
  'list_terminal_sessions',
  {
    title: 'List Terminal Sessions',
    description: `Lists every session this server currently knows about, each backed by a real, persistent shell process attached to its own pseudo console.

Returns for each session: name, shell (pwsh/powershell/cmd), starting directory, creation time, and whether the process is still alive (false if it exited or was killed since it was opened).

Use this before write_to_terminal/read_terminal_output when you're not sure which named sessions already exist, or to check whether a session that exited needs to be reopened.`,
    inputSchema: {},
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async () => {
    const sessions = await daemon.call<SessionSummary[]>('list_sessions', {});
    if (sessions.length === 0) {
      return textResult('No terminal sessions are open yet. Call open_terminal_session, or just call write_to_terminal and a "default" session will be created automatically.');
    }
    const lines = sessions.map(
      (s) => `- ${s.name} (${s.shell}${s.cwd ? `, cwd: ${s.cwd}` : ''}) - ${s.alive ? 'open' : 'CLOSED (process exited)'}`,
    );
    return { ...textResult(lines.join('\n')), structuredContent: { sessions } };
  },
);

// ---------------------------------------------------------------------------
// open_terminal_session
// ---------------------------------------------------------------------------
const OpenSessionSchema = z
  .object({
    name: z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/).default(DEFAULT_SESSION_NAME).describe('Unique name for this session, e.g. "build" or "git". Defaults to "default".'),
    shell: z
      .enum(['pwsh', 'powershell', 'cmd'])
      .default('pwsh')
      .describe('Which shell to start. "pwsh" is PowerShell 7+, "powershell" is the Windows-builtin 5.1, "cmd" is classic cmd.exe.'),
    cwd: z.string().optional().describe('Starting directory for the session, e.g. "C:\\\\src\\\\myproject". Defaults to the user\'s home/profile directory.'),
  })
  .strict();

server.registerTool(
  'open_terminal_session',
  {
    title: 'Open Terminal Session',
    description: `Starts a new, persistent shell process attached to its own pseudo console, and registers it under a name you choose.

Args:
  - name (string): unique session name, defaults to "default"
  - shell ('pwsh' | 'powershell' | 'cmd'): defaults to 'pwsh'. Falls back to 'powershell' automatically (with a warning in the result) if pwsh.exe is not installed.
  - cwd (string, optional): starting directory

You do not need to call this before write_to_terminal - writing to the "default" session name auto-creates it. Use this tool explicitly when you want a second, independently named session (e.g. run a dev server in "server" while running git commands in "git"), or want to pick the shell/starting directory yourself.

Errors if a session with that name is already open - close it first or pick a different name.`,
    inputSchema: OpenSessionSchema.shape,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  async (params: z.infer<typeof OpenSessionSchema>) => {
    const { exe, args, warning } = await resolveShellWithFallback(params.shell);

    const info = await daemon.call<SessionInfo>('open_session', {
      name: params.name,
      shellExe: exe,
      shellArgs: args,
      cwd: params.cwd,
    });
    pendingLine.delete(params.name);
    auditLog(
      { ts: new Date().toISOString(), session: params.name, action: 'open_terminal_session', detail: `${exe} ${args.join(' ')}` },
      config.logCommands,
    );
    return { ...textResult(`${warning}Opened session "${params.name}" (${exe}), pid ${info.pid}.`), structuredContent: info };
  },
);

async function checkExeOnPath(exe: string): Promise<boolean> {
  try {
    const result = await daemon.call<{ exe: string; found: boolean }>('check_exe', { exe });
    return result.found;
  } catch {
    // If the daemon can't even answer this, let open_session surface the real error.
    return true;
  }
}

// ---------------------------------------------------------------------------
// write_to_terminal
// ---------------------------------------------------------------------------
const WriteSchema = z
  .object({
    session: z.string().min(1).max(64).default(DEFAULT_SESSION_NAME).describe('Session name to write to. Defaults to "default", which is auto-created on first use.'),
    command: z.string().min(0).describe('The text/command to type into the terminal, e.g. "git status". Sent exactly as given, then Enter (unless pressEnter is false).'),
    pressEnter: z.boolean().default(true).describe('Whether to press Enter after typing. Set false to type partial input (e.g. answering an interactive prompt character by character).'),
    confirm: z.boolean().default(false).describe('Set true to bypass the dangerous-command safety check after you have deliberately reviewed the command.'),
  })
  .strict();

server.registerTool(
  'write_to_terminal',
  {
    title: 'Write To Terminal',
    description: `Writes a command or text into a session's shell input, exactly as if a person typed it, then presses Enter (by default).

Args:
  - session (string): which session to write to (default "default"; auto-created if it doesn't exist yet, using the default shell)
  - command (string): text to type
  - pressEnter (boolean): press Enter afterward (default true)
  - confirm (boolean): must be true to run a command matched by the dangerous-command safety filter (see config.json's dangerousPatterns)

Returns immediately after the keystrokes are sent - it does NOT wait for the command to finish. Use read_terminal_output afterward (optionally with waitForIdleMs) to see the result.

Errors:
  - "matches a pattern flagged as potentially destructive" -> resend with confirm: true if you really mean it
  - "readOnlyMode" -> this server instance has writes disabled in config.json
  - "No open session named ..." -> only for non-default session names; call open_terminal_session or list_terminal_sessions first`,
    inputSchema: WriteSchema.shape,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  },
  async (params: z.infer<typeof WriteSchema>) => {
    // Check against the full accumulated line (any earlier pressEnter:false
    // fragments plus this one), not just this call's text - see pendingLine.
    const hadPendingFragment = pendingLine.has(params.session);
    const accumulated = (pendingLine.get(params.session) ?? '') + params.command;
    const check = checkCommand(accumulated, params.confirm, config);
    if (!check.allowed) {
      // An earlier pressEnter:false fragment (already sent to the real prompt,
      // since it looked safe alone) is what makes accumulated dangerous here.
      // That fragment is still sitting unexecuted at the shell's prompt, and
      // there is no reliable way from here to clear it: Ctrl+C only delivers
      // conhost's CTRL_C_EVENT signal (which does nothing to an idle prompt),
      // not the distinct "Ctrl+C as a keypress" PSReadLine needs to cancel an
      // in-progress edit, so it does not reliably clear the line (confirmed on
      // this machine) - and on top of that, sending it measurably injects a
      // stray character into the shell's own redraw output. Writing anything
      // more would land on the same unexecuted line. The only reliable way to
      // get this session back to a clean prompt is to close and reopen it.
      let stuckWarning = '';
      if (hadPendingFragment) {
        stuckWarning =
          ' An earlier unsent fragment is still sitting at this session\'s prompt, unexecuted, and there is no reliable ' +
          'way to clear just that line - call close_terminal_session and open_terminal_session to get a fresh prompt ' +
          'before writing anything else to this session.';
        pendingLine.delete(params.session);
      }
      auditLog(
        {
          ts: new Date().toISOString(),
          session: params.session,
          action: 'write_to_terminal',
          detail: params.command,
          blocked: true,
          blockReason: check.reason,
        },
        config.logCommands,
      );
      return textResult(`Blocked: ${check.reason}${stuckWarning}`);
    }
    if (params.pressEnter) {
      pendingLine.delete(params.session);
    } else {
      pendingLine.set(params.session, accumulated);
    }

    let autoCreateWarning = '';
    if (params.session === DEFAULT_SESSION_NAME && !(await sessionExistsAndAlive(DEFAULT_SESSION_NAME))) {
      const { exe, args, warning } = await resolveShellWithFallback(config.defaultShell);
      autoCreateWarning = warning;
      try {
        await daemon.call<SessionInfo>('open_session', { name: DEFAULT_SESSION_NAME, shellExe: exe, shellArgs: args });
        auditLog(
          { ts: new Date().toISOString(), session: DEFAULT_SESSION_NAME, action: 'open_terminal_session', detail: `${exe} ${args.join(' ')}` },
          config.logCommands,
        );
      } catch (err) {
        // Another concurrent write_to_terminal call may have won the race to
        // create the "default" session between our check and this call - that's
        // fine, proceed to write. Any other failure (e.g. the configured shell
        // exe missing) is real.
        if (!/already open/i.test((err as Error).message)) throw err;
      }
    }

    await daemon.call('write_to_terminal', { name: params.session, text: params.command, pressEnter: params.pressEnter });

    auditLog(
      { ts: new Date().toISOString(), session: params.session, action: 'write_to_terminal', detail: params.command },
      config.logCommands,
    );

    return textResult(
      `${autoCreateWarning}Sent to session "${params.session}": ${params.command || '(empty input)'}${params.pressEnter ? '' : ' (no Enter pressed)'}`,
    );
  },
);

// ---------------------------------------------------------------------------
// read_terminal_output
// ---------------------------------------------------------------------------
const ReadSchema = z
  .object({
    session: z.string().min(1).max(64).default(DEFAULT_SESSION_NAME).describe('Session name to read from.'),
    lines: z.number().int().min(0).max(5000).default(0).describe('How many trailing lines of visible output to return. 0 (default) returns everything currently visible/scrolled-into-view.'),
    waitForIdleMs: z.number().int().min(0).max(10000).default(0).describe('If > 0, poll the terminal until its visible text stops changing for this many ms (useful for waiting until a command likely finished), up to timeoutMs.'),
    timeoutMs: z.number().int().min(500).max(60000).default(15000).describe('Max total time to spend polling when waitForIdleMs > 0.'),
  })
  .strict();

server.registerTool(
  'read_terminal_output',
  {
    title: 'Read Terminal Output',
    description: `Reads a session's captured output transcript: everything the shell has printed since the session opened, with terminal escape/color codes stripped and carriage-return line-rewrites (progress bars, spinners) collapsed to their final state.

Args:
  - session (string): which session to read (default "default")
  - lines (number): trailing lines to return, 0 = everything captured so far (default 0)
  - waitForIdleMs / timeoutMs: optionally wait for output to stop changing (a heuristic for "the command probably finished") before returning; without this the call returns immediately with whatever has been captured so far

Returns: { text, truncated, idleReached, timedOut }. Long output is truncated from the start (oldest lines dropped first) to maxOutputChars (see config.json); truncated is true when that happened.

Note: this is a plain-text transcript, not a full terminal screen emulation - a full-screen app (vim, htop) that repaints the same screen region repeatedly will show as a scrolling log of each repaint, not one clean frame.`,
    inputSchema: ReadSchema.shape,
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async (params: z.infer<typeof ReadSchema>) => {
    let text = (await daemon.call<{ text: string }>('read_terminal_output', { name: params.session, lines: params.lines })).text;
    let idleReached = false;
    let timedOut = false;

    if (params.waitForIdleMs > 0) {
      const deadline = Date.now() + params.timeoutMs;
      let lastChange = Date.now();
      let prev = text;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 400));
        const next = (await daemon.call<{ text: string }>('read_terminal_output', { name: params.session, lines: params.lines })).text;
        if (next !== prev) {
          prev = next;
          lastChange = Date.now();
        } else if (Date.now() - lastChange >= params.waitForIdleMs) {
          idleReached = true;
          text = next;
          break;
        }
        text = next;
      }
      if (!idleReached) timedOut = true;
    }

    const { text: finalText, truncated } = truncate(text);
    return {
      ...textResult(finalText || '(no output)'),
      structuredContent: { text: finalText, truncated, idleReached, timedOut },
    };
  },
);

// ---------------------------------------------------------------------------
// send_control_character
// ---------------------------------------------------------------------------
const ControlCharSchema = z
  .object({
    session: z.string().min(1).max(64).default(DEFAULT_SESSION_NAME).describe('Session to send the key to.'),
    key: z.string().min(1).max(6).default('C').describe('Letter for Ctrl+<key> (e.g. "C" for Ctrl+C to interrupt, "Z" for Ctrl+Z / EOF).'),
  })
  .strict();

server.registerTool(
  'send_control_character',
  {
    title: 'Send Control Character',
    description: `Sends a real Ctrl+<key> control byte (e.g. Ctrl+C to interrupt) directly into a session's own shell input.

This writes the literal ASCII control byte straight into this one session's input pipe - it physically cannot reach any other process on the machine, since there is no keyboard/focus involved at all.

Args:
  - session (string): which session (default "default")
  - key (string): "C" (default) or any other letter for Ctrl+<that key>

Ctrl+Break is not supported - there is no ASCII control byte for it over this transport. Use "C" to interrupt a running command.

Reliably interrupts a command that is actually running. It is not a reliable way to cancel text already typed into the prompt but not yet submitted (pressEnter:false) - PowerShell's line editor needs Ctrl+C delivered as its own keypress to cancel an in-progress edit, which this transport does not guarantee. To discard an unsent fragment, close and reopen the session instead.`,
    inputSchema: ControlCharSchema.shape,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  async (params: z.infer<typeof ControlCharSchema>) => {
    await daemon.call('send_control_character', { name: params.session, key: params.key });
    pendingLine.delete(params.session);
    auditLog(
      { ts: new Date().toISOString(), session: params.session, action: 'send_control_character', detail: `Ctrl+${params.key.toUpperCase()}` },
      config.logCommands,
    );
    return textResult(`Sent Ctrl+${params.key.toUpperCase()} to session "${params.session}".`);
  },
);

// ---------------------------------------------------------------------------
// close_terminal_session
// ---------------------------------------------------------------------------
const CloseSchema = z
  .object({
    session: z.string().min(1).max(64).describe('Session name to close.'),
  })
  .strict();

server.registerTool(
  'close_terminal_session',
  {
    title: 'Close Terminal Session',
    description: `Terminates a session's shell process and forgets it.

Args:
  - session (string): session name to close

Errors with "No open session named ..." if it's already gone.`,
    inputSchema: CloseSchema.shape,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  },
  async (params: z.infer<typeof CloseSchema>) => {
    await daemon.call('close_session', { name: params.session });
    pendingLine.delete(params.session);
    auditLog(
      { ts: new Date().toISOString(), session: params.session, action: 'close_terminal_session', detail: '' },
      config.logCommands,
    );
    return textResult(`Closed session "${params.session}".`);
  },
);

// ---------------------------------------------------------------------------
// debug_inspect_sessions
// ---------------------------------------------------------------------------
server.registerTool(
  'debug_inspect_sessions',
  {
    title: 'Debug Inspect Sessions',
    description: `Diagnostic tool: dumps the daemon's internal state for every session it knows about - pid, alive status, and how many characters of output are currently buffered.

Use this when a session seems "stuck" (write/read errors, session not found) to see what the daemon actually has in memory. Not needed for normal use.`,
    inputSchema: {},
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async () => {
    const snapshot = await daemon.call('debug_inspect_sessions', {});
    return { ...textResult(JSON.stringify(snapshot, null, 2)), structuredContent: snapshot as Record<string, unknown> };
  },
);

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
async function main() {
  if (process.platform !== 'win32') {
    console.error(
      'WARNING: this server drives shell processes via the Windows Pseudo Console API (ConPTY) and only functions on Windows. ' +
        `Detected platform: ${process.platform}.`,
    );
  }

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`${SERVER_NAME} v${SERVER_VERSION} running on stdio.`);

  // Warm the daemon in the background so the first real tool call isn't slowed
  // down by PowerShell + UIA assembly startup. Failures here are surfaced to
  // the user lazily on the first actual tool call instead of crashing the server.
  daemon.ensureReady().catch((err) => {
    console.error(`[startup] Daemon warm-up failed (will retry on first tool call): ${(err as Error).message}`);
  });
}

process.on('SIGINT', () => {
  daemon.shutdown();
  process.exit(0);
});
process.on('SIGTERM', () => {
  daemon.shutdown();
  process.exit(0);
});

main().catch((err) => {
  console.error('Fatal error starting server:', err);
  process.exit(1);
});
