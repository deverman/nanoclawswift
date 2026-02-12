import path from 'path';

export const ASSISTANT_NAME = process.env.ASSISTANT_NAME || 'Andy';
export const POLL_INTERVAL = 2000;
export const SCHEDULER_POLL_INTERVAL = 60000;
export const WHATSAPP_ENABLED = process.env.WHATSAPP_ENABLED !== '0';
export const HOST_SOCKET_PATH = process.env.NANOCLAW_HOST_SOCKET || '/tmp/nanoclaw-host.sock';
export const HOST_REQUEST_TIMEOUT_MS = parseInt(process.env.NANOCLAW_HOST_REQUEST_TIMEOUT_MS || '15000', 10);
export const HOST_OUTBOUND_POLL_INTERVAL_MS = parseInt(process.env.HOST_OUTBOUND_POLL_INTERVAL_MS || '1000', 10);
export const HOST_AUTOSTART = process.env.NANOCLAW_HOST_AUTOSTART !== '0';
export const HOST_STARTUP_TIMEOUT_MS = parseInt(process.env.NANOCLAW_HOST_STARTUP_TIMEOUT_MS || '45000', 10);

// Absolute paths needed for container mounts
const PROJECT_ROOT = process.cwd();
const HOME_DIR = process.env.HOME || '/Users/user';

// Mount security: allowlist stored OUTSIDE project root, never mounted into containers
export const MOUNT_ALLOWLIST_PATH = path.join(HOME_DIR, '.config', 'nanoclaw', 'mount-allowlist.json');
export const WEB_POLICY_GLOBAL_PATH = path.join(HOME_DIR, '.config', 'nanoclaw', 'web-policy.global.json');
export const STORE_DIR = path.resolve(PROJECT_ROOT, 'store');
export const GROUPS_DIR = path.resolve(PROJECT_ROOT, 'groups');
export const DATA_DIR = path.resolve(PROJECT_ROOT, 'data');
export const MAIN_GROUP_FOLDER = 'main';

export const CONTAINER_IMAGE = process.env.CONTAINER_IMAGE || 'nanoclawswift-agent:slim';
export const CONTAINER_TIMEOUT = parseInt(process.env.CONTAINER_TIMEOUT || '300000', 10);
export const CONTAINER_MAX_OUTPUT_SIZE = parseInt(process.env.CONTAINER_MAX_OUTPUT_SIZE || '10485760', 10); // 10MB default
export const IPC_POLL_INTERVAL = 1000;
export const WEB_BROKER_PORT = parseInt(process.env.WEB_BROKER_PORT || '18081', 10);
export const WEB_FETCH_TIMEOUT_MS = parseInt(process.env.WEB_FETCH_TIMEOUT_MS || '30000', 10);
export const WEB_FETCH_MAX_BYTES = parseInt(process.env.WEB_FETCH_MAX_BYTES || '1048576', 10);

// Telegram Bot Token (optional - if not set, Telegram bot won't start)
export const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';

// Telegram Owner ID (your personal Telegram user ID)
// Get this by messaging @userinfobot on Telegram
// Only this user can chat with the bot directly
export const TELEGRAM_OWNER_ID = process.env.TELEGRAM_OWNER_ID || '';

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export const TRIGGER_PATTERN = new RegExp(`^@${escapeRegex(ASSISTANT_NAME)}\\b`, 'i');

// Timezone for scheduled tasks (cron expressions, etc.)
// Uses system timezone by default
export const TIMEZONE = process.env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone;
