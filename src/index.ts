/**
 * DEPRECATED TRANSITIONAL ENTRYPOINT
 *
 * Runtime control has moved to Swift host CLI:
 *   - swift run nanoclaw-hostctl restart --foreground
 *
 * Keep this file only for temporary reference during Swift-only cleanup.
 * Do not add new runtime behavior here.
 */

import type { WASocket } from '@whiskeysockets/baileys';
import pino from 'pino';
import { spawn, execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

import {
  ASSISTANT_NAME,
  STORE_DIR,
  TRIGGER_PATTERN,
  WHATSAPP_ENABLED,
  HOST_SOCKET_PATH,
  HOST_OUTBOUND_POLL_INTERVAL_MS,
  HOST_AUTOSTART,
  HOST_STARTUP_TIMEOUT_MS
} from './config.js';
import { postInboundEvent, claimOutbound, ackOutbound, hostHealth, type HostInboundEvent } from './host-client.js';
import { startHostRelay, stopHostRelay } from './host-relay.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

let sock: WASocket | null = null;
let hostProcess: ReturnType<typeof spawn> | null = null;
let relayStarted = false;
let shuttingDown = false;
let whatsappConnecting = false;

const outboundLoopStarted: Record<'whatsapp', boolean> = {
  whatsapp: false
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function ensureContainerSystemRunning(): void {
  try {
    execSync('container system status', { stdio: 'pipe' });
    logger.debug('Apple Container system already running');
  } catch {
    logger.info('Starting Apple Container system...');
    try {
      execSync('container system start', { stdio: 'pipe', timeout: 30000 });
      logger.info('Apple Container system started');
    } catch (err) {
      logger.error({ err }, 'Failed to start Apple Container system');
      throw new Error('Apple Container system is required but failed to start');
    }
  }
}

type RelayProvider = 'openai' | 'kimi' | 'anthropic';
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

function resolveRelayProvider(env: NodeJS.ProcessEnv): RelayProvider {
  const configured = (env.MODEL_PROVIDER || '').trim().toLowerCase();
  if (configured === 'openai' || configured === 'anthropic' || configured === 'kimi') {
    return configured;
  }
  if (env.OPENAI_API_KEY) return 'openai';
  if (env.MOONSHOT_API_KEY) return 'kimi';
  if (env.ANTHROPIC_API_KEY) return 'anthropic';
  return 'kimi';
}

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

async function ensureRelayEnvironmentConfigured(): Promise<void> {
  const relayInfo = await startHostRelay();
  relayStarted = true;

  const relayMode = normalizeRelayMode(process.env.CONTAINER_LLM_RELAY_MODE);
  const provider = resolveRelayProvider(process.env);
  const previousBaseURL = process.env.BASE_URL;
  const relayBaseURL = `http://${relayInfo.host}:${relayInfo.port}/relay/${provider}/v1`;
  const defaultRouteInterface = detectDefaultRouteInterface();
  const routedViaUtun = defaultRouteInterface?.startsWith('utun') ?? false;
  const applyRelayBaseURL = relayMode === 'force' || (relayMode === 'auto' && !previousBaseURL);

  process.env.NANOCLAW_WEB_BROKER_URL = relayInfo.webBrokerURL;
  if (applyRelayBaseURL) {
    process.env.BASE_URL = relayBaseURL;
  }

  logger.info(
    {
      relayMode,
      routedViaUtun,
      defaultRouteInterface: defaultRouteInterface || '(unknown)',
      relayWillApplyByDefault: applyRelayBaseURL
    },
    'Container networking mode detected'
  );
  logger.info(
    {
      provider,
      relayBaseURL: applyRelayBaseURL ? relayBaseURL : '(not applied)',
      mode: relayMode,
      previousBaseURL: previousBaseURL || '(none)',
      webBrokerURL: relayInfo.webBrokerURL
    },
    'Configured relay and web broker environment for NanoClawHost'
  );
}

async function waitForHostReady(timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const health = await hostHealth();
      if (health.ok) return;
    } catch {
      // Keep waiting for host startup.
    }
    await sleep(300);
  }
  throw new Error(`Timed out waiting for NanoClawHost readiness (${timeoutMs}ms)`);
}

async function ensureHostRunning(): Promise<void> {
  try {
    const health = await hostHealth();
    if (health.ok) {
      logger.info({ socket: HOST_SOCKET_PATH }, 'NanoClawHost already running');
      return;
    }
  } catch {
    // Host not running yet.
  }

  if (!HOST_AUTOSTART) {
    throw new Error(`NanoClawHost is not reachable at ${HOST_SOCKET_PATH} and autostart is disabled`);
  }

  const args = ['run', 'nanoclaw-host', '--socket-path', HOST_SOCKET_PATH, '--project-root', process.cwd()];
  logger.info({ cmd: `swift ${args.join(' ')}` }, 'Starting NanoClawHost');
  hostProcess = spawn('swift', args, {
    stdio: ['ignore', 'pipe', 'pipe'],
    cwd: process.cwd(),
    env: process.env
  });

  hostProcess.stdout?.on('data', (data) => {
    logger.info({ host: 'stdout' }, data.toString().trim());
  });
  hostProcess.stderr?.on('data', (data) => {
    logger.info({ host: 'stderr' }, data.toString().trim());
  });
  hostProcess.on('exit', (code, signal) => {
    logger.warn({ code, signal }, 'NanoClawHost process exited');
    hostProcess = null;
  });

  await waitForHostReady(HOST_STARTUP_TIMEOUT_MS);
  logger.info('NanoClawHost ready');
}

function shouldTrigger(text: string, isDirect: boolean): { triggered: boolean; prompt: string } {
  if (isDirect) {
    return { triggered: true, prompt: text.trim() };
  }
  const match = text.match(TRIGGER_PATTERN);
  if (!match) return { triggered: false, prompt: '' };
  return { triggered: true, prompt: text.slice(match[0].length).trim() };
}

async function forwardInboundEvent(event: HostInboundEvent): Promise<void> {
  await postInboundEvent(event);
}

async function startOutboundLoop(
  channel: 'whatsapp',
  deliver: (chatJid: string, text: string) => Promise<void>
): Promise<void> {
  if (outboundLoopStarted[channel]) return;
  outboundLoopStarted[channel] = true;

  const loop = async () => {
    while (!shuttingDown) {
      try {
        const outbound = await claimOutbound(channel, 10);
        if (outbound.length > 0) {
          logger.info({ channel, count: outbound.length }, 'Claimed outbound messages');
        }

        const delivered: string[] = [];
        for (const msg of outbound) {
          try {
            await deliver(msg.chat_jid, msg.text);
            delivered.push(msg.id);
          } catch (error) {
            logger.error({ error, channel, id: msg.id }, 'Failed to deliver outbound message');
          }
        }

        if (delivered.length > 0) {
          await ackOutbound(delivered);
        }
      } catch (error) {
        logger.error({ error, channel }, 'Outbound loop error');
      }

      await sleep(HOST_OUTBOUND_POLL_INTERVAL_MS);
    }
  };

  void loop();
}

function extractWhatsAppText(msg: any): string {
  return (
    msg.message?.conversation ||
    msg.message?.extendedTextMessage?.text ||
    msg.message?.imageMessage?.caption ||
    msg.message?.videoMessage?.caption ||
    ''
  );
}

async function connectWhatsApp(): Promise<void> {
  if (whatsappConnecting) return;
  whatsappConnecting = true;

  try {
    const baileys = await import('@whiskeysockets/baileys');
    const makeWASocket = baileys.default;
    const { useMultiFileAuthState, DisconnectReason, makeCacheableSignalKeyStore } = baileys;

    const authDir = path.join(STORE_DIR, 'auth');
    fs.mkdirSync(authDir, { recursive: true });
    const { state, saveCreds } = await useMultiFileAuthState(authDir);

    const client = makeWASocket({
      auth: { creds: state.creds, keys: makeCacheableSignalKeyStore(state.keys, logger) },
      printQRInTerminal: false,
      logger,
      browser: ['NanoClaw', 'Chrome', '2.0.0']
    });

    sock = client;
    client.ev.on('creds.update', saveCreds);

    client.ev.on('connection.update', async (update) => {
      const { connection, lastDisconnect, qr } = update;
      if (qr) {
        logger.error('WhatsApp authentication required. Run: npm run auth');
      }

      if (connection === 'open') {
        logger.info('Connected to WhatsApp');
        await startOutboundLoop('whatsapp', async (chatJid, text) => {
          if (!sock) throw new Error('WhatsApp socket not ready');
          await sock.sendMessage(chatJid, { text });
        });
        return;
      }

      if (connection === 'close') {
        const reason = (lastDisconnect?.error as any)?.output?.statusCode;
        const shouldReconnect = reason !== DisconnectReason.loggedOut;
        logger.warn({ reason, shouldReconnect }, 'WhatsApp connection closed');
        sock = null;
        if (shouldReconnect && !shuttingDown) {
          setTimeout(() => {
            void connectWhatsApp();
          }, 1500);
        }
      }
    });

    client.ev.on('messages.upsert', ({ messages }) => {
      for (const msg of messages) {
        if (!msg.message || !msg.key?.remoteJid) continue;
        if (msg.key.fromMe) continue;

        const chatJid = msg.key.remoteJid;
        const text = extractWhatsAppText(msg).trim();
        if (!text) continue;
        if (text.startsWith(`${ASSISTANT_NAME}:`)) continue;

        const isDirect = !chatJid.endsWith('@g.us');
        const trigger = shouldTrigger(text, isDirect);
        if (!trigger.triggered || !trigger.prompt) continue;

        const timestamp = new Date(Number(msg.messageTimestamp || Date.now() / 1000) * 1000).toISOString();
        const sender = msg.key.participant || msg.key.remoteJid || 'unknown';
        const senderName = msg.pushName || sender.split('@')[0] || 'unknown';
        const messageId = msg.key.id || `${Date.now()}`;

        const inbound: HostInboundEvent = {
          channel: 'whatsapp',
          chat_jid: chatJid,
          sender,
          sender_name: senderName,
          content: trigger.prompt,
          timestamp,
          message_id: messageId,
          is_direct: isDirect
        };

        void forwardInboundEvent(inbound).catch((error) => {
          logger.error({ error, chatJid }, 'Failed to forward WhatsApp inbound event');
        });
      }
    });
  } finally {
    whatsappConnecting = false;
  }
}

async function main(): Promise<void> {
  ensureContainerSystemRunning();
  await ensureRelayEnvironmentConfigured();
  await ensureHostRunning();
  logger.info('Telegram inbound/outbound delivery is handled by Swift host transport');

  if (WHATSAPP_ENABLED) {
    await connectWhatsApp();
  } else {
    logger.warn('WHATSAPP_ENABLED=0, skipping WhatsApp startup');
  }

  logger.info('NanoClaw adapters running');
}

async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info('Shutting down NanoClaw adapters');

  if (sock) {
    try {
      await sock.logout();
    } catch {
      // ignore
    }
    sock = null;
  }

  if (hostProcess) {
    hostProcess.kill('SIGTERM');
    hostProcess = null;
  }

  if (relayStarted) {
    await stopHostRelay();
    relayStarted = false;
  }
}

process.on('SIGINT', async () => {
  await shutdown();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  await shutdown();
  process.exit(0);
});

main().catch(async (error) => {
  logger.error({ error }, 'Failed to start NanoClaw adapters');
  await shutdown();
  process.exit(1);
});
