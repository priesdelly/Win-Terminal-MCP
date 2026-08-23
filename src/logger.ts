import { appendFileSync, existsSync, mkdirSync, statSync, renameSync } from 'node:fs';
import path from 'node:path';
import { LOG_DIR } from './config.js';

const LOG_FILE = path.join(LOG_DIR, 'commands.log');
const MAX_LOG_BYTES = 5 * 1024 * 1024; // 5MB, then rotate once

export interface AuditEntry {
  ts: string;
  session: string;
  action: 'write_to_terminal' | 'send_control_character' | 'open_terminal_session' | 'close_terminal_session';
  detail: string;
  blocked?: boolean;
  blockReason?: string;
}

/**
 * Appends one line per terminal-affecting action to logs/commands.log.
 * This exists so you can always answer "what did Claude actually type into
 * my terminal, and when" without having to trust anything - it's a plain
 * append-only text file you can open, tail, or delete at any time.
 */
export function auditLog(entry: AuditEntry, enabled: boolean): void {
  if (!enabled) return;
  try {
    if (!existsSync(LOG_DIR)) mkdirSync(LOG_DIR, { recursive: true });
    if (existsSync(LOG_FILE)) {
      const size = statSync(LOG_FILE).size;
      if (size > MAX_LOG_BYTES) {
        renameSync(LOG_FILE, `${LOG_FILE}.1`);
      }
    }
    appendFileSync(LOG_FILE, JSON.stringify(entry) + '\n', 'utf-8');
  } catch (err) {
    console.error(`[logger] Failed to write audit log: ${(err as Error).message}`);
  }
}
