# Telegram Setup (Swift Host Runtime)

Updated: 2026-02-17

## 1) Create Bot and Owner ID

1. Create a bot via `@BotFather` and copy the token.
2. Get your numeric Telegram user ID (for example with `@userinfobot`).

## 2) Export Required Environment Variables

```bash
export TELEGRAM_BOT_TOKEN="<bot-token>"
export TELEGRAM_OWNER_ID="<numeric-user-id>"

export MODEL_PROVIDER="kimi"
export MODEL_NAME="kimi-k2.5"
export MOONSHOT_API_KEY="<api-key>"
```

Optional:

```bash
export NANOCLAW_PROVIDER_RPM_LIMIT="18"
export NANOCLAW_FALLBACK_PROVIDER="openai"
export NANOCLAW_FALLBACK_MODEL="gpt-4.1-mini"
export NANOCLAW_FALLBACK_API_KEY="<fallback-key>"
```

## 3) Build and Start

```bash
swift test
swift run nanoclaw-devctl rebuild-and-restart slim --foreground
```

If you prefer background mode:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
swift run nanoclaw-hostctl status
```

## 4) Smoke Test

From Telegram DM to your bot:

- `/tasks`
- `/skills`

You should receive a response within seconds.

## 5) Troubleshooting

### No response

1. Check health:

```bash
swift run nanoclaw-hostctl status
```

2. Check logs:

```bash
tail -n 200 /tmp/nanoclaw-host.log
```

3. Verify `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_ID` are set in the host process environment.

### Unauthorized DM

- `TELEGRAM_OWNER_ID` is missing or incorrect.
- Re-check your numeric Telegram user ID and restart host.

### Repeated 429 rate-limit failures

- Reduce request burst volume.
- Set `NANOCLAW_PROVIDER_RPM_LIMIT` to stay below provider limits.
- Configure fallback provider variables if needed.

## Notes

- Telegram direct message mode is owner-gated by `TELEGRAM_OWNER_ID`.
- Scheduled tasks run when host is running; missed tasks are catch-up queued on startup.
- Telegram is the only active channel in this phase.
