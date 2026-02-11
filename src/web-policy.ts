import fs from 'fs';
import net from 'net';
import path from 'path';
import pino from 'pino';

import {
  GROUPS_DIR,
  WEB_FETCH_MAX_BYTES,
  WEB_FETCH_TIMEOUT_MS,
  WEB_POLICY_GLOBAL_PATH
} from './config.js';
import {
  EffectiveWebPolicy,
  WebPolicyDefaults,
  WebPolicyGlobal,
  WebPolicyOverlay
} from './types.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

const HARD_DENY_RULES = [
  'localhost',
  '127.0.0.1',
  '::1',
  '0.0.0.0',
  '169.254.169.254',
  '*.local'
];

const DEFAULT_POLICY_DEFAULTS: WebPolicyDefaults = {
  timeoutMs: WEB_FETCH_TIMEOUT_MS,
  maxBytes: WEB_FETCH_MAX_BYTES
};

const DEFAULT_GLOBAL_POLICY: WebPolicyGlobal = {
  version: 1,
  allow: [
    'github.com',
    'docs.github.com',
    'developer.apple.com',
    'www.google.com',
    'duckduckgo.com',
    'api.duckduckgo.com'
  ],
  deny: ['localhost', '*.local', '169.254.169.254'],
  defaults: DEFAULT_POLICY_DEFAULTS
};

let warnedMissingGlobalPolicy = false;
let warnedInvalidGlobalPolicy = false;
const warnedInvalidOverlayPolicies = new Set<string>();

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function unique(items: string[]): string[] {
  return [...new Set(items)];
}

function sanitizePositiveInt(value: unknown, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  const rounded = Math.floor(value);
  return rounded > 0 ? rounded : fallback;
}

export function normalizeDomainRule(value: string): string | null {
  let raw = value.trim().toLowerCase();
  if (!raw) return null;

  if (raw.includes('://')) {
    try {
      raw = new URL(raw).hostname.toLowerCase();
    } catch {
      return null;
    }
  }

  raw = raw.replace(/^\.+/, '').replace(/\.+$/, '');
  if (!raw) return null;

  if (raw.startsWith('*.')) {
    const base = raw.slice(2).replace(/^\.+/, '').replace(/\.+$/, '');
    if (!base) return null;
    return `*.${base}`;
  }

  return raw;
}

function normalizeRuleList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const normalized = value
    .map((entry) => (typeof entry === 'string' ? normalizeDomainRule(entry) : null))
    .filter((entry): entry is string => entry !== null);
  return unique(normalized);
}

function parseGlobalPolicy(value: unknown): WebPolicyGlobal | null {
  if (!isObject(value)) return null;
  if (typeof value.version !== 'number') return null;
  const defaults = isObject(value.defaults) ? value.defaults : {};

  return {
    version: value.version,
    allow: normalizeRuleList(value.allow),
    deny: normalizeRuleList(value.deny),
    defaults: {
      timeoutMs: sanitizePositiveInt(defaults.timeoutMs, DEFAULT_POLICY_DEFAULTS.timeoutMs),
      maxBytes: sanitizePositiveInt(defaults.maxBytes, DEFAULT_POLICY_DEFAULTS.maxBytes)
    }
  };
}

function parseOverlayPolicy(value: unknown): WebPolicyOverlay | null {
  if (!isObject(value)) return null;
  if (typeof value.version !== 'number') return null;
  return {
    version: value.version,
    allow: normalizeRuleList(value.allow),
    deny: normalizeRuleList(value.deny)
  };
}

export function resolveGroupOverlayPath(groupFolder: string): string {
  if (!groupFolder || groupFolder.includes('\0')) {
    throw new Error('Invalid group folder for web policy lookup');
  }

  const overlayPath = path.resolve(
    GROUPS_DIR,
    groupFolder,
    '.nanoclaw',
    'web-policy.overlay.json'
  );
  const relative = path.relative(GROUPS_DIR, overlayPath);

  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`Group folder escapes configured groups root: "${groupFolder}"`);
  }

  return overlayPath;
}

export function loadGlobalWebPolicy(): WebPolicyGlobal {
  if (!fs.existsSync(WEB_POLICY_GLOBAL_PATH)) {
    if (!warnedMissingGlobalPolicy) {
      warnedMissingGlobalPolicy = true;
      logger.warn(
        { path: WEB_POLICY_GLOBAL_PATH },
        'Web policy global file not found; using built-in defaults'
      );
    }
    return DEFAULT_GLOBAL_POLICY;
  }

  try {
    const raw = fs.readFileSync(WEB_POLICY_GLOBAL_PATH, 'utf8');
    const parsed = parseGlobalPolicy(JSON.parse(raw));
    if (!parsed) {
      throw new Error('Invalid global web policy JSON schema');
    }
    return parsed;
  } catch (error) {
    if (!warnedInvalidGlobalPolicy) {
      warnedInvalidGlobalPolicy = true;
      logger.warn(
        {
          path: WEB_POLICY_GLOBAL_PATH,
          error: error instanceof Error ? error.message : String(error)
        },
        'Failed to parse global web policy; using built-in defaults'
      );
    }
    return DEFAULT_GLOBAL_POLICY;
  }
}

export function loadGroupWebPolicyOverlay(groupFolder: string): WebPolicyOverlay {
  const overlayPath = resolveGroupOverlayPath(groupFolder);
  if (!fs.existsSync(overlayPath)) {
    return { version: 1, allow: [], deny: [] };
  }

  try {
    const raw = fs.readFileSync(overlayPath, 'utf8');
    const parsed = parseOverlayPolicy(JSON.parse(raw));
    if (!parsed) {
      throw new Error('Invalid group overlay web policy schema');
    }
    return parsed;
  } catch (error) {
    if (!warnedInvalidOverlayPolicies.has(overlayPath)) {
      warnedInvalidOverlayPolicies.add(overlayPath);
      logger.warn(
        {
          path: overlayPath,
          groupFolder,
          error: error instanceof Error ? error.message : String(error)
        },
        'Failed to parse group web policy overlay; using empty overlay'
      );
    }
    return { version: 1, allow: [], deny: [] };
  }
}

export function domainMatchesRule(host: string, rule: string): boolean {
  const normalizedHost = host.trim().toLowerCase();
  const normalizedRule = rule.trim().toLowerCase();

  if (normalizedRule.startsWith('*.')) {
    const base = normalizedRule.slice(2);
    return normalizedHost === base || normalizedHost.endsWith(`.${base}`);
  }

  if (net.isIP(normalizedHost)) {
    return normalizedHost === normalizedRule;
  }

  return normalizedHost === normalizedRule || normalizedHost.endsWith(`.${normalizedRule}`);
}

function isPrivateIPv4(host: string): boolean {
  const parts = host.split('.').map((part) => parseInt(part, 10));
  if (parts.length !== 4 || parts.some((part) => Number.isNaN(part))) return false;

  const [a, b] = parts;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
}

function isLocalIpv6(host: string): boolean {
  const normalized = host.toLowerCase();
  return (
    normalized === '::1' ||
    normalized.startsWith('fe80:') ||
    normalized.startsWith('fc') ||
    normalized.startsWith('fd')
  );
}

function isHardDeniedHost(host: string): string | null {
  const normalized = host.trim().toLowerCase();

  if (net.isIP(normalized) === 4 && isPrivateIPv4(normalized)) {
    return normalized;
  }
  if (net.isIP(normalized) === 6 && isLocalIpv6(normalized)) {
    return normalized;
  }

  for (const rule of HARD_DENY_RULES) {
    if (domainMatchesRule(normalized, rule)) {
      return rule;
    }
  }
  return null;
}

export function getEffectiveWebPolicy(groupFolder: string): EffectiveWebPolicy {
  const globalPolicy = loadGlobalWebPolicy();
  const overlay = loadGroupWebPolicyOverlay(groupFolder);

  return {
    allow: unique([...globalPolicy.allow, ...overlay.allow]),
    deny: unique([...globalPolicy.deny, ...overlay.deny, ...HARD_DENY_RULES]),
    defaults: {
      timeoutMs: sanitizePositiveInt(globalPolicy.defaults.timeoutMs, DEFAULT_POLICY_DEFAULTS.timeoutMs),
      maxBytes: sanitizePositiveInt(globalPolicy.defaults.maxBytes, DEFAULT_POLICY_DEFAULTS.maxBytes)
    }
  };
}

export function assertUrlAllowedByPolicy(
  rawUrl: string,
  groupFolder: string
): { url: URL; policy: EffectiveWebPolicy } {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error(`Invalid URL: "${rawUrl}"`);
  }

  const scheme = url.protocol.toLowerCase();
  if (scheme !== 'http:' && scheme !== 'https:') {
    throw new Error(`Unsupported URL scheme "${url.protocol}". Only http/https are allowed.`);
  }

  const host = url.hostname.toLowerCase();
  const hardDenied = isHardDeniedHost(host);
  if (hardDenied) {
    throw new Error(`Blocked host "${host}" by hard deny rule "${hardDenied}"`);
  }

  const policy = getEffectiveWebPolicy(groupFolder);
  if (policy.deny.some((rule) => domainMatchesRule(host, rule))) {
    throw new Error(`Host "${host}" is denied by policy`);
  }

  if (policy.allow.length === 0) {
    throw new Error('Web policy allowlist is empty. Add a domain via web_policy_add_domain first.');
  }

  if (!policy.allow.some((rule) => domainMatchesRule(host, rule))) {
    throw new Error(`Host "${host}" is not in the effective allowlist for group "${groupFolder}"`);
  }

  return { url, policy };
}

export function getWebPolicySnapshot(groupFolder: string): {
  global: WebPolicyGlobal;
  overlay: WebPolicyOverlay;
  effective: EffectiveWebPolicy;
  overlayPath: string;
} {
  const global = loadGlobalWebPolicy();
  const overlay = loadGroupWebPolicyOverlay(groupFolder);
  const effective = getEffectiveWebPolicy(groupFolder);
  return {
    global,
    overlay,
    effective,
    overlayPath: resolveGroupOverlayPath(groupFolder)
  };
}
