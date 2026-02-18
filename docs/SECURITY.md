# Security Model

Updated: 2026-02-18

## Trust Boundaries

1. Telegram inbound messages are untrusted input.
2. Host process (`nanoclaw-host`) is trusted control-plane.
3. Containerized agent runtime is isolated execution-plane.
4. Provider and MCP endpoints are external dependencies.

## Primary Security Controls

### 1) Container Isolation

- Agent logic runs in Apple Container Linux VM sessions.
- Group workspace mount is explicit (`/workspace/group`).
- Shared memory mount is explicit (`/workspace/shared-memory`).
- Host secrets are not blanket-mounted into containers.

### 2) Environment Passthrough Allowlist

Host forwards only specific env keys into containers (model/provider/runtime knobs). Arbitrary host env does not pass through by default.

### 3) Side-Effect Gating

Side-effect tools are wrapped with approval/idempotency controls, including:

- `write`
- `edit`
- `bash`
- `send_message`
- `schedule_task`
- `pause_task`
- `resume_task`
- `cancel_task`
- `todo_write`
- `activate_skill`
- `deactivate_skill`
- `sync_skills`
- `write_memory`

### 4) Attachment Path Safety

`send_message` attachment flow maps container paths to host paths safely and rejects:

- traversal attempts (`..`)
- out-of-root paths
- invalid/unresolvable attachment references

### 5) Telegram Owner Gating

Direct Telegram usage is restricted to `TELEGRAM_OWNER_ID`.

## Data Scope

- Chat memory: group-local persistent memory file.
- Global memory: shared host-mounted file accessible across groups.
- Session/chat history: stored in local runtime storage (SQLite + session files).

## MCP Security Posture

- MCP servers are loaded from `.mcp.json`.
- Runtime supports `transport=stdio` with:
  - `runtime=container` (container-launched MCP servers)
  - `runtime=host` (host-launched MCP servers via relay bridge)
- MCP failures are surfaced through diagnostics.

## Host MCP Bridge Security Posture

- Host relay endpoints:
  - `/mcp/host/bootstrap`
  - `/mcp/host/call`
  - `/mcp/host/cli`
  - `/mcp/host/status`
- Bootstrap validates server IDs, command payloads, args, env keys/values, and working directory fields.
- Tool calls validate server/tool/argument names and JSON argument payload types before MCP invocation.
- Host CLI calls are constrained to already-bootstrapped MCP server commands and validated args.
- Command/arg payloads reject control characters and enforce size/count limits.

## FocusRelay Compatibility Bridge

- Legacy FocusRelay relay endpoints (`/focusrelay/*`) remain available for backward compatibility.
- FocusRelay-specific allowlisted subcommand checks are still applied on those compatibility endpoints.
## Known Limits

1. Network egress is not hard-denied by default at container layer.
2. Provider quotas/rate limits can still fail requests.
3. Security depends on correct host env configuration and keeping host runtime controlled.

## Operational Recommendations

1. Keep API keys in environment, never in source.
2. Keep `TELEGRAM_OWNER_ID` set in all non-local environments.
3. Review side-effect tool usage in logs for unusual patterns.
4. Keep runtime and dependency updates tested before deployment.
