# Handover Notes

Updated: 2026-02-17

## Runtime Ownership

- Primary runtime: Swift host + Swift container agent.
- Channel in scope: Telegram only.
- Startup/stop control: `nanoclaw-hostctl`.
- Preferred runtime update workflow: `nanoclaw-devctl rebuild-and-restart slim`.

## Standard Operations

Start host (foreground):

```bash
swift run nanoclaw-devctl rebuild-and-restart slim --foreground
```

Start host (background):

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
```

Stop host:

```bash
swift run nanoclaw-hostctl stop
```

Health check:

```bash
swift run nanoclaw-hostctl status
```

## After Code Changes

1. If `Sources/NanoClawAgent/**` or container/runtime package files changed:
   - rebuild image: `swift run nanoclaw-devctl build-agent-image slim`
2. If `Sources/NanoClawHost/**` changed:
   - restart host: `swift run nanoclaw-hostctl restart`
3. For full end-to-end changes:
   - preferred one-liner: `swift run nanoclaw-devctl rebuild-and-restart slim`

## Required Environment

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_OWNER_ID`
- provider/model env vars and API key(s)

## Log Locations

- host log: `/tmp/nanoclaw-host.log`
- runtime state/db: repository `store/` directory

## Deferred Work

1. Real local MCP server smoke validation in runtime.
2. Wax memory backend decision packet.
3. Multi-channel scope remains deferred.
