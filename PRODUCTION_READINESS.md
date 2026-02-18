# Production Readiness

Updated: 2026-02-18

## Runtime Baseline

Production runtime is Swift-first:

- Host: `nanoclaw-host`
- Agent: `nanoclaw-agent` in Apple Containers
- Channel: Telegram polling only
- Queue/state: SQLite + host watchdog/janitor
- Orchestration: SwiftAgents `ToolCallingAgent` + `PlanAndExecuteAgent`

## Release Gates

1. `swift test` passes.
2. Container image builds successfully:
   - `swift run nanoclaw-devctl rebuild-and-restart slim` (preferred serialized path)
   - or `swift run nanoclaw-devctl build-agent-image slim` (build-only)
3. Host starts healthy:
   - `swift run nanoclaw-hostctl restart` (host-only changes)
   - `swift run nanoclaw-hostctl status`
4. Telegram smoke succeeds with owner DM.
5. No stale-doc CI violations from docs consistency guard.

## Security Gates

1. Only allowlisted env vars are passed into containers.
2. Side-effectful tools require approval/idempotency controls.
3. `write_memory` remains side-effect classified.
4. Attachment path mapping rejects traversal and out-of-root paths.
5. `TELEGRAM_OWNER_ID` is set in production.

## Reliability Controls (Implemented)

- Queue job watchdog timeout + forced recycle
- Session janitor sweep for stale container/session artifacts
- Stale claimed outbound reaper
- Startup scheduler catch-up for missed runs while host was offline
- Typing heartbeat lifecycle cleanup for long-running requests
- Provider RPM throttle to reduce 429 bursts
- Optional fallback provider route

## Key Environment Settings

Required:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_OWNER_ID`
- Provider settings such as:
  - `MODEL_PROVIDER`, `MODEL_NAME`
  - `MOONSHOT_API_KEY` (or provider equivalent)

Recommended for safety/reliability:

- `NANOCLAW_PROVIDER_RPM_LIMIT`
- `NANOCLAW_FALLBACK_PROVIDER`
- `NANOCLAW_FALLBACK_MODEL`
- `NANOCLAW_FALLBACK_API_KEY`
- `NANOCLAW_QUEUE_JOB_WATCHDOG_MS`
- `NANOCLAW_SESSION_JANITOR_INTERVAL_SEC`
- `NANOCLAW_STALE_CLAIM_REAP_AGE_SEC`

## Known Operational Risks

1. Scheduled tasks run only while the host is running.
2. If host network/provider is unavailable, scheduled reports can be delayed.
3. Host MCP bridge must be reachable for `runtime: "host"` MCP servers.
4. Provider-side rate limits can still occur under sustained user bursts.

## Triage Runbook

### No Telegram response

1. Check host health:
   - `swift run nanoclaw-hostctl status`
2. Inspect host log:
   - `tail -n 200 /tmp/nanoclaw-host.log`
3. Confirm required env vars are present for host process.
4. Confirm container image exists and is current.

### Frequent 429 errors

1. Lower request volume.
2. Set/adjust `NANOCLAW_PROVIDER_RPM_LIMIT`.
3. Configure fallback provider env vars.
4. Re-test with short prompts and monitor logs.

### MCP tools missing

1. Validate `.mcp.json` path and syntax.
2. Confirm server entries use `transport=stdio` and valid `runtime` (`container` or `host`).
3. For host MCP entries, confirm host relay is on and `NANOCLAW_MCP_HOST_BROKER_URL` is set in container env.
4. Check startup diagnostics emitted by MCP bootstrap.

## Current Readiness Summary

- Core Telegram runtime: ready
- Memory/parity tools: ready
- Attachment send path: ready (live smoke still recommended)
- MCP runtime wiring: ready in startup path (container + host bridge)
- Multi-channel: intentionally deferred
