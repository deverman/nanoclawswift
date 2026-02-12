import dns from 'dns';
import fs from 'fs';
import http, { type IncomingMessage, type RequestOptions, type ServerResponse } from 'http';
import https from 'https';
import { type LookupFunction } from 'net';
import net from 'net';
import path from 'path';
import pino from 'pino';

import {
  GROUPS_DIR,
  WEB_BROKER_PORT,
  WEB_FETCH_MAX_BYTES,
  WEB_FETCH_TIMEOUT_MS,
  WEB_POLICY_GLOBAL_PATH
} from './config.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

type RelayProvider = 'openai' | 'kimi' | 'anthropic';

interface WebPolicyDefaults {
  timeoutMs: number;
  maxBytes: number;
}

interface WebPolicyGlobal {
  version: number;
  allow: string[];
  deny: string[];
  defaults: WebPolicyDefaults;
}

interface WebPolicyOverlay {
  version: number;
  allow: string[];
  deny: string[];
}

interface EffectiveWebPolicy {
  allow: string[];
  deny: string[];
  defaults: WebPolicyDefaults;
}

interface WebFetchRequest {
  groupFolder: string;
  url: string;
  method?: string;
  headers?: Record<string, unknown>;
  timeoutMs?: number;
  maxBytes?: number;
}

interface WebFetchResponse {
  ok: true;
  url: string;
  status: number;
  statusText: string;
  contentType: string;
  content: string;
  contentFormat: 'plain-text' | 'html-extracted';
  extractedFromHTML: boolean;
  bytes: number;
  contentBytes: number;
  truncated: boolean;
  sourceTruncated: boolean;
  contentTruncated: boolean;
  redirects: string[];
}

interface WebSearchRequest {
  groupFolder: string;
  query: string;
  limit?: number;
}

interface WebSearchResult {
  title: string;
  url: string;
  snippet: string;
}

interface WebSearchResponse {
  ok: true;
  query: string;
  results: WebSearchResult[];
}

interface RelayRuntimeInfo {
  bind: string;
  host: string;
  port: number;
  webBrokerURL: string;
}

const RELAY_BIND = process.env.CONTAINER_LLM_RELAY_BIND || '0.0.0.0';
const RELAY_HOST = process.env.CONTAINER_LLM_RELAY_HOST || '192.168.64.1';
const RELAY_PORT = parseInt(
  process.env.CONTAINER_LLM_RELAY_PORT || String(WEB_BROKER_PORT),
  10
);
const RELAY_TIMEOUT_MS = parseInt(
  process.env.CONTAINER_LLM_RELAY_TIMEOUT || '120000',
  10
);

const RELAY_DNS_SERVERS = (process.env.CONTAINER_LLM_RELAY_DNS_SERVERS || '')
  .split(',')
  .map((entry) => entry.trim())
  .filter((entry) => entry.length > 0);

const RELAY_UPSTREAMS: Record<RelayProvider, string> = {
  openai: 'https://api.openai.com',
  kimi: 'https://api.moonshot.ai',
  anthropic: 'https://api.anthropic.com'
};

const HARD_DENY_RULES = [
  'localhost',
  '127.0.0.1',
  '::1',
  '0.0.0.0',
  '169.254.169.254',
  '*.local'
];

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
  defaults: {
    timeoutMs: WEB_FETCH_TIMEOUT_MS,
    maxBytes: WEB_FETCH_MAX_BYTES
  }
};

const MAX_WEB_BODY_BYTES = 256 * 1024;
const MAX_REDIRECTS = 5;
const MAX_SEARCH_RESULTS = 10;
const MAX_RETURN_TEXT_CHARS = parseInt(process.env.WEB_FETCH_MAX_TEXT_CHARS || '40000', 10);
const MAX_HTML_EXTRACT_CHARS = parseInt(process.env.WEB_FETCH_MAX_HTML_CHARS || '20000', 10);

let relayServer: http.Server | null = null;
let relayStartPromise: Promise<RelayRuntimeInfo> | null = null;

let warnedMissingGlobalPolicy = false;
let warnedInvalidGlobalPolicy = false;
const warnedInvalidOverlayPolicies = new Set<string>();

let relayResolver: dns.Resolver | null = null;

function toErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function unique(items: string[]): string[] {
  return [...new Set(items)];
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function clampPositiveInt(raw: unknown, fallback: number): number {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return fallback;
  const rounded = Math.floor(raw);
  return rounded > 0 ? rounded : fallback;
}

function sanitizePositiveInt(raw: unknown, fallback: number): number {
  return clampPositiveInt(raw, fallback);
}

function normalizeDomainRule(rawValue: string): string | null {
  let raw = rawValue.trim().toLowerCase();
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

function normalizeRuleList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const values = raw
    .map((entry) => (typeof entry === 'string' ? normalizeDomainRule(entry) : null))
    .filter((entry): entry is string => entry !== null);
  return unique(values);
}

function parseGlobalPolicy(raw: unknown): WebPolicyGlobal | null {
  if (!isObject(raw)) return null;
  if (typeof raw.version !== 'number') return null;
  const defaults = isObject(raw.defaults) ? raw.defaults : {};
  return {
    version: raw.version,
    allow: normalizeRuleList(raw.allow),
    deny: normalizeRuleList(raw.deny),
    defaults: {
      timeoutMs: sanitizePositiveInt(defaults.timeoutMs, DEFAULT_GLOBAL_POLICY.defaults.timeoutMs),
      maxBytes: sanitizePositiveInt(defaults.maxBytes, DEFAULT_GLOBAL_POLICY.defaults.maxBytes)
    }
  };
}

function parseOverlayPolicy(raw: unknown): WebPolicyOverlay | null {
  if (!isObject(raw)) return null;
  if (typeof raw.version !== 'number') return null;
  return {
    version: raw.version,
    allow: normalizeRuleList(raw.allow),
    deny: normalizeRuleList(raw.deny)
  };
}

function resolveOverlayPath(groupFolder: string): string {
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

function loadGlobalWebPolicy(): WebPolicyGlobal {
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
    if (!parsed) throw new Error('Invalid web policy global schema');
    return parsed;
  } catch (error) {
    if (!warnedInvalidGlobalPolicy) {
      warnedInvalidGlobalPolicy = true;
      logger.warn(
        {
          path: WEB_POLICY_GLOBAL_PATH,
          error: toErrorMessage(error)
        },
        'Failed to parse global web policy; using built-in defaults'
      );
    }
    return DEFAULT_GLOBAL_POLICY;
  }
}

function loadGroupOverlay(groupFolder: string): WebPolicyOverlay {
  const overlayPath = resolveOverlayPath(groupFolder);
  if (!fs.existsSync(overlayPath)) {
    return { version: 1, allow: [], deny: [] };
  }

  try {
    const raw = fs.readFileSync(overlayPath, 'utf8');
    const parsed = parseOverlayPolicy(JSON.parse(raw));
    if (!parsed) throw new Error('Invalid web policy overlay schema');
    return parsed;
  } catch (error) {
    if (!warnedInvalidOverlayPolicies.has(overlayPath)) {
      warnedInvalidOverlayPolicies.add(overlayPath);
      logger.warn(
        {
          path: overlayPath,
          groupFolder,
          error: toErrorMessage(error)
        },
        'Failed to parse web policy overlay; using empty overlay'
      );
    }
    return { version: 1, allow: [], deny: [] };
  }
}

function domainMatchesRule(host: string, rule: string): boolean {
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
  if (net.isIP(normalized) === 4 && isPrivateIPv4(normalized)) return normalized;
  if (net.isIP(normalized) === 6 && isLocalIpv6(normalized)) return normalized;
  for (const rule of HARD_DENY_RULES) {
    if (domainMatchesRule(normalized, rule)) return rule;
  }
  return null;
}

function getEffectivePolicy(groupFolder: string): EffectiveWebPolicy {
  const global = loadGlobalWebPolicy();
  const overlay = loadGroupOverlay(groupFolder);
  return {
    allow: unique([...global.allow, ...overlay.allow]),
    deny: unique([...global.deny, ...overlay.deny, ...HARD_DENY_RULES]),
    defaults: {
      timeoutMs: sanitizePositiveInt(global.defaults.timeoutMs, DEFAULT_GLOBAL_POLICY.defaults.timeoutMs),
      maxBytes: sanitizePositiveInt(global.defaults.maxBytes, DEFAULT_GLOBAL_POLICY.defaults.maxBytes)
    }
  };
}

function assertUrlAllowedByPolicy(
  rawUrl: string,
  groupFolder: string
): { url: URL; policy: EffectiveWebPolicy } {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error(`Invalid URL: "${rawUrl}"`);
  }

  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`Unsupported URL scheme "${url.protocol}"`);
  }

  const host = url.hostname.toLowerCase();
  const hardDenied = isHardDeniedHost(host);
  if (hardDenied) {
    throw new Error(`Blocked host "${host}" by hard deny rule "${hardDenied}"`);
  }

  const policy = getEffectivePolicy(groupFolder);
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

function getPolicySnapshot(groupFolder: string) {
  const global = loadGlobalWebPolicy();
  const overlay = loadGroupOverlay(groupFolder);
  const effective = getEffectivePolicy(groupFolder);
  return {
    global,
    overlay,
    effective,
    overlayPath: resolveOverlayPath(groupFolder)
  };
}

function writeJson(res: ServerResponse, statusCode: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body).toString()
  });
  res.end(body);
}

async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let total = 0;

  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > MAX_WEB_BODY_BYTES) {
      throw new Error(`Request body too large (${total} bytes)`);
    }
    chunks.push(buffer);
  }

  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function sanitizeMethod(raw: unknown): string {
  if (typeof raw !== 'string' || !raw.trim()) return 'GET';
  const method = raw.trim().toUpperCase();
  const allowed = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);
  return allowed.has(method) ? method : 'GET';
}

function sanitizeHeaders(raw: unknown): Record<string, string> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!key) continue;
    if (typeof value === 'string') out[key] = value;
    else if (typeof value === 'number' || typeof value === 'boolean') out[key] = String(value);
  }
  return out;
}

async function readLimitedText(
  response: Response,
  maxBytes: number
): Promise<{ text: string; bytes: number; truncated: boolean }> {
  if (!response.body) return { text: '', bytes: 0, truncated: false };
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let bytes = 0;
  let truncated = false;

  while (true) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    if (bytes + value.length > maxBytes) {
      const keep = maxBytes - bytes;
      if (keep > 0) {
        chunks.push(Buffer.from(value.subarray(0, keep)));
        bytes += keep;
      }
      truncated = true;
      await reader.cancel();
      break;
    }

    chunks.push(Buffer.from(value));
    bytes += value.length;
  }

  return {
    text: Buffer.concat(chunks).toString('utf8'),
    bytes,
    truncated
  };
}

function decodeCommonHtmlEntities(input: string): string {
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&apos;/gi, "'");
}

function collapseWhitespace(input: string): string {
  return input
    .replace(/\r/g, '\n')
    .replace(/\t/g, ' ')
    .replace(/[ \f\v]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function cleanInlineHtmlText(input: string): string {
  const stripped = input
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return decodeCommonHtmlEntities(stripped);
}

function extractTagTexts(html: string, tag: string, limit: number): string[] {
  const regex = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`, 'gi');
  const out: string[] = [];
  let match: RegExpExecArray | null;
  while ((match = regex.exec(html)) !== null && out.length < limit) {
    const cleaned = cleanInlineHtmlText(match[1] || '');
    if (cleaned) out.push(cleaned);
  }
  return out;
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function extractMetaContent(html: string, metaName: string): string | null {
  const escaped = escapeRegex(metaName);
  const patterns = [
    new RegExp(`<meta\\b[^>]*(?:name|property)=["']${escaped}["'][^>]*content=["']([^"']+)["'][^>]*>`, 'i'),
    new RegExp(`<meta\\b[^>]*content=["']([^"']+)["'][^>]*(?:name|property)=["']${escaped}["'][^>]*>`, 'i')
  ];

  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match?.[1]) {
      const cleaned = decodeCommonHtmlEntities(match[1].trim());
      if (cleaned) return cleaned;
    }
  }
  return null;
}

function isLikelyHTML(contentType: string, url: string): boolean {
  const normalized = contentType.toLowerCase();
  if (normalized.includes('text/html') || normalized.includes('application/xhtml+xml')) {
    return true;
  }

  try {
    const pathname = new URL(url).pathname.toLowerCase();
    return pathname.endsWith('.html') || pathname.endsWith('.htm');
  } catch {
    return false;
  }
}

function extractHTMLContent(rawHTML: string, maxChars: number): { content: string; truncated: boolean } {
  const sanitizedHTML = rawHTML
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/gi, ' ')
    .replace(/<template\b[^>]*>[\s\S]*?<\/template>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ');

  const sections: string[] = [];
  const title = extractTagTexts(sanitizedHTML, 'title', 1)[0];
  if (title) sections.push(`Title: ${title}`);

  const description = extractMetaContent(sanitizedHTML, 'description')
    || extractMetaContent(sanitizedHTML, 'og:description')
    || extractMetaContent(sanitizedHTML, 'twitter:description');
  if (description) sections.push(`Summary: ${description}`);

  const headings = [
    ...extractTagTexts(sanitizedHTML, 'h1', 3),
    ...extractTagTexts(sanitizedHTML, 'h2', 6)
  ].slice(0, 8);
  if (headings.length > 0) {
    sections.push(`Headings:\n${headings.map((h) => `- ${h}`).join('\n')}`);
  }

  const paragraphs = extractTagTexts(sanitizedHTML, 'p', 20)
    .map((text) => text.trim())
    .filter((text) => text.length >= 40)
    .slice(0, 12);
  if (paragraphs.length > 0) {
    sections.push(`Content:\n${paragraphs.map((p) => `- ${p}`).join('\n')}`);
  }

  if (sections.length === 0) {
    const fallback = collapseWhitespace(
      decodeCommonHtmlEntities(
        sanitizedHTML
          .replace(/<\/(p|div|section|article|h[1-6]|li|tr|br)\s*>/gi, '\n')
          .replace(/<[^>]+>/g, ' ')
      )
    );
    sections.push(fallback);
  }

  const merged = collapseWhitespace(sections.join('\n\n'));
  if (merged.length <= maxChars) {
    return { content: merged, truncated: false };
  }

  return {
    content: `${merged.slice(0, maxChars).trimEnd()}\n\n...[content truncated]`,
    truncated: true
  };
}

function optimizeFetchedContent(
  rawText: string,
  contentType: string,
  url: string,
  maxChars: number
): { content: string; extractedFromHTML: boolean; contentFormat: 'plain-text' | 'html-extracted'; truncated: boolean } {
  const boundedMaxChars = Math.max(1000, Math.min(maxChars, MAX_RETURN_TEXT_CHARS));
  if (isLikelyHTML(contentType, url)) {
    const htmlMaxChars = Math.min(boundedMaxChars, MAX_HTML_EXTRACT_CHARS);
    const extracted = extractHTMLContent(rawText, htmlMaxChars);
    return {
      content: extracted.content,
      extractedFromHTML: true,
      contentFormat: 'html-extracted',
      truncated: extracted.truncated
    };
  }

  const normalized = collapseWhitespace(rawText);
  if (normalized.length <= boundedMaxChars) {
    return {
      content: normalized,
      extractedFromHTML: false,
      contentFormat: 'plain-text',
      truncated: false
    };
  }

  return {
    content: `${normalized.slice(0, boundedMaxChars).trimEnd()}\n\n...[content truncated]`,
    extractedFromHTML: false,
    contentFormat: 'plain-text',
    truncated: true
  };
}

async function performWebFetch(request: WebFetchRequest): Promise<WebFetchResponse> {
  if (!request.groupFolder?.trim()) throw new Error('Missing groupFolder for web fetch');
  if (!request.url?.trim()) throw new Error('Missing url for web fetch');

  const initial = assertUrlAllowedByPolicy(request.url, request.groupFolder);
  const policy = initial.policy;
  const method = sanitizeMethod(request.method);
  const headers = sanitizeHeaders(request.headers);
  const timeoutMs = Math.min(
    clampPositiveInt(request.timeoutMs, policy.defaults.timeoutMs),
    policy.defaults.timeoutMs
  );
  const maxBytes = Math.min(
    clampPositiveInt(request.maxBytes, policy.defaults.maxBytes),
    policy.defaults.maxBytes
  );

  let currentUrl = initial.url.toString();
  const redirects: string[] = [];

  for (let attempt = 0; attempt <= MAX_REDIRECTS; attempt += 1) {
    const checked = assertUrlAllowedByPolicy(currentUrl, request.groupFolder);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    let response: Response;
    try {
      response = await fetch(checked.url, {
        method,
        headers,
        redirect: 'manual',
        signal: controller.signal
      });
    } finally {
      clearTimeout(timeout);
    }

    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      if (!location) {
        throw new Error(`Redirect (${response.status}) missing location`);
      }
      if (attempt === MAX_REDIRECTS) {
        throw new Error(`Too many redirects (>${MAX_REDIRECTS})`);
      }
      const next = new URL(location, checked.url).toString();
      redirects.push(next);
      currentUrl = next;
      continue;
    }

    const body = await readLimitedText(response, maxBytes);
    const contentType = response.headers.get('content-type') || '';
    const maxChars = Math.floor(maxBytes / 2);
    const optimized = optimizeFetchedContent(
      body.text,
      contentType,
      checked.url.toString(),
      maxChars
    );

    const sourceTruncated = body.truncated;
    const contentTruncated = optimized.truncated;
    const truncated = sourceTruncated || contentTruncated;

    return {
      ok: true,
      url: checked.url.toString(),
      status: response.status,
      statusText: response.statusText,
      contentType,
      content: optimized.content,
      contentFormat: optimized.contentFormat,
      extractedFromHTML: optimized.extractedFromHTML,
      bytes: body.bytes,
      contentBytes: Buffer.byteLength(optimized.content),
      truncated,
      sourceTruncated,
      contentTruncated,
      redirects
    };
  }

  throw new Error('Unexpected redirect handling failure');
}

interface DuckDuckGoTopic {
  Text?: string;
  FirstURL?: string;
  Topics?: DuckDuckGoTopic[];
}

function flattenDuckDuckGoTopics(topics: DuckDuckGoTopic[]): WebSearchResult[] {
  const out: WebSearchResult[] = [];
  const visit = (topic: DuckDuckGoTopic): void => {
    if (topic.FirstURL && topic.Text) {
      out.push({
        title: topic.Text,
        url: topic.FirstURL,
        snippet: topic.Text
      });
    }
    if (Array.isArray(topic.Topics)) {
      for (const child of topic.Topics) visit(child);
    }
  };
  for (const topic of topics) visit(topic);
  return out;
}

async function performWebSearch(request: WebSearchRequest): Promise<WebSearchResponse> {
  if (!request.groupFolder?.trim()) throw new Error('Missing groupFolder for web search');
  if (!request.query?.trim()) throw new Error('Missing query for web search');

  const limit = Math.min(clampPositiveInt(request.limit, 5), MAX_SEARCH_RESULTS);
  const searchUrl = new URL('https://api.duckduckgo.com/');
  searchUrl.searchParams.set('q', request.query);
  searchUrl.searchParams.set('format', 'json');
  searchUrl.searchParams.set('no_html', '1');
  searchUrl.searchParams.set('no_redirect', '1');
  searchUrl.searchParams.set('skip_disambig', '1');

  const checked = assertUrlAllowedByPolicy(searchUrl.toString(), request.groupFolder);
  const timeoutMs = checked.policy.defaults.timeoutMs;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetch(checked.url, {
      method: 'GET',
      headers: { accept: 'application/json' },
      redirect: 'manual',
      signal: controller.signal
    });
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    throw new Error(`Search provider returned ${response.status}`);
  }

  const payload = await response.json() as {
    Heading?: string;
    AbstractText?: string;
    AbstractURL?: string;
    RelatedTopics?: DuckDuckGoTopic[];
  };

  const results: WebSearchResult[] = [];
  if (payload.AbstractText && payload.AbstractURL) {
    results.push({
      title: payload.Heading || payload.AbstractURL,
      url: payload.AbstractURL,
      snippet: payload.AbstractText
    });
  }
  const related = Array.isArray(payload.RelatedTopics)
    ? flattenDuckDuckGoTopics(payload.RelatedTopics)
    : [];

  for (const item of related) {
    if (results.length >= limit) break;
    results.push(item);
  }

  return {
    ok: true,
    query: request.query,
    results: results.slice(0, limit)
  };
}

async function handleWebBrokerRequest(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
  const incomingUrl = new URL(req.url || '/', 'http://relay.local');
  if (!incomingUrl.pathname.startsWith('/web')) return false;

  if (incomingUrl.pathname === '/web/healthz') {
    writeJson(res, 200, { ok: true, service: 'web-broker' });
    return true;
  }

  if (req.method !== 'POST') {
    writeJson(res, 405, { ok: false, error: 'Method not allowed' });
    return true;
  }

  try {
    const body = await readJsonBody(req);
    if (incomingUrl.pathname === '/web/fetch') {
      const response = await performWebFetch(body as WebFetchRequest);
      writeJson(res, 200, response);
      return true;
    }
    if (incomingUrl.pathname === '/web/search') {
      const response = await performWebSearch(body as WebSearchRequest);
      writeJson(res, 200, response);
      return true;
    }
    if (incomingUrl.pathname === '/web/policy/list') {
      const payload = body as { groupFolder?: string };
      if (!payload.groupFolder?.trim()) throw new Error('Missing groupFolder for web policy listing');
      writeJson(res, 200, {
        ok: true,
        groupFolder: payload.groupFolder,
        ...getPolicySnapshot(payload.groupFolder)
      });
      return true;
    }
    writeJson(res, 404, { ok: false, error: 'Unknown web broker endpoint' });
    return true;
  } catch (error) {
    logger.warn(
      { path: req.url, method: req.method, error: toErrorMessage(error) },
      'Web broker request failed'
    );
    writeJson(res, 400, { ok: false, error: toErrorMessage(error) });
    return true;
  }
}

function getRelayResolver(): dns.Resolver | null {
  if (RELAY_DNS_SERVERS.length === 0) return null;
  if (!relayResolver) {
    relayResolver = new dns.Resolver();
    relayResolver.setServers(RELAY_DNS_SERVERS);
  }
  return relayResolver;
}

const relayLookup: LookupFunction = (hostname, options, callback) => {
  const resolver = getRelayResolver();
  if (!resolver) {
    dns.lookup(hostname, options as dns.LookupOneOptions, callback as never);
    return;
  }

  const normalizedOptions: dns.LookupOptions = typeof options === 'number'
    ? { family: options }
    : options;
  const family = normalizedOptions.family ?? 0;
  const wantsAll = normalizedOptions.all ?? false;

  const completeWithRecords = (records: dns.LookupAddress[]) => {
    if (wantsAll) {
      (callback as (err: NodeJS.ErrnoException | null, addresses: dns.LookupAddress[]) => void)(
        null,
        records
      );
      return;
    }
    const first = records[0];
    (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
      null,
      first.address,
      first.family
    );
  };

  const fail = (message: string) => {
    const error = new Error(message) as NodeJS.ErrnoException;
    error.code = 'ENOTFOUND';
    if (wantsAll) {
      (callback as (err: NodeJS.ErrnoException | null, addresses: dns.LookupAddress[]) => void)(
        error,
        []
      );
      return;
    }
    (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
      error,
      '',
      0
    );
  };

  const resolve4 = () =>
    new Promise<dns.LookupAddress[]>((resolve) => {
      resolver.resolve4(hostname, (error, addresses) => {
        if (error || !addresses || addresses.length === 0) {
          resolve([]);
          return;
        }
        resolve(addresses.map((address) => ({ address, family: 4 })));
      });
    });

  const resolve6 = () =>
    new Promise<dns.LookupAddress[]>((resolve) => {
      resolver.resolve6(hostname, (error, addresses) => {
        if (error || !addresses || addresses.length === 0) {
          resolve([]);
          return;
        }
        resolve(addresses.map((address) => ({ address, family: 6 })));
      });
    });

  void (async () => {
    let records: dns.LookupAddress[] = [];
    if (family === 4 || family === 0) records = records.concat(await resolve4());
    if (family === 6 || family === 0) records = records.concat(await resolve6());
    if (records.length === 0) {
      fail(`No relay DNS records found for ${hostname}`);
      return;
    }
    completeWithRecords(records);
  })().catch((error) => {
    fail(toErrorMessage(error));
  });
};

const relayHttpAgent = new http.Agent({
  keepAlive: true,
  lookup: relayLookup
});

const relayHttpsAgent = new https.Agent({
  keepAlive: true,
  lookup: relayLookup
});

function resolveRelayTarget(urlPath: string): { provider: RelayProvider; target: URL } | null {
  const incoming = new URL(urlPath, 'http://relay.local');
  const match = incoming.pathname.match(/^\/relay\/(openai|kimi|anthropic)(\/.*)?$/);
  if (!match) return null;

  const provider = match[1] as RelayProvider;
  const suffix = match[2] || '/';
  const target = new URL(RELAY_UPSTREAMS[provider]);
  target.pathname = suffix;
  target.search = incoming.search;
  return { provider, target };
}

function buildRelayFallbackCompletion(
  provider: RelayProvider,
  upstreamStatus: number,
  upstreamBody: string
): Record<string, unknown> {
  const messageParts = [
    `Upstream ${provider} API request failed`,
    upstreamStatus > 0 ? `with status ${upstreamStatus}.` : '.'
  ];
  const trimmedBody = upstreamBody.replace(/\s+/g, ' ').trim();
  if (trimmedBody) {
    messageParts.push(`Details: ${trimmedBody.slice(0, 280)}`);
  }
  return {
    id: 'relay-fallback',
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: `relay-${provider}`,
    choices: [
      {
        index: 0,
        message: {
          role: 'assistant',
          content: messageParts.join(' ')
        },
        finish_reason: 'stop'
      }
    ],
    usage: {
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0
    }
  };
}

function proxyRelayRequest(
  req: IncomingMessage,
  res: ServerResponse,
  relayTarget: { provider: RelayProvider; target: URL }
): void {
  const transport = relayTarget.target.protocol === 'https:' ? https : http;
  const relayAgent = relayTarget.target.protocol === 'https:' ? relayHttpsAgent : relayHttpAgent;

  const forwardedHeaders: http.OutgoingHttpHeaders = { ...req.headers };
  delete forwardedHeaders.host;
  delete forwardedHeaders['accept-encoding'];

  const requestOptions: RequestOptions = {
    protocol: relayTarget.target.protocol,
    hostname: relayTarget.target.hostname,
    port: relayTarget.target.port
      ? parseInt(relayTarget.target.port, 10)
      : relayTarget.target.protocol === 'https:'
        ? 443
        : 80,
    method: req.method || 'GET',
    path: `${relayTarget.target.pathname}${relayTarget.target.search}`,
    headers: forwardedHeaders,
    timeout: RELAY_TIMEOUT_MS,
    agent: relayAgent
  };

  const upstreamReq = transport.request(requestOptions, (upstreamRes) => {
    const bodyChunks: Buffer[] = [];

    upstreamRes.on('data', (chunk) => {
      bodyChunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });

    upstreamRes.on('end', () => {
      const body = Buffer.concat(bodyChunks);
      const upstreamStatus = upstreamRes.statusCode ?? 502;

      if (upstreamStatus !== 200) {
        const upstreamBody = body.toString('utf8').trim();
        const completion = buildRelayFallbackCompletion(relayTarget.provider, upstreamStatus, upstreamBody);
        const fallbackBody = Buffer.from(JSON.stringify(completion));
        writeJsonResponse(res, 200, fallbackBody, {
          'x-nanoclaw-relay-provider': relayTarget.provider,
          'x-nanoclaw-relay-upstream-status': String(upstreamStatus)
        });
        logger.warn(
          { provider: relayTarget.provider, upstreamStatus },
          'Relay received non-200 response from upstream'
        );
        return;
      }

      const responseHeaders: http.OutgoingHttpHeaders = {
        'content-length': String(body.length),
        'x-nanoclaw-relay-provider': relayTarget.provider
      };
      const contentType = upstreamRes.headers['content-type'];
      if (contentType) responseHeaders['content-type'] = contentType;

      res.writeHead(upstreamRes.statusCode ?? 502, responseHeaders);
      res.end(body);
    });

    upstreamRes.on('error', (error) => {
      logger.error(
        { provider: relayTarget.provider, error: toErrorMessage(error) },
        'Relay response stream failed'
      );
      if (res.headersSent) {
        res.end();
        return;
      }
      const completion = buildRelayFallbackCompletion(
        relayTarget.provider,
        0,
        `Relay response stream failed: ${toErrorMessage(error)}`
      );
      const fallbackBody = Buffer.from(JSON.stringify(completion));
      writeJsonResponse(res, 200, fallbackBody, {
        'x-nanoclaw-relay-provider': relayTarget.provider,
        'x-nanoclaw-relay-upstream-status': '0'
      });
    });
  });

  upstreamReq.on('timeout', () => {
    upstreamReq.destroy(new Error(`Upstream timeout after ${RELAY_TIMEOUT_MS}ms`));
  });

  upstreamReq.on('error', (error) => {
    logger.error(
      {
        provider: relayTarget.provider,
        error: toErrorMessage(error),
        code: (error as NodeJS.ErrnoException).code
      },
      'Relay upstream request failed'
    );
    if (res.headersSent) {
      res.end();
      return;
    }
    const completion = buildRelayFallbackCompletion(
      relayTarget.provider,
      0,
      `Relay upstream request failed: ${toErrorMessage(error)}`
    );
    const fallbackBody = Buffer.from(JSON.stringify(completion));
    writeJsonResponse(res, 200, fallbackBody, {
      'x-nanoclaw-relay-provider': relayTarget.provider,
      'x-nanoclaw-relay-upstream-status': '0'
    });
  });

  req.on('error', (error) => {
    upstreamReq.destroy(error);
  });

  req.pipe(upstreamReq);
}

function writeJsonResponse(
  res: ServerResponse,
  statusCode: number,
  body: Buffer,
  extraHeaders: http.OutgoingHttpHeaders = {}
): void {
  res.writeHead(statusCode, {
    'content-type': 'application/json',
    'content-length': String(body.length),
    ...extraHeaders
  });
  res.end(body);
}

async function handleRelayRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (await handleWebBrokerRequest(req, res)) return;

  const url = req.url || '/';
  if (url === '/healthz') {
    writeJson(res, 200, { ok: true });
    return;
  }

  const relayTarget = resolveRelayTarget(url);
  if (!relayTarget) {
    writeJson(res, 404, { error: 'Unknown relay endpoint' });
    return;
  }

  proxyRelayRequest(req, res, relayTarget);
}

export async function startHostRelay(): Promise<RelayRuntimeInfo> {
  if (relayServer) {
    return {
      bind: RELAY_BIND,
      host: RELAY_HOST,
      port: RELAY_PORT,
      webBrokerURL: `http://${RELAY_HOST}:${RELAY_PORT}/web`
    };
  }
  if (relayStartPromise) return relayStartPromise;

  relayStartPromise = new Promise<RelayRuntimeInfo>((resolve, reject) => {
    const server = http.createServer((req, res) => {
      void handleRelayRequest(req, res).catch((error) => {
        logger.error({ error: toErrorMessage(error), path: req.url }, 'Relay request handling failed');
        if (!res.headersSent) {
          writeJson(res, 500, { error: 'Relay internal error' });
        }
      });
    });
    server.keepAliveTimeout = 60_000;
    server.headersTimeout = 65_000;
    server.on('clientError', (error, socket) => {
      logger.warn({ error: toErrorMessage(error) }, 'Relay client error');
      socket.destroy();
    });

    server.once('error', (error) => {
      relayStartPromise = null;
      reject(error);
    });

    server.once('listening', () => {
      relayServer = server;
      const info = {
        bind: RELAY_BIND,
        host: RELAY_HOST,
        port: RELAY_PORT,
        webBrokerURL: `http://${RELAY_HOST}:${RELAY_PORT}/web`
      };
      logger.info(
        {
          ...info,
          dnsServers: RELAY_DNS_SERVERS.length ? RELAY_DNS_SERVERS.join(',') : '(system)'
        },
        'Host relay started'
      );
      resolve(info);
    });

    server.listen(RELAY_PORT, RELAY_BIND);
  });

  return relayStartPromise;
}

export async function stopHostRelay(): Promise<void> {
  relayStartPromise = null;
  if (!relayServer) return;
  await new Promise<void>((resolve) => {
    relayServer?.close(() => resolve());
  });
  relayServer = null;
}
