#!/usr/bin/env node
/**
 * Register Telegram group for NanoClaw
 * Interactive script to set up Telegram chat
 */

import fs from 'fs';
import path from 'path';
import readline from 'readline';

const DATA_DIR = './data';
const GROUPS_DIR = './groups';

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(prompt: string): Promise<string> {
  return new Promise(resolve => {
    rl.question(prompt, resolve);
  });
}

async function main() {
  console.log('=== NanoClaw Telegram Registration ===\n');
  
  // Check if TELEGRAM_BOT_TOKEN is set
  if (!process.env.TELEGRAM_BOT_TOKEN) {
    console.log('❌ TELEGRAM_BOT_TOKEN not set!');
    console.log('\nTo get a token:');
    console.log('1. Message @BotFather on Telegram');
    console.log('2. Send /newbot');
    console.log('3. Follow instructions to create a bot');
    console.log('4. Copy the token and add to your environment:');
    console.log('   export TELEGRAM_BOT_TOKEN="your_token_here"');
    process.exit(1);
  }
  
  console.log('✅ TELEGRAM_BOT_TOKEN is set');
  console.log('\nTo find your Telegram chat ID:');
  console.log('1. Message @userinfobot on Telegram');
  console.log('2. It will reply with your chat ID (e.g., 123456789)');
  console.log('');
  
  const chatId = await question('Enter your Telegram chat ID: ');
  const folderName = await question('Enter folder name (default: telegram-main): ') || 'telegram-main';
  const isMain = (await question('Is this the main/admin channel? (y/N): ')).toLowerCase() === 'y';
  
  const telegramJid = `telegram_${chatId}@g.us`;
  
  // Load existing groups
  const groupsPath = path.join(DATA_DIR, 'registered_groups.json');
  let groups: any = { groups: {} };
  if (fs.existsSync(groupsPath)) {
    groups = JSON.parse(fs.readFileSync(groupsPath, 'utf-8'));
  }
  
  // Add new group
  groups.groups[telegramJid] = {
    name: folderName,
    folder: folderName,
    isMain
  };
  
  // Save
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(groupsPath, JSON.stringify(groups, null, 2));
  
  // Create folder
  const groupDir = path.join(GROUPS_DIR, folderName);
  fs.mkdirSync(path.join(groupDir, 'logs'), { recursive: true });
  
  console.log('\n✅ Telegram group registered!');
  console.log(`\nDetails:`);
  console.log(`  Chat ID: ${chatId}`);
  console.log(`  Folder: ${folderName}`);
  console.log(`  Main: ${isMain ? 'Yes' : 'No'}`);
  console.log(`\nNow run: npm run dev`);
  console.log(`Then message your bot: @Andy hello`);
  
  rl.close();
}

main().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
