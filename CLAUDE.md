# NanoClawSwift

Swift-first Telegram assistant runtime.

## Runtime Truth

- Host runtime: `nanoclaw-host` (Swift)
- Agent runtime: `nanoclaw-agent` (Swift, Apple Containers)
- Channel scope: Telegram-first
- MCP/runtime orchestration: Swift implementation

## Development Commands

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
swift run nanoclaw-hostctl status
swift test
```

## Memory Files

- `groups/<group>/CLAUDE.md` files are group memory/instruction context loaded into the agent.
- Keep these files focused on durable user/workflow context.
- Do not store legacy runtime instructions here.
