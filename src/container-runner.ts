/**
 * Container Runner for NanoClaw
 * Spawns agent execution in Apple Container and handles IPC
 */

import { execSync, spawn } from 'child_process';
import dns from 'dns';
import fs from 'fs';
import http, { type IncomingMessage, type ServerResponse } from 'http';
import https from 'https';
import { type LookupFunction } from 'net';
import path from 'path';
import pino from 'pino';
import {
  CONTAINER_IMAGE,
  CONTAINER_TIMEOUT,
  CONTAINER_MAX_OUTPUT_SIZE,
  GROUPS_DIR,
  DATA_DIR,
  WEB_BROKER_PORT
} from './config.js';
import { RegisteredGroup } from './types.js';
import { validateAdditionalMounts } from './mount-security.js';
import { handleWebBrokerRequest } from './web-broker.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

// Sentinel markers for robust output parsing (must match agent-runner)
const OUTPUT_START_MARKER = '---NANOCLAW_OUTPUT_START---';
const OUTPUT_END_MARKER = '---NANOCLAW_OUTPUT_END---';

const CONTAINER_ENV_KEYS = [
  'MODEL_PROVIDER',
  'MODEL_NAME',
  'OPENAI_API_KEY',
  'MOONSHOT_API_KEY',
  'ANTHROPIC_API_KEY',
  'BASE_URL',
  'TIMEOUT',
  'MAX_TOKENS',
  'ASSISTANT_NAME',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'NANOCLAW_WEB_BROKER_URL',
  'NANOCLAW_GROUP_FOLDER'
] as const;

const CONTAINER_PREFLIGHT_TIMEOUT = parseInt(
  process.env.CONTAINER_PREFLIGHT_TIMEOUT || '15000',
  10
);

function parseCsvEnv(raw: string | undefined): string[] {
  if (!raw) return [];
  return raw
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
}

const CONTAINER_NO_DNS = process.env.CONTAINER_NO_DNS === '1';
const CONTAINER_DNS_SERVERS = parseCsvEnv(process.env.CONTAINER_DNS_SERVERS || '8.8.8.8');
const CONTAINER_DNS_DOMAIN = process.env.CONTAINER_DNS_DOMAIN?.trim();
const CONTAINER_DNS_OPTIONS = parseCsvEnv(process.env.CONTAINER_DNS_OPTIONS);
const CONTAINER_DNS_SEARCH_DOMAINS = parseCsvEnv(process.env.CONTAINER_DNS_SEARCH);

type RelayMode = 'off' | 'auto' | 'force';

function normalizeRelayMode(raw: string | undefined): RelayMode {
  switch ((raw || 'auto').toLowerCase()) {
    case 'off':
      return 'off';
    case 'force':
      return 'force';
    default:
      return 'auto';
  }
}

type RelayProvider = 'openai' | 'kimi' | 'anthropic';

const CONTAINER_LLM_RELAY_MODE = normalizeRelayMode(process.env.CONTAINER_LLM_RELAY_MODE);
const CONTAINER_LLM_RELAY_BIND = process.env.CONTAINER_LLM_RELAY_BIND || '0.0.0.0';
const CONTAINER_LLM_RELAY_HOST = process.env.CONTAINER_LLM_RELAY_HOST || '192.168.64.1';
const CONTAINER_LLM_RELAY_PORT = parseInt(
  process.env.CONTAINER_LLM_RELAY_PORT || String(WEB_BROKER_PORT),
  10
);
const CONTAINER_LLM_RELAY_TIMEOUT = parseInt(
  process.env.CONTAINER_LLM_RELAY_TIMEOUT || '120000',
  10
);
const CONTAINER_LLM_RELAY_DNS_SERVERS = parseCsvEnv(
  process.env.CONTAINER_LLM_RELAY_DNS_SERVERS || '1.1.1.1,8.8.8.8'
);

function detectDefaultRouteInterface(): string | null {
  try {
    const output = execSync('route -n get default', {
      stdio: ['ignore', 'pipe', 'ignore'],
      encoding: 'utf8'
    });
    const match = output.match(/^\s*interface:\s*(\S+)/m);
    return match?.[1] || null;
  } catch {
    return null;
  }
}

const DEFAULT_ROUTE_INTERFACE = detectDefaultRouteInterface();
const ROUTED_VIA_UTUN = DEFAULT_ROUTE_INTERFACE?.startsWith('utun') ?? false;

const RELAY_UPSTREAMS: Record<RelayProvider, string> = {
  openai: 'https://api.openai.com',
  kimi: 'https://api.moonshot.ai',
  anthropic: 'https://api.anthropic.com'
};

let containerPreflightPromise: Promise<void> | null = null;
let containerPreflightWarningLogged = false;
let llmRelayServerPromise: Promise<void> | null = null;
let llmRelayServer: http.Server | null = null;
let relayDnsResolver: dns.Resolver | null = null;
let relayRoutingHintLogged = false;

function getRelayDnsResolver(): dns.Resolver | null {
  if (CONTAINER_LLM_RELAY_DNS_SERVERS.length === 0) return null;
  if (!relayDnsResolver) {
    relayDnsResolver = new dns.Resolver();
    relayDnsResolver.setServers(CONTAINER_LLM_RELAY_DNS_SERVERS);
  }
  return relayDnsResolver;
}

const relayLookup: LookupFunction = (hostname, options, callback) => {
  const resolver = getRelayDnsResolver();
  if (!resolver) {
    dns.lookup(hostname, options as dns.LookupOneOptions, callback as never);
    return;
  }

  const normalizedOptions: dns.LookupOptions =
    typeof options === 'number' ? { family: options } : options;
  const family = normalizedOptions.family ?? 0;
  const all = normalizedOptions.all ?? false;

  const finish = (records: dns.LookupAddress[]) => {
    logger.debug({
      hostname,
      family,
      all,
      records: records.map((item) => `${item.address}/${item.family}`)
    }, 'LLM relay DNS lookup result');

    if (all) {
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
    logger.warn({ hostname, family, all, message }, 'LLM relay DNS lookup failed');
    const error = new Error(message) as NodeJS.ErrnoException;
    error.code = 'ENOTFOUND';
    if (all) {
      (callback as (err: NodeJS.ErrnoException | null, addresses: dns.LookupAddress[]) => void)(
        error,
        []
      );
    } else {
      (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
        error,
        '',
        0
      );
    }
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

  (async () => {
    let records: dns.LookupAddress[] = [];

    if (family === 4 || family === 0) {
      records = records.concat(await resolve4());
    }
    if (family === 6 || family === 0) {
      records = records.concat(await resolve6());
    }

    if (records.length === 0) {
      fail(`No relay DNS records found for ${hostname}`);
      return;
    }

    finish(records);
  })().catch((error) => {
    const lookupError = error instanceof Error ? error : new Error(String(error));
    const err = lookupError as NodeJS.ErrnoException;
    err.code = err.code || 'ENOTFOUND';
    if (all) {
      (callback as (err: NodeJS.ErrnoException | null, addresses: dns.LookupAddress[]) => void)(
        err,
        []
      );
    } else {
      (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
        err,
        '',
        0
      );
    }
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

function resolveProvider(containerEnv: Record<string, string>): RelayProvider {
  const provider = containerEnv.MODEL_PROVIDER?.trim().toLowerCase();
  if (provider === 'openai' || provider === 'anthropic' || provider === 'kimi') {
    return provider;
  }

  if (containerEnv.OPENAI_API_KEY) return 'openai';
  if (containerEnv.MOONSHOT_API_KEY) return 'kimi';
  if (containerEnv.ANTHROPIC_API_KEY) return 'anthropic';
  return 'kimi';
}

function shouldApplyRelay(containerEnv: Record<string, string>): boolean {
  if (CONTAINER_LLM_RELAY_MODE === 'off') return false;
  if (CONTAINER_LLM_RELAY_MODE === 'force') return true;
  if (containerEnv.BASE_URL) return false;
  return ROUTED_VIA_UTUN;
}

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
  // Keep upstream responses simple for FoundationNetworking clients.
  delete forwardedHeaders['accept-encoding'];

  const requestOptions: http.RequestOptions = {
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
      timeout: CONTAINER_LLM_RELAY_TIMEOUT,
      agent: relayAgent
    };

  const upstreamReq = transport.request(
    requestOptions,
    (upstreamRes) => {
      const bodyChunks: Buffer[] = [];

      upstreamRes.on('data', (chunk) => {
        bodyChunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      });

      upstreamRes.on('end', () => {
        const body = Buffer.concat(bodyChunks);
        const upstreamStatus = upstreamRes.statusCode ?? 502;

        if (upstreamStatus !== 200) {
          const upstreamBody = body.toString('utf8').trim();
          const completion = buildRelayFallbackCompletion(
            relayTarget.provider,
            upstreamStatus,
            upstreamBody
          );
          const fallbackBody = Buffer.from(JSON.stringify(completion));
          const responseHeaders: http.OutgoingHttpHeaders = {
            'content-type': 'application/json',
            'content-length': String(fallbackBody.length),
            'x-nanoclaw-relay-provider': relayTarget.provider,
            'x-nanoclaw-relay-upstream-status': String(upstreamStatus)
          };

          logger.warn({
            provider: relayTarget.provider,
            upstreamStatus
          }, 'LLM relay received non-200 response from upstream');

          res.writeHead(200, responseHeaders);
          res.end(fallbackBody);
          return;
        }

        const responseHeaders: http.OutgoingHttpHeaders = {
          'content-length': String(body.length),
          'x-nanoclaw-relay-provider': relayTarget.provider
        };

        const contentType = upstreamRes.headers['content-type'];
        if (contentType) {
          responseHeaders['content-type'] = contentType;
        }

        res.writeHead(upstreamRes.statusCode ?? 502, responseHeaders);
        res.end(body);
      });

      upstreamRes.on('error', (error) => {
        logger.error({ error: String(error), provider: relayTarget.provider }, 'LLM relay response stream failed');
        if (res.headersSent) {
          res.end();
          return;
        }

        const completion = buildRelayFallbackCompletion(
          relayTarget.provider,
          0,
          `Relay response stream failed: ${String(error)}`
        );
        const fallbackBody = Buffer.from(JSON.stringify(completion));
        res.writeHead(200, {
          'content-type': 'application/json',
          'content-length': String(fallbackBody.length),
          'x-nanoclaw-relay-provider': relayTarget.provider,
          'x-nanoclaw-relay-upstream-status': '0'
        });
        res.end(fallbackBody);
      });
    }
  );

  upstreamReq.on('timeout', () => {
    upstreamReq.destroy(
      new Error(`Upstream timeout after ${CONTAINER_LLM_RELAY_TIMEOUT}ms`)
    );
  });

  upstreamReq.on('error', (error) => {
    const details = error instanceof AggregateError
      ? error.errors.map((item) => String(item))
      : undefined;
    logger.error({
      error: String(error),
      provider: relayTarget.provider,
      code: (error as NodeJS.ErrnoException).code,
      details
    }, 'LLM relay upstream request failed');
    if (res.headersSent) {
      res.end();
      return;
    }

    const completion = buildRelayFallbackCompletion(
      relayTarget.provider,
      0,
      `Relay upstream request failed: ${String(error)}`
    );
    const fallbackBody = Buffer.from(JSON.stringify(completion));
    res.writeHead(200, {
      'content-type': 'application/json',
      'content-length': String(fallbackBody.length),
      'x-nanoclaw-relay-provider': relayTarget.provider,
      'x-nanoclaw-relay-upstream-status': '0'
    });
    res.end(fallbackBody);
  });

  req.on('error', (error) => {
    upstreamReq.destroy(error);
  });

  req.pipe(upstreamReq);
}

function handleRelayRequest(req: IncomingMessage, res: ServerResponse): void {
  void (async () => {
    if (await handleWebBrokerRequest(req, res)) {
      return;
    }

    if ((req.url || '/') === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    const relayTarget = resolveRelayTarget(req.url || '/');
    if (!relayTarget) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unknown relay endpoint' }));
      return;
    }

    proxyRelayRequest(req, res, relayTarget);
  })().catch((error) => {
    logger.error({ error: String(error), path: req.url }, 'Relay request handling failed');
    if (res.headersSent) return;
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'Relay internal error' }));
  });
}

async function ensureLlmRelayServer(): Promise<void> {
  if (llmRelayServerPromise) {
    return llmRelayServerPromise;
  }

  llmRelayServerPromise = new Promise<void>((resolve, reject) => {
    const server = http.createServer(handleRelayRequest);
    server.keepAliveTimeout = 60_000;
    server.headersTimeout = 65_000;

    server.on('clientError', (error, socket) => {
      logger.warn({ error: String(error) }, 'LLM relay client error');
      socket.destroy();
    });

    const onError = (error: Error) => {
      server.off('listening', onListening);
      reject(error);
    };

    const onListening = () => {
      server.off('error', onError);
      llmRelayServer = server;
      logger.info({
        bind: CONTAINER_LLM_RELAY_BIND,
        host: CONTAINER_LLM_RELAY_HOST,
        port: CONTAINER_LLM_RELAY_PORT,
        dnsServers: CONTAINER_LLM_RELAY_DNS_SERVERS.length
          ? CONTAINER_LLM_RELAY_DNS_SERVERS.join(',')
          : '(system)'
      }, 'LLM relay started');
      resolve();
    };

    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(CONTAINER_LLM_RELAY_PORT, CONTAINER_LLM_RELAY_BIND);
  });

  try {
    await llmRelayServerPromise;
  } catch (error) {
    llmRelayServerPromise = null;
    llmRelayServer = null;
    throw error;
  }
}

async function maybeApplyLlmRelay(
  groupFolder: string,
  containerEnv: Record<string, string>
): Promise<void> {
  const shouldRelay = shouldApplyRelay(containerEnv);
  if (!relayRoutingHintLogged) {
    relayRoutingHintLogged = true;
    logger.info({
      relayMode: CONTAINER_LLM_RELAY_MODE,
      routedViaUtun: ROUTED_VIA_UTUN,
      defaultRouteInterface: DEFAULT_ROUTE_INTERFACE || '(unknown)',
      relayWillApplyByDefault: shouldRelay && !containerEnv.BASE_URL
    }, 'Container networking mode detected');
  }

  if (!shouldRelay) return;

  const provider = resolveProvider(containerEnv);

  try {
    await ensureLlmRelayServer();
  } catch (error) {
    logger.error({ error: String(error) }, 'Failed to start LLM relay, falling back to direct network');
    return;
  }

  const relayBaseURL =
    `http://${CONTAINER_LLM_RELAY_HOST}:${CONTAINER_LLM_RELAY_PORT}` +
    `/relay/${provider}/v1`;

  const previousBaseURL = containerEnv.BASE_URL;
  containerEnv.BASE_URL = relayBaseURL;

  logger.info({
    groupFolder,
    provider,
    relayBaseURL,
    mode: CONTAINER_LLM_RELAY_MODE,
    previousBaseURL: previousBaseURL || '(none)'
  }, 'Configured container BASE_URL to use host LLM relay');
}

async function configureWebBrokerEnv(
  groupFolder: string,
  containerEnv: Record<string, string>
): Promise<void> {
  containerEnv.NANOCLAW_GROUP_FOLDER = groupFolder;

  try {
    await ensureLlmRelayServer();
  } catch (error) {
    logger.error(
      { groupFolder, error: String(error) },
      'Failed to start host relay for web broker'
    );
    return;
  }

  containerEnv.NANOCLAW_WEB_BROKER_URL =
    `http://${CONTAINER_LLM_RELAY_HOST}:${CONTAINER_LLM_RELAY_PORT}/web`;

  logger.debug(
    {
      groupFolder,
      webBrokerURL: containerEnv.NANOCLAW_WEB_BROKER_URL
    },
    'Configured container web broker URL'
  );
}

function parseSimpleEnvFile(filePath: string): Record<string, string> {
  if (!fs.existsSync(filePath)) return {};

  const envVars: Record<string, string> = {};
  const contents = fs.readFileSync(filePath, 'utf-8');

  for (const rawLine of contents.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    const separatorIndex = line.indexOf('=');
    if (separatorIndex <= 0) continue;

    const key = line.slice(0, separatorIndex).trim();
    let value = line.slice(separatorIndex + 1).trim();
    if (!key) continue;

    // Handle simple quoted values from .env files.
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    envVars[key] = value;
  }

  return envVars;
}

async function buildContainerEnvFile(groupFolder: string): Promise<string | null> {
  const envDir = path.join(DATA_DIR, 'env');
  fs.mkdirSync(envDir, { recursive: true });

  const safeGroupFolder = groupFolder.replace(/[^a-zA-Z0-9_.-]/g, '_');
  const envFilePath = path.join(envDir, `${safeGroupFolder}.env`);

  // Load local .env as a fallback when variables aren't exported in the host process.
  const dotenvValues = parseSimpleEnvFile(path.join(process.cwd(), '.env'));
  const containerEnv: Record<string, string> = {};

  for (const key of CONTAINER_ENV_KEYS) {
    const value = process.env[key] ?? dotenvValues[key];
    if (value) {
      containerEnv[key] = value;
    }
  }

  await configureWebBrokerEnv(groupFolder, containerEnv);
  await maybeApplyLlmRelay(groupFolder, containerEnv);

  const lines = Object.entries(containerEnv).map(([key, value]) => `${key}=${value}`);

  if (lines.length === 0) {
    if (fs.existsSync(envFilePath)) fs.unlinkSync(envFilePath);
    return null;
  }

  fs.writeFileSync(envFilePath, `${lines.join('\n')}\n`, { mode: 0o600 });
  return envFilePath;
}

export interface ContainerInput {
  prompt: string;
  sessionId?: string;
  groupFolder: string;
  chatJid: string;
  isMain: boolean;
  isScheduledTask?: boolean;
}

export interface ContainerOutput {
  status: 'success' | 'error';
  result: string | null;
  newSessionId?: string;
  error?: string;
}

interface VolumeMount {
  hostPath: string;
  containerPath: string;
  readonly?: boolean;
}

function buildVolumeMounts(group: RegisteredGroup, isMain: boolean): VolumeMount[] {
  const mounts: VolumeMount[] = [];
  const projectRoot = process.cwd();

  if (isMain) {
    // Main gets the entire project root mounted
    mounts.push({
      hostPath: projectRoot,
      containerPath: '/workspace/project',
      readonly: false
    });

    // Main also gets its group folder as the working directory
    mounts.push({
      hostPath: path.join(GROUPS_DIR, group.folder),
      containerPath: '/workspace/group',
      readonly: false
    });
  } else {
    // Other groups only get their own folder
    mounts.push({
      hostPath: path.resolve(GROUPS_DIR, group.folder),
      containerPath: '/workspace/group',
      readonly: false
    });

    // Global memory directory (read-only for non-main)
    // Apple Container only supports directory mounts, not file mounts
    const globalDir = path.join(GROUPS_DIR, 'global');
    if (fs.existsSync(globalDir)) {
      mounts.push({
        hostPath: globalDir,
        containerPath: '/workspace/global',
        readonly: true
      });
    }
  }

  // Per-group Claude sessions directory (isolated from other groups)
  // Each group gets their own .claude/ to prevent cross-group session access
  const groupSessionsDir = path.join(DATA_DIR, 'sessions', group.folder, '.claude');
  fs.mkdirSync(groupSessionsDir, { recursive: true });
  mounts.push({
    hostPath: groupSessionsDir,
    containerPath: '/home/node/.claude',
    readonly: false
  });

  // Per-group IPC namespace: each group gets its own IPC directory
  // This prevents cross-group privilege escalation via IPC
  const groupIpcDir = path.join(DATA_DIR, 'ipc', group.folder);
  fs.mkdirSync(path.join(groupIpcDir, 'messages'), { recursive: true });
  fs.mkdirSync(path.join(groupIpcDir, 'tasks'), { recursive: true });
  mounts.push({
    hostPath: groupIpcDir,
    containerPath: '/workspace/ipc',
    readonly: false
  });

  // Additional mounts validated against external allowlist (tamper-proof from containers)
  if (group.containerConfig?.additionalMounts) {
    const validatedMounts = validateAdditionalMounts(
      group.containerConfig.additionalMounts,
      group.name,
      isMain
    );
    mounts.push(...validatedMounts);
  }

  return mounts;
}

function buildContainerArgs(mounts: VolumeMount[], envFilePath: string | null): string[] {
  const args: string[] = ['run', '-i', '--rm'];

  if (CONTAINER_NO_DNS) {
    args.push('--no-dns');
  } else {
    for (const dnsServer of CONTAINER_DNS_SERVERS) {
      args.push('--dns', dnsServer);
    }
    if (CONTAINER_DNS_DOMAIN) {
      args.push('--dns-domain', CONTAINER_DNS_DOMAIN);
    }
    for (const dnsOption of CONTAINER_DNS_OPTIONS) {
      args.push('--dns-option', dnsOption);
    }
    for (const searchDomain of CONTAINER_DNS_SEARCH_DOMAINS) {
      args.push('--dns-search', searchDomain);
    }
  }

  // Apple Container: --mount for readonly, -v for read-write
  for (const mount of mounts) {
    if (mount.readonly) {
      args.push('--mount', `type=bind,source=${mount.hostPath},target=${mount.containerPath},readonly`);
    } else {
      args.push('-v', `${mount.hostPath}:${mount.containerPath}`);
    }
  }

  // container 0.9.0 supports --env-file with -i; use it to avoid brittle quoting.
  if (envFilePath) {
    args.push('--env-file', envFilePath);
  }

  args.push(CONTAINER_IMAGE);

  return args;
}

interface CommandResult {
  code: number;
  stdout: string;
  stderr: string;
}

function runContainerCli(args: string[], timeoutMs: number): Promise<CommandResult> {
  return new Promise((resolve, reject) => {
    const proc = spawn('container', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });
    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    const timeout = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`Timed out running: container ${args.join(' ')}`));
    }, timeoutMs);

    proc.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });

    proc.on('close', (code) => {
      clearTimeout(timeout);
      resolve({
        code: code ?? 1,
        stdout,
        stderr
      });
    });
  });
}

function looksLikeDigestMetadataFailure(output: string): boolean {
  const normalized = output.toLowerCase();
  return (
    normalized.includes('not found') &&
    normalized.includes('sha256:') &&
    normalized.includes('digest')
  );
}

function buildImageInspectFailureMessage(output: string): string {
  return [
    `Container image preflight failed for "${CONTAINER_IMAGE}".`,
    'Unable to inspect the configured image. Build or pull it before starting NanoClaw.',
    '',
    `Suggested fixes:`,
    `1. Build image: ./container/build-swift.sh slim`,
    `2. Or set CONTAINER_IMAGE to an existing tag`,
    '',
    `container image inspect output: ${output.trim() || '(no output)'}`
  ].join('\n');
}

function buildDigestRecoveryMessage(output: string): string {
  return [
    'Detected container image metadata inconsistency (digest lookup failure).',
    'Agent runs may still work, but image-management commands can fail unpredictably.',
    '',
    'Suggested recovery:',
    '1. Restart services: container system stop && container system start',
    '2. Re-pull stale tags (for this repo typically swift:6.2.3*), or clean stale refs with backup',
    `3. Re-check: container image ls`,
    '',
    `Raw output: ${output.trim() || '(no output)'}`
  ].join('\n');
}

async function ensureContainerPreflight(): Promise<void> {
  if (containerPreflightPromise) {
    return containerPreflightPromise;
  }

  containerPreflightPromise = (async () => {
    const inspect = await runContainerCli(
      ['image', 'inspect', CONTAINER_IMAGE],
      CONTAINER_PREFLIGHT_TIMEOUT
    );

    if (inspect.code !== 0) {
      const output = [inspect.stderr, inspect.stdout].filter(Boolean).join('\n');
      throw new Error(buildImageInspectFailureMessage(output));
    }

    const imageList = await runContainerCli(
      ['image', 'ls'],
      CONTAINER_PREFLIGHT_TIMEOUT
    );

    if (imageList.code !== 0) {
      const output = [imageList.stderr, imageList.stdout].filter(Boolean).join('\n');

      if (looksLikeDigestMetadataFailure(output)) {
        if (!containerPreflightWarningLogged) {
          containerPreflightWarningLogged = true;
          logger.warn({ output }, buildDigestRecoveryMessage(output));
        }
      } else {
        logger.warn({ output }, 'container image ls failed during preflight');
      }
    }
  })();

  try {
    await containerPreflightPromise;
  } catch (error) {
    // Allow retries after a preflight failure (e.g. image built while process is running).
    containerPreflightPromise = null;
    throw error;
  }
}

export async function runContainerAgent(
  group: RegisteredGroup,
  input: ContainerInput
): Promise<ContainerOutput> {
  const startTime = Date.now();

  try {
    await ensureContainerPreflight();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error({ group: group.name, error: message }, 'Container preflight failed');
    return {
      status: 'error',
      result: null,
      error: message
    };
  }

  const groupDir = path.join(GROUPS_DIR, group.folder);
  fs.mkdirSync(groupDir, { recursive: true });
  fs.mkdirSync(path.join(groupDir, '.nanoclaw'), { recursive: true });

  const mounts = buildVolumeMounts(group, input.isMain);
  const envFilePath = await buildContainerEnvFile(group.folder);
  const containerArgs = buildContainerArgs(mounts, envFilePath);

  logger.debug({
    group: group.name,
    mounts: mounts.map(m => `${m.hostPath} -> ${m.containerPath}${m.readonly ? ' (ro)' : ''}`),
    envFilePath,
    containerArgs: containerArgs.join(' ')
  }, 'Container mount configuration');

  logger.info({
    group: group.name,
    mountCount: mounts.length,
    isMain: input.isMain
  }, 'Spawning container agent');

  const logsDir = path.join(GROUPS_DIR, group.folder, 'logs');
  fs.mkdirSync(logsDir, { recursive: true });

  return new Promise((resolve) => {
    // Build Swift CLI arguments
    const swiftArgs = [
      '--config', '/workspace/config.json',
      '--group-folder', '/workspace/group',
      '--chat-jid', input.chatJid
    ];
    
    if (input.sessionId) {
      swiftArgs.push('--session-id', input.sessionId);
    }
    
    if (input.isMain) {
      swiftArgs.push('--is-main');
    }
    
    if (input.isScheduledTask) {
      swiftArgs.push('--is-scheduled-task');
    }
    
    const fullArgs = [...containerArgs, ...swiftArgs];
    
    const container = spawn('container', fullArgs, {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';
    let stdoutTruncated = false;
    let stderrTruncated = false;

    // Send prompt via stdin
    container.stdin.write(input.prompt);
    container.stdin.end();

    container.stdout.on('data', (data) => {
      if (stdoutTruncated) return;
      const chunk = data.toString();
      const remaining = CONTAINER_MAX_OUTPUT_SIZE - stdout.length;
      if (chunk.length > remaining) {
        stdout += chunk.slice(0, remaining);
        stdoutTruncated = true;
        logger.warn({ group: group.name, size: stdout.length }, 'Container stdout truncated due to size limit');
      } else {
        stdout += chunk;
      }
    });

    container.stderr.on('data', (data) => {
      const chunk = data.toString();
      const lines = chunk.trim().split('\n');
      for (const line of lines) {
        if (line) logger.info({ container: group.folder }, line);
      }
      if (stderrTruncated) return;
      const remaining = CONTAINER_MAX_OUTPUT_SIZE - stderr.length;
      if (chunk.length > remaining) {
        stderr += chunk.slice(0, remaining);
        stderrTruncated = true;
        logger.warn({ group: group.name, size: stderr.length }, 'Container stderr truncated due to size limit');
      } else {
        stderr += chunk;
      }
    });

    const timeout = setTimeout(() => {
      logger.error({ group: group.name }, 'Container timeout, killing');
      container.kill('SIGKILL');
      resolve({
        status: 'error',
        result: null,
        error: `Container timed out after ${CONTAINER_TIMEOUT}ms`
      });
    }, group.containerConfig?.timeout || CONTAINER_TIMEOUT);

    container.on('close', (code) => {
      clearTimeout(timeout);
      const duration = Date.now() - startTime;
      
      logger.info({
        group: group.name,
        exitCode: code,
        duration: duration,
        stdoutLength: stdout.length,
        stderrLength: stderr.length
      }, 'Container completed');

      const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
      const logFile = path.join(logsDir, `container-${timestamp}.log`);
      const isVerbose = process.env.LOG_LEVEL === 'debug' || process.env.LOG_LEVEL === 'trace';

      const logLines = [
        `=== Container Run Log ===`,
        `Timestamp: ${new Date().toISOString()}`,
        `Group: ${group.name}`,
        `IsMain: ${input.isMain}`,
        `Duration: ${duration}ms`,
        `Exit Code: ${code}`,
        `Stdout Truncated: ${stdoutTruncated}`,
        `Stderr Truncated: ${stderrTruncated}`,
        ``
      ];

      if (isVerbose) {
        logLines.push(
          `=== Input ===`,
          JSON.stringify(input, null, 2),
          ``,
          `=== Container Args ===`,
          containerArgs.join(' '),
          ``,
          `=== Mounts ===`,
          mounts.map(m => `${m.hostPath} -> ${m.containerPath}${m.readonly ? ' (ro)' : ''}`).join('\n'),
          ``,
          `=== Stderr${stderrTruncated ? ' (TRUNCATED)' : ''} ===`,
          stderr,
          ``,
          `=== Stdout${stdoutTruncated ? ' (TRUNCATED)' : ''} ===`,
          stdout
        );
      } else {
        logLines.push(
          `=== Input Summary ===`,
          `Prompt length: ${input.prompt.length} chars`,
          `Session ID: ${input.sessionId || 'new'}`,
          ``,
          `=== Mounts ===`,
          mounts.map(m => `${m.containerPath}${m.readonly ? ' (ro)' : ''}`).join('\n'),
          ``
        );

        if (code !== 0) {
          logLines.push(
            `=== Stderr (last 500 chars) ===`,
            stderr.slice(-500),
            ``
          );
        }
      }

      fs.writeFileSync(logFile, logLines.join('\n'));
      logger.debug({ logFile, verbose: isVerbose }, 'Container log written');

      if (code !== 0) {
        logger.error({
          group: group.name,
          code,
          duration,
          stderr: stderr.slice(-500),
          logFile
        }, 'Container exited with error');

        resolve({
          status: 'error',
          result: null,
          error: `Container exited with code ${code}: ${stderr.slice(-200)}`
        });
        return;
      }

      try {
        // Extract JSON between sentinel markers for robust parsing
        const startIdx = stdout.indexOf(OUTPUT_START_MARKER);
        const endIdx = stdout.indexOf(OUTPUT_END_MARKER);

        let jsonLine: string;
        if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
          jsonLine = stdout.slice(startIdx + OUTPUT_START_MARKER.length, endIdx).trim();
        } else {
          // Fallback: last non-empty line (backwards compatibility)
          const lines = stdout.trim().split('\n');
          jsonLine = lines[lines.length - 1];
        }

        const output: ContainerOutput = JSON.parse(jsonLine);

        logger.info({
          group: group.name,
          duration,
          status: output.status,
          hasResult: !!output.result
        }, 'Container completed');

        resolve(output);
      } catch (err) {
        logger.error({
          group: group.name,
          stdout: stdout.slice(-500),
          error: err
        }, 'Failed to parse container output');

        resolve({
          status: 'error',
          result: null,
          error: `Failed to parse container output: ${err instanceof Error ? err.message : String(err)}`
        });
      }
    });

    container.on('error', (err) => {
      clearTimeout(timeout);
      logger.error({ group: group.name, error: err }, 'Container spawn error');
      resolve({
        status: 'error',
        result: null,
        error: `Container spawn error: ${err.message}`
      });
    });
  });
}

export function writeTasksSnapshot(
  groupFolder: string,
  isMain: boolean,
  tasks: Array<{
    id: string;
    groupFolder: string;
    prompt: string;
    schedule_type: string;
    schedule_value: string;
    status: string;
    next_run: string | null;
  }>
): void {
  // Write filtered tasks to the group's IPC directory
  const groupIpcDir = path.join(DATA_DIR, 'ipc', groupFolder);
  fs.mkdirSync(groupIpcDir, { recursive: true });

  // Main sees all tasks, others only see their own
  const filteredTasks = isMain
    ? tasks
    : tasks.filter(t => t.groupFolder === groupFolder);

  const tasksFile = path.join(groupIpcDir, 'current_tasks.json');
  fs.writeFileSync(tasksFile, JSON.stringify(filteredTasks, null, 2));
}

export interface AvailableGroup {
  jid: string;
  name: string;
  lastActivity: string;
  isRegistered: boolean;
}

/**
 * Write available groups snapshot for the container to read.
 * Only main group can see all available groups (for activation).
 * Non-main groups only see their own registration status.
 */
export function writeGroupsSnapshot(
  groupFolder: string,
  isMain: boolean,
  groups: AvailableGroup[],
  registeredJids: Set<string>
): void {
  const groupIpcDir = path.join(DATA_DIR, 'ipc', groupFolder);
  fs.mkdirSync(groupIpcDir, { recursive: true });

  // Main sees all groups; others see nothing (they can't activate groups)
  const visibleGroups = isMain ? groups : [];

  const groupsFile = path.join(groupIpcDir, 'available_groups.json');
  fs.writeFileSync(groupsFile, JSON.stringify({
    groups: visibleGroups,
    lastSync: new Date().toISOString()
  }, null, 2));
}
