export interface ShellDefinition {
  exe: string;
  args: string[];
}

export interface AppConfig {
  defaultShell: string;
  shells: Record<string, ShellDefinition>;
  readOnlyMode: boolean;
  requireConfirmForDangerousCommands: boolean;
  dangerousPatterns: string[];
  maxCommandLength: number;
  maxOutputChars: number;
  logCommands: boolean;
  uia: {
    windowClassName: string;
    windowCreateTimeoutMs: number;
    focusSettleMs: number;
  };
  daemonHostExe: string;
}

export interface SessionInfo {
  [key: string]: unknown;
  name: string;
  marker: string;
  shell: string;
  cwd?: string;
  hwnd: number;
  createdAt: string;
}

export interface SessionSummary {
  [key: string]: unknown;
  name: string;
  shell: string;
  cwd?: string;
  createdAt: string;
  alive: boolean;
}

/** One JSON-line request sent to the PowerShell daemon. */
export interface DaemonRequest {
  id: number;
  action: string;
  params?: Record<string, unknown>;
}

/** One JSON-line response received from the PowerShell daemon. */
export interface DaemonResponse<T = unknown> {
  id: number | string | null;
  ok: boolean;
  result?: T;
  error?: string;
}
