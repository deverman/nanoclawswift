# Production Readiness

Updated: 2026-03-06

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

## Go/No-Go Gate (Operator Checklist)

Mark each gate `pass` / `fail`:

1. Build + restart reliability (`pass` requires one clean serialized run):
   - `swift run nanoclaw-devctl rebuild-and-restart slim`
2. Host health:
   - `swift run nanoclaw-hostctl status`
3. Scheduler diagnostics and due-task visibility:
   - `swift run nanoclaw-hostctl scheduler-diagnostics`
4. Scheduled task DB evidence:
   - `sqlite3 store/messages.db "SELECT id,status,next_run,last_run,last_result FROM scheduled_tasks ORDER BY id;"`
   - `sqlite3 store/messages.db "SELECT task_id,run_at,status,duration_ms,substr(result,1,120),substr(error,1,120) FROM task_run_logs ORDER BY run_at DESC LIMIT 10;"`
5. MCP runtime visibility in Telegram:
   - `show mcp status`
   - `please use mcp_host_cli server <server> args <command>`
6. Pagination UX:
   - run a paged MCP command, then `show more`, then `show more 3`
7. Rate-limit safety:
   - verify `NANOCLAW_PROVIDER_RPM_LIMIT` is set to a safe value for production load.

Go decision:

- `GO` if all gates pass.
- `NO-GO` if any gate fails; capture blocker + owner in `IMPLEMENTATION_PLAN.md`.

## Current Gate Status (2026-03-06)

1. Build + restart reliability: `pass`
2. Host health: `pass`
3. Scheduler diagnostics and due-task visibility: `partial` (Apple and Swift scheduled tasks now stable; provider/network soak confidence still needed)
4. Scheduled task DB status: `pass`
5. MCP runtime visibility in Telegram: `pass`
6. Pagination UX: `pass`
7. Rate-limit safety default: `pass`

Current decision: `NO-GO` until scheduler/provider soak confidence is complete.

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
- Serialized runtime update flow (`nanoclaw-devctl rebuild-and-restart slim`) to avoid concurrent build-db contention

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

Build/restart tuning:

- `NANOCLAW_DEVCTL_BUILD_TIMEOUT_SEC`
- `NANOCLAW_DEVCTL_CONTAINER_BUILD_TIMEOUT_SEC`

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
- Scheduled Swift tip runtime: ready with targeted-source fallback and explicit no-fresh-results branch
- Scheduled Apple report runtime: ready with targeted-source prompt and dated-source output
- Multi-channel: intentionally deferred
- Pending before final production go/no-go: complete another scheduler/provider soak cycle and re-run the gate checklist
