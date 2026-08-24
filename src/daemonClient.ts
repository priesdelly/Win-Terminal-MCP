import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { DAEMON_SCRIPT_PATH } from './config.js';
import type { DaemonResponse } from './types.js';

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * Owns the single long-lived PowerShell process ("the daemon") that does all
 * of the actual Windows Terminal UI Automation work. Talks to it with
 * newline-delimited JSON over stdio. One daemon per MCP server process.
 */
export class DaemonClient {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private readyPromise: Promise<void> | null = null;
  private daemonHostExe: string;
  private startupErrorLines: string[] = [];

  constructor(daemonHostExe: string) {
    this.daemonHostExe = daemonHostExe;
  }

  /** Spawns the daemon if it is not already running/starting, and waits until it responds to ping. */
  async ensureReady(): Promise<void> {
    if (this.readyPromise) return this.readyPromise;

    this.readyPromise = (async () => {
      const proc = spawn(
        this.daemonHostExe,
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', DAEMON_SCRIPT_PATH],
        { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true },
      );
      this.proc = proc;

      const rl = createInterface({ input: proc.stdout });
      rl.on('line', (line) => this.handleLine(line));

      proc.stderr.setEncoding('utf-8');
      proc.stderr.on('data', (chunk: string) => {
        for (const line of chunk.split(/\r?\n/)) {
          if (!line) continue;
          this.startupErrorLines.push(line);
          if (this.startupErrorLines.length > 50) this.startupErrorLines.shift();
          console.error(`[daemon] ${line}`);
        }
      });

      proc.on('exit', (code, signal) => {
        console.error(`[daemon] exited (code=${code}, signal=${signal})`);
        for (const [, p] of this.pending) {
          clearTimeout(p.timer);
          p.reject(new Error(`Daemon process exited (code=${code}) before responding.`));
        }
        this.pending.clear();
        this.proc = null;
        this.readyPromise = null;
      });

      let spawnError: Error | null = null;
      proc.on('error', (err) => {
        spawnError = err;
        console.error(`[daemon] failed to start (${this.daemonHostExe}): ${err.message}`);
      });

      try {
        await this.call('ping', {}, 15000);
      } catch (err) {
        if (spawnError) {
          throw new Error(
            `Could not start the PowerShell host '${this.daemonHostExe}' (${(spawnError as Error).message}). ` +
              `Is PowerShell installed and on PATH? This server only works on Windows.`,
          );
        }
        const extra = this.startupErrorLines.length
          ? `\nDaemon stderr:\n${this.startupErrorLines.join('\n')}`
          : '';
        throw new Error(
          `Windows Terminal MCP daemon did not respond to ping (host: ${this.daemonHostExe}). ` +
            `This process only works on Windows.${extra}\n${(err as Error).message}`,
        );
      }
    })();

    return this.readyPromise;
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;
    let msg: DaemonResponse;
    try {
      msg = JSON.parse(line);
    } catch {
      console.error(`[daemon] non-JSON line from daemon stdout: ${line}`);
      return;
    }
    const id = typeof msg.id === 'number' ? msg.id : null;
    if (id === null) {
      if (!msg.ok) console.error(`[daemon] startup error: ${msg.error}`);
      return;
    }
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    clearTimeout(pending.timer);
    if (msg.ok) {
      pending.resolve(msg.result);
    } else {
      pending.reject(new Error(msg.error ?? 'Unknown daemon error'));
    }
  }

  /** Sends one request and waits for its matching response, with a timeout. */
  async call<T = unknown>(action: string, params: Record<string, unknown>, timeoutMs = 20000): Promise<T> {
    if (!this.proc || !this.proc.stdin.writable) {
      if (action !== 'ping') {
        await this.ensureReady();
      } else if (!this.proc) {
        throw new Error('Daemon process is not running.');
      }
    }
    const id = this.nextId++;
    const payload = JSON.stringify({ id, action, params }) + '\n';

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out after ${timeoutMs}ms waiting for daemon response to '${action}'.`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      this.proc!.stdin.write(payload, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }

  shutdown(): void {
    if (this.proc) {
      try {
        this.proc.stdin.end();
      } catch {
        /* ignore */
      }
      this.proc.kill();
      this.proc = null;
    }
  }
}
