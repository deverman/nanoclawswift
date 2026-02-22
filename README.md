# NanoClawSwift

Run a personal AI agent on your Mac with Apple Containers isolation, Telegram control, and MCP tool and Skills access.

NanoClawSwift is designed for Mac users who want OpenClaw-style autonomy with a setup that feels local, private, and operationally safe.

## Why NanoClawSwift

- Swift-native runtime with a Mac-first operational model.
- Safety by default: agent execution is isolated in Apple Containers while the host stays observable and in control.
- Telegram as your control surface: run your agent from your phone with low friction.
- MCP-native extensibility: connect your existing MCP servers without writing adapter glue.
- Production-minded tooling: built-in lifecycle commands for build, restart, and diagnostics.

## Core Capabilities

| Area | What you get |
| --- | --- |
| Channels | Telegram inbound/outbound messaging (polling) |
| Runtime | Swift host (`nanoclaw-host`) + Swift container agent (`nanoclaw-agent`) |
| Reliability | Typing heartbeat, message splitting for Telegram limits, scheduler + task state |
| Memory | `read_memory` / `write_memory` in `chat` and `global` scopes |
| Skills | `list_skills`, `activate_skill`, `deactivate_skill`, `sync_skills` |
| Planning/Parity Tools | `todo_read`, `todo_write`, `sub_agent`, `get_task_history`, `export_chat` |
| Attachments | `send_message` supports text, captions, and file attachments |
| MCP | Automatic MCP server bootstrap from `.mcp.json` with host/container runtimes |
| MCP Operations | `mcp_reload` and `mcp_host_cli` for live reload and direct server CLI workflows |

## Prerequisites

- macOS 26
- Swift 6.2.3
- Apple `container` CLI installed and working ([GitHub](https://github.com/apple/container))
- Telegram bot token and Telegram owner/user ID
- At least one model provider API key (for example Moonshot/Kimi)

## Install and Get Started (Mac)

Runtime state is stored in `~/.config/clawclaw` by default:
- `~/.config/clawclaw/groups`
- `~/.config/clawclaw/store`
- `~/.config/clawclaw/data`

### 1) Clone and enter repo

```bash
git clone -b swift-agent https://github.com/deverman/nanoclawswift
cd nanoclawswift
```

### 2) Configure environment

Set these in your shell profile (`~/.zshrc`) or your current session:

```bash
export TELEGRAM_BOT_TOKEN="<bot-token>"
export TELEGRAM_OWNER_ID="<numeric-user-id>"

export MODEL_PROVIDER="kimi"
export MODEL_NAME="kimi-k2.5"
export MOONSHOT_API_KEY="<api-key>"

# Optional reliability/fallback controls
export NANOCLAW_PROVIDER_RPM_LIMIT="18"
export NANOCLAW_FALLBACK_PROVIDER="openai"
export NANOCLAW_FALLBACK_MODEL="gpt-4.1-mini"
export NANOCLAW_FALLBACK_API_KEY="<fallback-key>"
```

### 3) Validate build

```bash
swift test
```

### 4) Start Apple Container system service

```bash
container system start
```

If image builds fail with an XPC connection error, run:

```bash
container system start
```

### 5) Build agent image and start runtime

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
```

Run foreground mode if you want live logs while starting:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim --foreground
```

### 6) Check runtime health

```bash
swift run nanoclaw-hostctl status
```

### 7) Send first Telegram command

Message your bot:

```text
Please list tasks
```

If you need logs:

```bash
tail -n 200 /tmp/nanoclaw-host.log
```

## Executable Targets (`Package.swift`)

- `nanoclaw-agent`: container-side agent runtime that selects/executes tools and agents.
- `nanoclaw-host`: host runtime (Telegram I/O, scheduler, persistence, container lifecycle).
- `nanoclaw-hostctl`: host lifecycle controller (`start`, `stop`, `restart`, `status`, diagnostics).
- `nanoclaw-devctl`: developer/operator workflows (build image, rebuild/restart, soak verification).
- `session-summary`: utility CLI for session summary workflows.

Run any executable with:

```bash
swift run <executable-name> --help
```

Examples:

```bash
swift run nanoclaw-hostctl --help
swift run nanoclaw-devctl --help
```
## CLI Quick Reference

### `nanoclaw-devctl`

```bash
swift run nanoclaw-devctl --help
```

Main workflows:
- `build-agent-image`: build Linux agent + package container image.
- `rebuild-and-restart`: serialized rebuild + host restart for end-to-end updates.
- `download-linux-binary`: fetch prebuilt Linux `nanoclaw-agent` from releases.
- `verify-telegram-soak`: check recent Telegram handling invariants.

### `nanoclaw-hostctl`

```bash
swift run nanoclaw-hostctl --help
```

Main workflows:
- `start`, `stop`, `restart`, `status`
- `scheduler-diagnostics`

## How To: Use Skills

### Inspect available skills from chat

In Telegram, ask the agent:

```text
Please use list_skills
```

### Activate a skill

```text
Please activate_skill for <skill-name>
```

### Deactivate a skill

```text
Please deactivate_skill for <skill-name>
```

### Re-sync skill discovery roots

```text
Please run sync_skills
```

Default skill roots include:
- `CODEX_HOME/skills`
- `~/.codex/skills`
- `~/.claude/skills`

## How To: Connect MCP Servers and Use MCP CLI

### 1) Add `.mcp.json`

Place `.mcp.json` in one of:
- `/workspace/group/.mcp.json`
- `/workspace/project/.mcp.json`
- or point to a custom file with `NANOCLAW_MCP_CONFIG_PATH`

Generic example:

```json
{
  "mcpServers": {
    "myserver": {
      "runtime": "host",
      "transport": "stdio",
      "command": "/absolute/path/to/server-binary",
      "args": ["serve"]
    }
  }
}
```

Runtime modes:
- `runtime: "container"` + `transport: "stdio"`: server runs inside container runtime.
- `runtime: "host"` + `transport: "stdio"`: server runs on macOS host via host MCP bridge.

### 2) Reload MCP without full rebuild

From Telegram:

```text
Please run mcp_reload
```

### 3) Verify MCP status in chat

```text
Please show mcp status
```

### 4) Call MCP server CLI through NanoClaw

Use `mcp_host_cli` from chat when you want direct, token-cheap server calls:

```text
Please use mcp_host_cli server <server-id> args <command> <arg1> <arg2>
```

Example:

```text
Please use mcp_host_cli server myserver args list-tools
```

## Operational Notes

- Rebuild container image when changes touch:
  - `Sources/NanoClawAgent/**`
  - `container/**`
  - `Package.swift` or `Package.resolved`
- Restart host when changes touch:
  - `Sources/NanoClawHost/**`
- For end-to-end behavior changes, use:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
```

## Project Docs

- Implementation plan: `IMPLEMENTATION_PLAN.md`
- Production checklist: `PRODUCTION_READINESS.md`
- Telegram setup detail: `docs/TELEGRAM_SETUP.md`
- Security model: `docs/SECURITY.md`
- MCP operations: `docs/MCP_OPERATIONS.md`
- Technical spec: `docs/SPEC.md`
- Wax decision packet: `docs/WAX_DECISION.md`

## Explicitly Deferred

- Multi-channel runtime expansion
- Wax as production memory backend (adapter seam exists; decision packet pending)
