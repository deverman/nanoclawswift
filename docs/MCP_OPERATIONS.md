# MCP Operations Guide

Updated: 2026-02-18

## Scope

This guide covers day-to-day MCP operations for NanoClawSwift using:
- `runtime: "host"` servers (for host-only tools, like macOS integrations)
- `runtime: "container"` servers (for container-local tools)

## Mixed Runtime Configuration

Create `.mcp.json` in your group workspace and mix host/container servers in one file:

```json
{
  "mcpServers": {
    "focusrelay": {
      "runtime": "host",
      "transport": "stdio",
      "command": "/opt/homebrew/bin/focusrelay",
      "args": ["serve"]
    },
    "localsmoke": {
      "runtime": "container",
      "transport": "stdio",
      "command": "python3",
      "args": ["/workspace/group/tools/mcp_smoke_server.py"]
    }
  }
}
```

## Runtime Lifecycle

Use this as the default update flow after runtime code changes:

```bash
swift run nanoclaw-devctl rebuild-and-restart slim
```

After only `.mcp.json` changes (no code change), reload MCP from chat:
- `Please show mcp status`
- `Please reload mcp`
- `Please show mcp status`

## Tool Invocation Patterns

- Bridged tool style:
  - `Please use mcp_focusrelay_list_tasks tool`
- Host CLI style (token-cheap for large lists):
  - `Please use mcp_host_cli server focusrelay args list-tasks --inbox-only true --limit 10`

## Pagination UX

When MCP/CLI output includes `nextCursor`, agent output includes a continuation hint.

Continuation commands:
- `show more` (reuse previous page size)
- `show more 5` (override page size to 5)
- `next page` / `continue` (aliases)

Notes:
- If upstream cursor is stale, response will say no additional items were returned.
- Re-run the original query to reset pagination state.

## Troubleshooting

1. `Please show mcp status` reports `Config found: no`:
- Ensure `.mcp.json` exists in group workspace or `NANOCLAW_MCP_CONFIG_PATH` is set.

2. MCP reload succeeds but new tools do not appear immediately:
- New bridged tools are available on the next agent request by design.

3. Host server command works in terminal but fails in MCP:
- Verify executable path, args, and required env are present in `.mcp.json`.
- Confirm host health: `swift run nanoclaw-hostctl status`

4. FocusRelay due-date queries time out:
- This is currently an upstream FocusRelay issue for some due-window filters.
- Track and fix in `deverman/FocusRelayMCP` rather than adding local fallback behavior.
