import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_CONFIG } from './constants.js';
import type { AppConfig } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const PROJECT_ROOT = path.resolve(__dirname, '..');
export const HELPER_DIR = path.join(PROJECT_ROOT, 'helper');
export const DAEMON_SCRIPT_PATH = path.join(HELPER_DIR, 'daemon.ps1');
export const LOG_DIR = path.join(PROJECT_ROOT, 'logs');

function deepMerge<T>(base: T, override: Partial<T>): T {
  const out: any = Array.isArray(base) ? [...(base as any)] : { ...base };
  for (const key of Object.keys(override ?? {})) {
    const overrideVal = (override as any)[key];
    const baseVal = (base as any)[key];
    if (
      overrideVal &&
      typeof overrideVal === 'object' &&
      !Array.isArray(overrideVal) &&
      baseVal &&
      typeof baseVal === 'object' &&
      !Array.isArray(baseVal)
    ) {
      out[key] = deepMerge(baseVal, overrideVal);
    } else {
      out[key] = overrideVal;
    }
  }
  return out as T;
}

/**
 * Loads config.json from the project root if present and merges it over the
 * built-in defaults. config.json is intentionally gitignored so local safety
 * tweaks (e.g. a stricter dangerousPatterns list) never get committed or shared.
 */
export function loadConfig(): AppConfig {
  const userConfigPath = path.join(PROJECT_ROOT, 'config.json');
  if (!existsSync(userConfigPath)) {
    return DEFAULT_CONFIG;
  }
  try {
    const raw = readFileSync(userConfigPath, 'utf-8');
    const parsed = JSON.parse(raw);
    return deepMerge(DEFAULT_CONFIG, parsed);
  } catch (err) {
    console.error(
      `[config] Failed to parse config.json (${(err as Error).message}). Falling back to built-in defaults.`,
    );
    return DEFAULT_CONFIG;
  }
}
