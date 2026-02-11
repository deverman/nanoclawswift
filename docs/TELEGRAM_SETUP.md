# Telegram Setup Guide (Direct Messages)

This guide sets up Telegram as a **direct messaging** channel - you chat 1-on-1 with your bot, no groups needed!

## Why Direct Messages?

- ✅ **No groups required** - Just DM the bot directly
- ✅ **No @Andy trigger** - Just type your message in the private chat
- ✅ **More private** - Your conversations stay between you and the bot
- ✅ **Faster** - No need to mention the bot in a group

## Quick Setup (2 minutes)

### 1. Create a Telegram Bot

1. Open Telegram and message **@BotFather**
2. Send: `/newbot`
3. Choose a name (e.g., "My NanoClaw")
4. Choose a username (must end in `bot`, e.g., `my_nanoclaw_bot`)
5. **Save the token** BotFather gives you:
   ```
   123456789:ABCdefGHIjklMNOpqrSTUvwxyz
   ```

### 2. Get Your Telegram User ID

1. Message **@userinfobot** on Telegram
2. It will reply with your ID (e.g., `123456789`)
3. **Save this number**

### 3. Set Environment Variables

Add to your `~/.zshenv` or `~/.bash_profile`:

```bash
export TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrSTUvwxyz"
export TELEGRAM_OWNER_ID="123456789"
```

Reload:
```bash
source ~/.zshenv
```

### 4. Run NanoClaw

```bash
npm run dev
```

### 5. Start Chatting

1. Message your bot on Telegram
2. Send `/start`
3. Just type any message - the bot responds immediately!
   ```
   Hello!
   What is 2+2?
   Write a Python script to sort a list
   ```

No `@Andy` needed in direct messages!

---

## How It Works

**Direct Chat Mode:**
```
You → Telegram Bot → Swift Agent → Response
      (private DM)    (Apple Container)
```

**Security:**
- Only your Telegram user ID (TELEGRAM_OWNER_ID) can chat with the bot
- Creates folder: `groups/telegram-direct/`
- Uses same Swift agent in Apple containers
- Same isolated memory (CLAUDE.md) as WhatsApp groups

**Commands:**
- `/start` - Welcome message
- `/help` - Show available commands
- `/status` - Check bot status
- `/new` - Reset conversation (clear session)

**Plus any message** - Just type and the bot responds!

---

## Optional: Groups Still Work

If you want the bot in a Telegram **group** (so others can use it too):

1. Add the bot to a group
2. Register it manually in `data/registered_groups.json`:
   ```json
   {
     "groups": {
       "telegram_-123456789@g.us": {
         "name": "My Group",
         "folder": "telegram-group",
         "isMain": false
       }
     }
   }
   ```
   (Get group ID by adding @RawDataBot to the group)

3. In groups, use `@Andy` trigger:
   ```
   @Andy summarize this
   ```

---

## Troubleshooting

**"Bot not responding"**
```bash
# Check environment variables
echo $TELEGRAM_BOT_TOKEN
echo $TELEGRAM_OWNER_ID

# Both should show your values
```

**"Unauthorized direct message blocked"**
- Your TELEGRAM_OWNER_ID doesn't match your Telegram user ID
- Message @userinfobot again to confirm your ID

**"Bot says 'this bot is private'"**
- You haven't set TELEGRAM_OWNER_ID
- Or the ID is wrong

**"How do I allow multiple users?"**
Currently only supports one owner. For multiple users, create a Telegram group instead.

---

## Architecture

```
┌─ Telegram DM ──┐
│  Private Chat  │  (no @Andy needed)
└───────┬────────┘
        │
        ▼
┌──────────────────┐
│  Telegram Bot    │  (grammY)
│  Checks owner ID │
└───────┬──────────┘
        │
        ▼
┌──────────────────┐
│  Auto-creates:   │
│  telegram-direct │
│  folder + CLAUDE.md
└───────┬──────────┘
        │
        ▼
┌──────────────────┐
│  Swift Agent     │  (Apple Container)
│  Same as WhatsApp│
└──────────────────┘
```

Your direct messages and WhatsApp groups share the same agent but have **isolated memory** (separate CLAUDE.md files).
