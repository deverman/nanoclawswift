# NanoClawSwift Technical Specification

Updated: 2026-02-17

## 1. Scope

This specification describes the active Swift-first runtime for NanoClawSwift.

In-scope:
- Telegram channel (polling)
- Swift host orchestration + Swift container agent
- Tool-calling and plan/execute loop routes
- Skills and parity tools
- Memory tools and persistent memory context
- MCP runtime bootstrap and tool bridging

Out-of-scope:
- Multi-channel runtime expansion (deferred)
- Wax as production memory backend (decision pending)

## 2. Runtime Architecture

```text
Telegram -> SwiftTelegramInboundPolling -> NanoClawHostService
         -> GroupQueue/SQLite/Scheduler -> ContainerSessionManager
         -> nanoclaw-agent (Swift) -> Tool execution + provider + response
         -> outbound queue -> SwiftTelegramAdapter -> Telegram API
```

### Host Components

- `Sources/NanoClawHost/main.swift`
- `Sources/NanoClawHost/NanoClawHostService.swift`
- `Sources/NanoClawHost/ContainerSessionManager.swift`
- `Sources/NanoClawHost/SQLiteStore.swift`
- `Sources/NanoClawHost/SwiftTelegramInboundPolling.swift`
- `Sources/NanoClawHost/SwiftTelegramAdapter.swift`
- `Sources/NanoClawHost/HostEnvironmentConfig.swift`

### Agent Components

- `Sources/NanoClawAgent/NanoClawAgent.swift`
- `Sources/NanoClawAgent/ExecutionPolicies.swift`
- `Sources/NanoClawAgent/Tools/Tools.swift`
- `Sources/NanoClawAgent/Skills/`
- `Sources/NanoClawAgent/MCPToolLoader.swift`
- `Sources/NanoClawAgent/MCPRuntime.swift`

## 3. Execution Model

Dual-route execution is used:

1. `ToolCallingAgent` for direct/simple asks
2. `PlanAndExecuteAgent` for multi-step asks

Loop policy defaults:
- Tool route: 16 iterations, 16 tool-call budget
- Plan route: 40 iterations, 40 tool-call budget
- Hard ceiling: 60

Additional controls:
- Session compaction threshold/retain defaults (40/20)
- One-time empty-visible-reply retry guard
- Stop reason metadata for telemetry and triage

## 4. Tooling Surface

Core tool families include:

- Filesystem/search/shell: `read`, `write`, `edit`, `glob`, `grep`, `bash`
- Web: `web_fetch`, `web_search`, policy controls
- Scheduling: `schedule_task`, `list_tasks`, `pause_task`, `resume_task`, `cancel_task`
- Messaging: `send_message` (text + optional `attachment_path` + optional `caption`)
- TODO/history/export: `todo_read`, `todo_write`, `get_task_history`, `export_chat`
- Delegation: `sub_agent`
- Skills: `list_skills`, `activate_skill`, `deactivate_skill`, `sync_skills`
- Memory: `read_memory`, `write_memory`
- MCP bridged tools: `mcp_<server>_<tool>`

## 5. Memory Model

### Memory scopes

- `chat`: group-local persistent memory
- `global`: cross-group shared memory

### Storage mapping

- Chat memory file: `/workspace/group/.nanoclaw/memory/chat.md`
- Global memory file: `/workspace/shared-memory/global.md`

Host mounts shared memory into all container sessions for true cross-group global scope.

Memory snippets are injected into request instructions with token-budget clipping.

## 6. MCP Runtime

Startup loader behavior:

1. Resolve `.mcp.json` from:
   - `/workspace/group/.mcp.json`
   - `/workspace/project/.mcp.json`
   - current working directory
   - or `NANOCLAW_MCP_CONFIG_PATH`
2. Parse/normalize server entries.
3. Validate runtime/transport and collect:
   - container stdio servers
   - host stdio servers
4. Launch container stdio MCP servers directly in agent runtime.
5. Bootstrap host stdio MCP servers through host relay bridge (`/mcp/host/*`).
6. Discover tools and register bridged Swift tools.
7. Emit diagnostics for loaded/skipped/error states.

## 7. Messaging Behavior

Telegram behavior includes:
- typing heartbeat lifecycle management for long requests
- message chunking for Telegram limits
- outbound queue claim/ack retry handling
- attachment delivery path using Telegram document endpoint

## 8. Scheduling Behavior

- Recurring and one-time tasks persist in host SQLite.
- Scheduler uses configured host timezone.
- Startup catch-up queues missed tasks once on host start.
- User-facing notice is emitted for startup catch-up execution.

## 9. Configuration Sources

Swift runtime config uses `swift-configuration` patterns with controlled fallbacks.

Key runtime env groups:
- Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_OWNER_ID`
- Provider/model: `MODEL_PROVIDER`, `MODEL_NAME`, provider API keys
- Loop policies: `NANOCLAW_TOOL_ROUTE_MAX_*`, `NANOCLAW_PLAN_ROUTE_MAX_*`
- Reliability: watchdog/janitor/reaper settings
- MCP: `NANOCLAW_MCP_CONFIG_PATH`, `NANOCLAW_MCP_HOST_BROKER_URL`

## 10. Non-Goals (Current)

- Additional chat channels beyond Telegram
- Reintroducing legacy Node runtime control loops
- Using Wax as default production memory backend before compatibility decision
