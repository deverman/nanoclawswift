import { type IncomingMessage, type ServerResponse } from 'http';
import pino from 'pino';

import { WEB_FETCH_MAX_BYTES, WEB_FETCH_TIMEOUT_MS } from './config.js';
import {
  WebFetchRequest,
  WebFetchResponse,
  WebSearchRequest,
  WebSearchResponse,
  WebSearchResult
} from './types.js';
import { assertUrlAllowedByPolicy, getWebPolicySnapshot } from './web-policy.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

const MAX_WEB_REQUEST_BODY_BYTES = 256 * 1024;
const MAX_REDIRECTS = 5;
const MAX_SEARCH_RESULTS = 10;

function toErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
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
    const bufferChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += bufferChunk.length;
    if (total > MAX_WEB_REQUEST_BODY_BYTES) {
      throw new Error(`Request body too large (${total} bytes)`);
    }
    chunks.push(bufferChunk);
  }

  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function sanitizeHeaders(raw: unknown): Record<string, string> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!key) continue;
    if (typeof value === 'string') {
      out[key] = value;
    } else if (typeof value === 'number' || typeof value === 'boolean') {
      out[key] = String(value);
    }
  }
  return out;
}

function sanitizeMethod(raw: unknown): string {
  if (typeof raw !== 'string' || !raw.trim()) return 'GET';
  const method = raw.trim().toUpperCase();
  const allowed = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE']);
  return allowed.has(method) ? method : 'GET';
}

function clampPositiveInt(raw: unknown, fallback: number): number {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return fallback;
  const rounded = Math.floor(raw);
  return rounded > 0 ? rounded : fallback;
}

async function readLimitedText(response: Response, maxBytes: number): Promise<{ text: string; bytes: number; truncated: boolean }> {
  if (!response.body) {
    return { text: '', bytes: 0, truncated: false };
  }

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

async function performWebFetch(request: WebFetchRequest): Promise<WebFetchResponse> {
  if (!request.groupFolder?.trim()) {
    throw new Error('Missing groupFolder for web fetch');
  }
  if (!request.url?.trim()) {
    throw new Error('Missing url for web fetch');
  }

  const initialCheck = assertUrlAllowedByPolicy(request.url, request.groupFolder);
  const policy = initialCheck.policy;
  const method = sanitizeMethod(request.method);
  const headers = sanitizeHeaders(request.headers);
  const timeoutMs = Math.min(
    clampPositiveInt(request.timeoutMs, policy.defaults.timeoutMs || WEB_FETCH_TIMEOUT_MS),
    policy.defaults.timeoutMs || WEB_FETCH_TIMEOUT_MS
  );
  const maxBytes = Math.min(
    clampPositiveInt(request.maxBytes, policy.defaults.maxBytes || WEB_FETCH_MAX_BYTES),
    policy.defaults.maxBytes || WEB_FETCH_MAX_BYTES
  );

  let currentUrl = initialCheck.url.toString();
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

    if (
      response.status === 301 ||
      response.status === 302 ||
      response.status === 303 ||
      response.status === 307 ||
      response.status === 308
    ) {
      const location = response.headers.get('location');
      if (!location) {
        throw new Error(`Redirect response (${response.status}) missing Location header`);
      }
      if (attempt === MAX_REDIRECTS) {
        throw new Error(`Too many redirects (>${MAX_REDIRECTS})`);
      }
      const redirectUrl = new URL(location, checked.url).toString();
      redirects.push(redirectUrl);
      currentUrl = redirectUrl;
      continue;
    }

    const body = await readLimitedText(response, maxBytes);
    return {
      ok: true,
      url: checked.url.toString(),
      status: response.status,
      statusText: response.statusText,
      contentType: response.headers.get('content-type') || '',
      content: body.text,
      bytes: body.bytes,
      truncated: body.truncated,
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
  const results: WebSearchResult[] = [];

  const visit = (topic: DuckDuckGoTopic): void => {
    if (topic.FirstURL && topic.Text) {
      results.push({
        title: topic.Text,
        url: topic.FirstURL,
        snippet: topic.Text
      });
    }
    if (Array.isArray(topic.Topics)) {
      for (const child of topic.Topics) {
        visit(child);
      }
    }
  };

  for (const topic of topics) {
    visit(topic);
  }

  return results;
}

async function performWebSearch(request: WebSearchRequest): Promise<WebSearchResponse> {
  if (!request.groupFolder?.trim()) {
    throw new Error('Missing groupFolder for web search');
  }
  if (!request.query?.trim()) {
    throw new Error('Missing query for web search');
  }

  const limit = Math.min(clampPositiveInt(request.limit, 5), MAX_SEARCH_RESULTS);
  const searchUrl = new URL('https://api.duckduckgo.com/');
  searchUrl.searchParams.set('q', request.query);
  searchUrl.searchParams.set('format', 'json');
  searchUrl.searchParams.set('no_html', '1');
  searchUrl.searchParams.set('no_redirect', '1');
  searchUrl.searchParams.set('skip_disambig', '1');

  const checked = assertUrlAllowedByPolicy(searchUrl.toString(), request.groupFolder);
  const timeoutMs = checked.policy.defaults.timeoutMs || WEB_FETCH_TIMEOUT_MS;

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

export async function handleWebBrokerRequest(
  req: IncomingMessage,
  res: ServerResponse
): Promise<boolean> {
  const incomingUrl = new URL(req.url || '/', 'http://relay.local');
  if (!incomingUrl.pathname.startsWith('/web')) {
    return false;
  }

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
      if (!payload.groupFolder?.trim()) {
        throw new Error('Missing groupFolder for web policy listing');
      }
      writeJson(res, 200, {
        ok: true,
        groupFolder: payload.groupFolder,
        ...getWebPolicySnapshot(payload.groupFolder)
      });
      return true;
    }

    writeJson(res, 404, { ok: false, error: 'Unknown web broker endpoint' });
    return true;
  } catch (error) {
    logger.warn(
      {
        path: req.url,
        method: req.method,
        error: toErrorMessage(error)
      },
      'Web broker request failed'
    );
    writeJson(res, 400, { ok: false, error: toErrorMessage(error) });
    return true;
  }
}
