import type { AppConfig } from './types.js';

export interface CommandCheckResult {
  allowed: boolean;
  reason?: string;
  matchedPattern?: string;
}

/**
 * Screens a command before it is ever typed into a real terminal.
 *
 * This is the direct answer to "what if the tool itself does something
 * destructive": every write_to_terminal call passes through here first.
 * It never silently blocks forever - it tells the caller exactly what
 * matched and how to proceed (resend with confirm: true) so a human stays
 * in the loop for anything that looks irreversible.
 */
export function checkCommand(command: string, confirm: boolean, config: AppConfig): CommandCheckResult {
  if (config.readOnlyMode) {
    return {
      allowed: false,
      reason: 'This server is running in readOnlyMode (see config.json). write_to_terminal is disabled.',
    };
  }

  if (command.length > config.maxCommandLength) {
    return {
      allowed: false,
      reason: `Command is ${command.length} characters, which exceeds maxCommandLength (${config.maxCommandLength}). Split it into smaller steps.`,
    };
  }

  if (!config.requireConfirmForDangerousCommands || confirm) {
    return { allowed: true };
  }

  for (const pattern of config.dangerousPatterns) {
    let re: RegExp;
    try {
      re = new RegExp(pattern, 'is');
    } catch {
      continue; // ignore a malformed pattern rather than crash the server
    }
    if (re.test(command)) {
      return {
        allowed: false,
        reason:
          `This command matches a pattern flagged as potentially destructive ("${pattern}"). ` +
          `If you really mean to run it, call write_to_terminal again with confirm: true. ` +
          `You can edit the dangerousPatterns list in config.json.`,
        matchedPattern: pattern,
      };
    }
  }

  return { allowed: true };
}
