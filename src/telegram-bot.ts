/**
 * Telegram Bot Integration for NanoClaw
 * Uses grammY (same as OpenClaw)
 * 
 * Supports:
 * - Direct messages (DMs) from owner (TELEGRAM_OWNER_ID)
 * - Group mentions (@Andy) for registered groups
 */

import { Bot, Context, SessionFlavor, session } from 'grammy';
import pino from 'pino';
import path from 'path';
import fs from 'fs';
import dns from 'dns';
import https from 'https';
import { type LookupFunction } from 'net';
import {
  TELEGRAM_BOT_TOKEN,
  TELEGRAM_OWNER_ID,
  DATA_DIR,
  ASSISTANT_NAME,
  TRIGGER_PATTERN,
  MAIN_GROUP_FOLDER,
  GROUPS_DIR
} from './config.js';
import { RegisteredGroup } from './types.js';
import { runContainerAgent, writeTasksSnapshot, writeGroupsSnapshot } from './container-runner.js';
import { getAllTasks, getAllChats } from './db.js';
import { loadJson, saveJson } from './utils.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: { target: 'pino-pretty', options: { colorize: true } }
});

// Tailscale exit-node paths can prefer IPv6 routes that intermittently time out
// for Telegram API from Node HTTP clients. Force IPv4 DNS results for this bot.
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

// Session storage for Telegram
interface TelegramSession {
  sessionId?: string;
  lastActivity: string;
}

export interface MyContext extends Context, SessionFlavor<TelegramSession> {}

// Track registered groups (shared with WhatsApp router)
let registeredGroups: Record<string, RegisteredGroup> = {};
let telegramSessions: Record<string, string> = {}; // chatId -> sessionId

const DIRECT_CHAT_FOLDER = 'telegram-direct';

function loadState(): void {
  registeredGroups = loadJson(path.join(DATA_DIR, 'registered_groups.json'), {});
  telegramSessions = loadJson(path.join(DATA_DIR, 'telegram_sessions.json'), {});
  logger.info({ groupCount: Object.keys(registeredGroups).length }, 'Telegram bot state loaded');
}

function saveState(): void {
  saveJson(path.join(DATA_DIR, 'telegram_sessions.json'), telegramSessions);
}

function getAvailableGroups(): Array<{ jid: string; name: string; lastActivity: string; isRegistered: boolean }> {
  const chats = getAllChats();
  return chats.map(chat => ({
    jid: chat.jid,
    name: chat.name,
    lastActivity: chat.last_message_time,
    isRegistered: chat.jid in registeredGroups
  }));
}

/**
 * Check if message triggers the agent
 * For DMs: always triggers (no @Andy needed in private chat)
 * For groups: requires @Andy trigger
 */
function shouldTrigger(text: string, isDirectMessage: boolean): { triggered: boolean; prompt: string } {
  // In direct messages, always respond (no trigger needed)
  if (isDirectMessage) {
    return { triggered: true, prompt: text };
  }
  
  // In groups, require @Andy trigger
  const match = text.match(TRIGGER_PATTERN);
  if (match) {
    return { triggered: true, prompt: text.slice(match[0].length).trim() };
  }
  return { triggered: false, prompt: text };
}

/**
 * Ensure direct chat is registered
 * Creates folder and registration for owner's DM
 */
function ensureDirectChatRegistered(chatId: number, username: string): { group: RegisteredGroup; chatJid: string } {
  const telegramJid = `telegram_${chatId}@direct`;
  
  // Check if already registered
  if (telegramJid in registeredGroups) {
    return { group: registeredGroups[telegramJid], chatJid: telegramJid };
  }
  
  // Auto-register direct chat
  const group: RegisteredGroup = {
    name: `Telegram Direct (${username})`,
    folder: DIRECT_CHAT_FOLDER,
    trigger: `@${ASSISTANT_NAME}`,
    added_at: new Date().toISOString()
  };
  
  registeredGroups[telegramJid] = group;
  saveJson(path.join(DATA_DIR, 'registered_groups.json'), registeredGroups);
  
  // Create folder structure
  const groupDir = path.join(GROUPS_DIR, DIRECT_CHAT_FOLDER);
  fs.mkdirSync(path.join(groupDir, 'logs'), { recursive: true });
  
  // Create CLAUDE.md if it doesn't exist
  const claudeMdPath = path.join(groupDir, 'CLAUDE.md');
  if (!fs.existsSync(claudeMdPath)) {
    fs.writeFileSync(claudeMdPath, `# Telegram Direct Chat Memory\n\nThis is your private direct message conversation with the assistant.\n`);
  }
  
  logger.info({ chatId, folder: DIRECT_CHAT_FOLDER }, 'Auto-registered Telegram direct chat');
  
  return { group, chatJid: telegramJid };
}

/**
 * Find registered group by Telegram chat ID
 */
function findRegisteredGroup(chatId: number): { group: RegisteredGroup; chatJid: string } | null {
  // Check for direct chat registration
  const directJid = `telegram_${chatId}@direct`;
  if (directJid in registeredGroups) {
    return { group: registeredGroups[directJid], chatJid: directJid };
  }
  
  // Check for group registration
  const groupJid = `telegram_${chatId}@g.us`;
  if (groupJid in registeredGroups) {
    return { group: registeredGroups[groupJid], chatJid: groupJid };
  }
  
  return null;
}

/**
 * Run the agent for a Telegram message
 */
async function runAgent(
  group: RegisteredGroup,
  prompt: string,
  chatJid: string,
  ctx: MyContext
): Promise<string | null> {
  const isMain = group.folder === MAIN_GROUP_FOLDER || group.folder === DIRECT_CHAT_FOLDER;
  const sessionId = telegramSessions[chatJid];

  // Update tasks snapshot for container to read
  const tasks = getAllTasks();
  writeTasksSnapshot(group.folder, isMain, tasks.map(t => ({
    id: t.id,
    groupFolder: t.group_folder,
    prompt: t.prompt,
    schedule_type: t.schedule_type,
    schedule_value: t.schedule_value,
    status: t.status,
    next_run: t.next_run
  })));

  // Update available groups snapshot
  const availableGroups = getAvailableGroups();
  writeGroupsSnapshot(group.folder, isMain, availableGroups, new Set(Object.keys(registeredGroups)));

  try {
    const output = await runContainerAgent(group, {
      prompt,
      sessionId,
      groupFolder: group.folder,
      chatJid,
      isMain
    });

    if (output.newSessionId) {
      telegramSessions[chatJid] = output.newSessionId;
      saveState();
    }

    if (output.status === 'error') {
      logger.error({ group: group.name, error: output.error }, 'Telegram container agent error');
      return null;
    }

    return output.result;
  } catch (err) {
    logger.error({ group: group.name, err }, 'Telegram agent error');
    return null;
  }
}

/**
 * Check if user is the owner
 */
function isOwner(userId: number): boolean {
  if (!TELEGRAM_OWNER_ID) {
    // If no owner ID set, allow any user (for easy testing)
    return true;
  }
  return userId.toString() === TELEGRAM_OWNER_ID;
}

/**
 * Start the Telegram bot
 */
export async function startTelegramBot(): Promise<Bot<MyContext> | null> {
  if (!TELEGRAM_BOT_TOKEN) {
    logger.info('TELEGRAM_BOT_TOKEN not set, skipping Telegram bot');
    return null;
  }

  loadState();

  // Use grammY client options to keep keep-alive while pinning Telegram DNS to IPv4.
  // This preserves performance and avoids ETIMEDOUT on some Tailscale exit-node routes.
  const bot = new Bot<MyContext>(TELEGRAM_BOT_TOKEN, {
    client: {
      baseFetchConfig: { compress: true, agent: telegramHttpsAgent }
    }
  });

  // Use session middleware
  bot.use(session({
    initial: (): TelegramSession => ({
      lastActivity: new Date().toISOString()
    })
  }));

  // Handle text messages
  bot.on('message:text', async (ctx) => {
    const chatId = ctx.chat.id;
    const userId = ctx.from?.id;
    const text = ctx.message.text;
    const username = ctx.from?.username || ctx.from?.first_name || 'Unknown';
    const chatType = ctx.chat.type; // 'private', 'group', 'supergroup'
    const isDirectMessage = chatType === 'private';

    logger.debug({ 
      chatId, 
      userId, 
      username, 
      chatType,
      isDirectMessage,
      text: text.slice(0, 50) 
    }, 'Telegram message received');

    // Security: Check if user is owner for direct messages
    if (isDirectMessage && !isOwner(userId || 0)) {
      logger.warn({ userId, username }, 'Unauthorized direct message blocked');
      await ctx.reply('Sorry, this bot is private. Only the owner can use it.');
      return;
    }

    // Handle direct messages (auto-register if owner)
    let registration: { group: RegisteredGroup; chatJid: string } | null = null;
    
    if (isDirectMessage) {
      // Auto-register direct chat for owner
      registration = ensureDirectChatRegistered(chatId, username);
    } else {
      // For groups, check if registered
      registration = findRegisteredGroup(chatId);
      if (!registration) {
        logger.debug({ chatId }, 'Telegram group not registered, ignoring');
        return;
      }
    }

    const { triggered, prompt } = shouldTrigger(text, isDirectMessage);

    if (!triggered) {
      logger.debug({ chatId, text: text.slice(0, 50) }, 'Message does not trigger agent');
      return;
    }

    logger.info({ 
      group: registration.group.name, 
      username,
      isDirectMessage 
    }, 'Processing Telegram message');

    // Show typing indicator
    await ctx.api.sendChatAction(chatId, 'typing');

    // Run agent
    const response = await runAgent(
      registration.group, 
      prompt, 
      registration.chatJid, 
      ctx
    );

    if (response) {
      await ctx.reply(`${ASSISTANT_NAME}: ${response}`);
    }
  });

  // Handle /start command
  bot.command('start', async (ctx) => {
    const isDirectMessage = ctx.chat.type === 'private';
    const userId = ctx.from?.id;
    
    if (isDirectMessage && !isOwner(userId || 0)) {
      await ctx.reply('Sorry, this bot is private. Only the owner can use it.');
      return;
    }
    
    await ctx.reply(
      `Hello! I'm ${ASSISTANT_NAME}, your AI assistant.\n\n` +
      `${isDirectMessage 
        ? 'You can message me directly - no need for @ mentions!' 
        : `To talk to me, start your message with "@${ASSISTANT_NAME}".`
      }\n\n` +
      `Use /help for more commands.`
    );
  });

  // Handle /help command
  bot.command('help', async (ctx) => {
    const isDirectMessage = ctx.chat.type === 'private';
    
    let helpText = `Available commands:\n\n`;
    helpText += `/start - Welcome message\n`;
    helpText += `/help - Show this help\n`;
    helpText += `/status - Check bot status\n`;
    helpText += `/new - Reset conversation\n\n`;
    
    if (isDirectMessage) {
      helpText += `Just send me a message and I'll respond!`;
    } else {
      helpText += `Send "@${ASSISTANT_NAME} <your message>" to talk to me.`;
    }
    
    await ctx.reply(helpText);
  });

  // Handle /status command
  bot.command('status', async (ctx) => {
    const chatId = ctx.chat.id;
    const registration = findRegisteredGroup(chatId);
    
    if (registration) {
      const sessionId = telegramSessions[registration.chatJid];
      await ctx.reply(
        `✅ Bot is active\n` +
        `Group: ${registration.group.name}\n` +
        `Session: ${sessionId ? 'Active' : 'New'}`
      );
    } else {
      await ctx.reply('❌ This chat is not registered.');
    }
  });

  // Handle /new command (reset session)
  bot.command('new', async (ctx) => {
    const chatId = ctx.chat.id;
    const registration = findRegisteredGroup(chatId);
    
    if (registration) {
      delete telegramSessions[registration.chatJid];
      saveState();
      await ctx.reply('🔄 Conversation reset. Starting fresh!');
    } else {
      await ctx.reply('❌ This chat is not registered.');
    }
  });

  // Error handler
  bot.catch((err) => {
    logger.error({ err }, 'Telegram bot error');
  });

  // Start the bot
  await bot.start({
    onStart: (botInfo) => {
      logger.info({ username: botInfo.username }, 'Telegram bot started');
      logger.info('Direct messages: ' + (TELEGRAM_OWNER_ID ? 'Owner only' : 'Any user (set TELEGRAM_OWNER_ID to restrict)'));
    }
  });

  return bot;
}

/**
 * Stop the Telegram bot
 */
export async function stopTelegramBot(bot: Bot<MyContext> | null): Promise<void> {
  if (bot) {
    await bot.stop();
    logger.info('Telegram bot stopped');
  }
}
