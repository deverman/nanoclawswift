# NanoClawSwift

Swift-first personal AI assistant for Telegram, running with host/container isolation on Apple Containers.

## Current Runtime (as of 2026-02-18)

- Swift host runtime (`nanoclaw-host`) and Swift container agent (`nanoclaw-agent`)
- Telegram-only inbound/outbound channel (polling)
- Continuous typing heartbeat with lifecycle cleanup
- Telegram-safe message splitting (4096 limit-aware)
- Skills tools: `list_skills`, `activate_skill`, `deactivate_skill`, `sync_skills`
  - Default roots: `CODEX_HOME/skills`, `~/.codex/skills`, `~/.claude/skills`
- Parity tools: `todo_read`, `todo_write`, `sub_agent`, `get_task_history`, `export_chat`
- Memory tools: `read_memory`, `write_memory` (`chat` and `global` scopes)
- `send_message` supports text, attachments, and captions
- MCP runtime bootstrap from `.mcp.json` on agent startup
- Host MCP bridge for `runtime: "host"` servers in `.mcp.json` (no code changes required per server)
- Generic host MCP CLI tool: `mcp_host_cli` (for token-cheap direct CLI calls)
- MCP reload tool: `mcp_reload` (re-reads `.mcp.json` and reboots host MCP registrations)
- FocusRelay compatibility tools remain available: `focusrelay_inbox_tasks`, `focusrelay_cli`, `focusrelay_bridge_health`
- Multi-channel support is intentionally deferred

## Architecture

```text
Telegram -> Swift Telegram Adapter (host) -> Host Queue/Scheduler/DB -> Container Session -> Swift Agent
```

Host responsibilities:
- Telegram polling and outbound delivery
- Scheduling and task state in SQLite
- Container session lifecycle, watchdog, janitor, startup catch-up
- Optional host relay for provider/network edge cases

Agent responsibilities:
- Route selection (`ToolCallingAgent` vs `PlanAndExecuteAgent`)
- Tool execution with side-effect controls
- Persistent session + memory context
- MCP tool registration/execution

## Prerequisites

- macOS 26
- Swift 6.2.3 toolchain
- Apple `container` CLI installed and working
- Telegram bot token and owner ID
- At least one model provider API key (for example Moonshot/Kimi)

## Configuration

Set environment in your shell (or `.env` for local hostctl loading):

```bash
export TELEGRAM_BOT_TOKEN="<bot-token>"
export TELEGRAM_OWNER_ID="<numeric-user-id>"

export MODEL_PROVIDER="kimi"
export MODEL_NAME="kimi-k2.5"
export MOONSHOT_API_KEY="<api-key>"

# Optional reliability/limits
export NANOCLAW_PROVIDER_RPM_LIMIT="18"
export NANOCLAW_FALLBACK_PROVIDER="openai"
export NANOCLAW_FALLBACK_MODEL="gpt-4.1-mini"
export NANOCLAW_FALLBACK_API_KEY="<fallback-key>"
```

## Build and Run

```bash
swift test
swift run nanoclaw-devctl rebuild-and-restart slim --foreground
```

Background mode:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
swift run nanoclaw-hostctl status
```

Stop host:

```bash
swift run nanoclaw-hostctl stop
```

## Telegram Smoke Test

1. Send a direct Telegram message to your bot: `Please list tasks`
2. Confirm response arrives.
3. Confirm host health:

```bash
swift run nanoclaw-hostctl status
```

4. Check host log if needed:

```bash
tail -n 200 /tmp/nanoclaw-host.log
```

## Memory and Attachment Smoke

- Memory read:
  - `Please use the read_memory tool`
- Memory write:
  - `Please use write_memory with scope chat and mode append`
- Attachment send:
  - Ask the assistant to call `send_message` with `attachment_path` and optional `caption`.

## MCP Setup

Place `.mcp.json` in either:
- `/workspace/group/.mcp.json` (inside container session)
- `/workspace/project/.mcp.json`
- or set `NANOCLAW_MCP_CONFIG_PATH`.

At startup, the agent loads MCP servers and exposes bridged tools with names like `mcp_<server>_<tool>`.

Supported server modes:
- `runtime: "container"` + `transport: "stdio"`: launched in container runtime.
- `runtime: "host"` + `transport: "stdio"`: launched through the Swift host MCP bridge.

Example `.mcp.json`:

```json
{
  "mcpServers": {
    "focusrelay": {
      "runtime": "host",
      "transport": "stdio",
      "command": "/opt/homebrew/bin/focusrelay",
      "args": ["serve"]
    }
  }
}
```

After you update `.mcp.json`, new servers/tools are picked up on the next agent run. Rebuild/restart is only needed when NanoClawSwift code changes.
For mixed host/container operations and pagination workflow, see `docs/MCP_OPERATIONS.md`.

## FocusRelay Setup (OmniFocus on macOS Host)

FocusRelay is macOS-only, so configure it as a host MCP server in `.mcp.json` and NanoClawSwift will bridge it automatically.

1. Install FocusRelay on host (Homebrew):

```bash
brew tap deverman/focus-relay
brew install focusrelay
focusrelay bridge-health-check
```

2. Optional host env overrides:

```bash
export NANOCLAW_FOCUSRELAY_ENABLED="true"
export NANOCLAW_FOCUSRELAY_COMMAND="/opt/homebrew/bin/focusrelay"
```

3. Rebuild + restart runtime:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
```

4. Telegram smoke:
- `Please show mcp status`
- `Please reload mcp`
- `What are the tasks in my inbox?`
- `Please use mcp_host_cli server focusrelay args list-tasks --inbox-only true --limit 10`
- `show more` (or `show more 5` to change page size)

5. Optional parity verification (FocusRelay repo vs loaded MCP tools):

```bash
# Expected tool names from FocusRelay server source
python3 - <<'PY'
import re, pathlib
src = pathlib.Path("/Users/deverman/Documents/Code/swift/FocusRelayMCP/Sources/FocusRelayServer/FocusRelayServer.swift").read_text()
expected = sorted({
    n for n in re.findall(r'name:\\s*"([a-z0-9_\\-]+)"', src)
    if n in {
        "list_tasks", "get_task", "list_projects", "list_tags",
        "get_task_counts", "get_project_counts",
        "debug_inbox_probe", "debug_inbox_probe_alt", "bridge_health_check"
    }
})
print("\n".join(expected))
PY

# Loaded MCP tools from NanoClaw host bridge
curl -sS -X POST http://127.0.0.1:18081/mcp/host/bootstrap \
  -H 'content-type: application/json' \
  -d @<(jq '{servers:[.mcpServers|to_entries[]|{id:.key,command:.value.command,args:(.value.args//[]),env:(.value.env//{}),cwd:(.value.cwd//"")}]} ' .mcp.json) \
  | jq -r '.servers[] | select(.id=="focusrelay") | .tools[].name' | sort -u
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
