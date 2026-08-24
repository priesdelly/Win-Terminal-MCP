import type { AppConfig } from './types.js';

export const SERVER_NAME = 'winterminal-mcp-server';
export const SERVER_VERSION = '0.1.0';

export const DEFAULT_SESSION_NAME = 'default';

export const DEFAULT_CONFIG: AppConfig = {
  defaultShell: 'pwsh',
  shells: {
    pwsh: { exe: 'pwsh.exe', args: ['-NoLogo', '-NoExit'] },
    powershell: { exe: 'powershell.exe', args: ['-NoLogo', '-NoExit'] },
    cmd: { exe: 'cmd.exe', args: [] },
  },
  readOnlyMode: false,
  requireConfirmForDangerousCommands: true,
  dangerousPatterns: [
    'Remove-Item\\s+.*-Recurse',
    '\\b(rm|ri|del|erase)\\b.*-Recurse',
    '-Recurse.*\\b(Remove-Item|rm|ri|del|erase)\\b',
    '\\brd\\s+/s\\b',
    '\\brmdir\\s+/s\\b',
    '\\bdel\\s+/[fsq]',
    'Format-Volume',
    '\\bformat\\s+[a-zA-Z]:',
    'diskpart',
    '\\bStop-Computer\\b',
    '\\bRestart-Computer\\b',
    '\\bshutdown\\b',
    'reg\\s+delete',
    'Remove-Item\\s+.*HKLM',
    '\\bvssadmin\\s+delete\\b',
    '\\bcipher\\s+/w\\b',
    'New-ItemProperty.*-Path\\s+.*Run\\b',
    ':\\(\\)\\{.*\\|.*&.*\\};:',
  ],
  maxCommandLength: 4000,
  maxOutputChars: 25000,
  logCommands: true,
  daemonHostExe: 'powershell.exe',
};
