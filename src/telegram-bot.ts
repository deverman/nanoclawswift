import { Bot, Context } from 'grammy';
import pino from 'pino';
import dns from 'dns';
import https from 'https';
import { type LookupFunction } from 'net';
import {
  TELEGRAM_BOT_TOKEN,
  TELEGRAM_OWNER_ID,
  ASSISTANT_NAME,
  TRIGGER_PATTERN
} from './config.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

const telegramIpv4Lookup: LookupFunction = (hostname, options, callback) => {
  const normalizedOptions =
    typeof options === 'number' ? { family: options } : (options || {});
  const wantsAll = !!normalizedOptions.all;

  dns.lookup(hostname, { ...normalizedOptions, family: 4, all: false }, (err, address, family) => {
    if (err) {
      (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
        err,
        '',
        0
      );
      return;
    }

    if (wantsAll) {
      (callback as (err: NodeJS.ErrnoException | null, addresses: dns.LookupAddress[]) => void)(
        null,
        [{ address, family }]
      );
      return;
    }

    (callback as (err: NodeJS.ErrnoException | null, address: string, family: number) => void)(
      null,
      address,
      family
    );
  });
};

const telegramHttpsAgent = new https.Agent({
  keepAlive: true,
  lookup: telegramIpv4Lookup
});

export interface TelegramInboundEvent {
  channel: 'telegram';
  chat_jid: string;
  sender: string;
  sender_name: string;
  content: string;
  timestamp: string;
  message_id: string;
  is_direct: boolean;
}

export type TelegramInboundHandler = (event: TelegramInboundEvent) => Promise<void>;

function isOwner(userId: number): boolean {
  if (!TELEGRAM_OWNER_ID) return true;
  return userId.toString() === TELEGRAM_OWNER_ID;
}

function shouldTrigger(text: string, isDirect: boolean): { triggered: boolean; prompt: string } {
  if (isDirect) {
    return { triggered: true, prompt: text.trim() };
  }
  const match = text.match(TRIGGER_PATTERN);
  if (!match) return { triggered: false, prompt: '' };
  return { triggered: true, prompt: text.slice(match[0].length).trim() };
}

function buildChatJid(chatId: number, isDirect: boolean): string {
  return isDirect ? `telegram_${chatId}@direct` : `telegram_${chatId}@g.us`;
}

export async function startTelegramBot(onInbound: TelegramInboundHandler): Promise<Bot<Context> | null> {
  if (!TELEGRAM_BOT_TOKEN) {
    logger.info('TELEGRAM_BOT_TOKEN not set, skipping Telegram bot');
    return null;
  }

  const bot = new Bot<Context>(TELEGRAM_BOT_TOKEN, {
    client: {
      baseFetchConfig: { compress: true, agent: telegramHttpsAgent }
    }
  });

  bot.on('message:text', async (ctx) => {
    const chatId = ctx.chat.id;
    const userId = ctx.from?.id ?? 0;
    const chatType = ctx.chat.type;
    const isDirect = chatType === 'private';
    const rawText = ctx.message.text || '';
    const senderName = ctx.from?.username || ctx.from?.first_name || 'unknown';
    const sender = ctx.from?.username || `telegram_${userId}`;

    if (isDirect && !isOwner(userId)) {
      await ctx.reply('Sorry, this bot is private. Only the owner can use it.');
      return;
    }

    const trigger = shouldTrigger(rawText, isDirect);
    if (!trigger.triggered || !trigger.prompt) return;

    const event: TelegramInboundEvent = {
      channel: 'telegram',
      chat_jid: buildChatJid(chatId, isDirect),
      sender,
      sender_name: senderName,
      content: trigger.prompt,
      timestamp: new Date().toISOString(),
      message_id: String(ctx.message.message_id),
      is_direct: isDirect
    };

    try {
      await onInbound(event);
    } catch (error) {
      logger.error({ error, chatId }, 'Failed to forward Telegram inbound event');
      await ctx.reply(`${ASSISTANT_NAME}: I hit a host routing error. Please retry.`);
    }
  });

  bot.command('start', async (ctx) => {
    await ctx.reply(
      `Hello! I'm ${ASSISTANT_NAME}.\n` +
      `${ctx.chat.type === 'private' ? 'Send a message directly.' : `Use @${ASSISTANT_NAME} in group chats.`}`
    );
  });

  bot.command('help', async (ctx) => {
    await ctx.reply(
      `Commands:\n` +
      `/start\n` +
      `/help\n\n` +
      `I route your messages through the NanoClaw host orchestrator.`
    );
  });

  bot.catch((err) => {
    logger.error({ err }, 'Telegram bot error');
  });

  // grammY's bot.start() is a long-running polling loop. Do not await it here,
  // or caller startup will block and outbound delivery loops won't start.
  void bot.start({
    onStart: (botInfo) => {
      logger.info({ username: botInfo.username }, 'Telegram bot started');
      logger.info('Direct messages: ' + (TELEGRAM_OWNER_ID ? 'Owner only' : 'Any user'));
    }
  });

  return bot;
}

export async function stopTelegramBot(bot: Bot<Context> | null): Promise<void> {
  if (!bot) return;
  await bot.stop();
  logger.info('Telegram bot stopped');
}

export async function sendTelegramMessage(bot: Bot<Context>, chatJid: string, text: string): Promise<void> {
  const match = chatJid.match(/^telegram_(-?\d+)@/);
  if (!match) {
    logger.warn({ chatJid }, 'Invalid Telegram chat JID for outbound message');
    return;
  }
  const chatId = parseInt(match[1], 10);
  if (Number.isNaN(chatId)) {
    logger.warn({ chatJid }, 'Invalid Telegram chat ID in JID');
    return;
  }
  await bot.api.sendMessage(chatId, text);
}
