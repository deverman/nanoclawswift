# NanoClawSwift Implementation Plan (Swift-First)

Updated: 2026-03-07

## Summary

This plan tracks Swift-first parity and leapfrog work relative to `microclaw`, with Telegram-first scope and MCP before any multi-channel expansion.

## Locked Decisions

1. Runtime behavior is implemented in Swift targets first.
2. Telegram is the only active channel in this phase.
3. No feature flags for this migration.
4. Swift Testing (`import Testing`) is required for regression coverage.
5. Configuration/env access in Swift uses `swift-configuration` patterns.
6. MCP completion is prioritized before multi-channel expansion.
7. `write_memory` is side-effectful and follows approval/idempotency controls.
8. `TELEGRAM_OWNER_ID` remains required for owner-gated direct message access.

## Current Loop Profile (Balanced Default)

- Tool route max iterations: `16`
- Plan route max iterations: `40`
- Hard ceiling: `60`
- Tool-call budgets: tool `16`, plan `40`
- Session compaction thresholds: `40/20`
- Empty-visible-reply retry guard: one retry

## Phase 0: Documentation Realignment

### Scope

- Rewrite active docs:
  - `README.md`
  - `IMPLEMENTATION_PLAN.md`
  - `PRODUCTION_READINESS.md`
  - `docs/TELEGRAM_SETUP.md`
  - `docs/SECURITY.md`
- Rewrite legacy docs to remove contradictory runtime guidance:
  - `docs/SPEC.md`
  - `docs/REQUIREMENTS.md`
  - `docs/TELEGRAM_STATUS.md`
  - `docs/HANDOVER.md`
- Add CI docs consistency guard for stale patterns.

### Status

- [x] Active docs rewritten to Swift-first runtime truth
- [x] Legacy docs rewritten to remove deprecated runtime contradictions
- [x] CI stale-pattern guard added for active docs

## Phase 1: Memory Tools + Wax-Ready Abstraction

### Scope

- `read_memory` / `write_memory` tools
- Memory types (`MemoryScope`, `MemoryStore`, `MemoryWriteMode`, result models)
- Chat/global scope resolution
- Cross-group global memory via shared host-mounted path
- Memory context snippet injection with budget clipping
- Approval/idempotency for `write_memory`
- Provider seam for future Wax adapter

### Status

- [x] `MemoryStore` abstraction + `FileMemoryStore` default backend
- [x] `read_memory` and `write_memory` shipped in tool catalog
- [x] `scope=chat` mapped to group-local memory file
- [x] `scope=global` mapped to shared memory mount
- [x] Shared memory mount wired in host container session manager
- [x] Memory snippets injected into agent instructions with token budget cap
- [x] `write_memory` included in side-effect control policy
- [x] Swift tests for memory semantics and invalid args

## Phase 1A: Wax Decision Packet

### Scope

- Validate Wax fit against Linux container runtime model.
- Produce go/no-go decision with criteria:
  - compile/runtime compatibility
  - startup overhead
  - retrieval latency
  - operational complexity
  - testability in this repo

### Status

- [x] Decision packet documented in `docs/WAX_DECISION.md`
- [x] Adapter seam exists so Wax can be added without changing tool contracts

## Phase 2: Loop Capacity Uplift

### Scope

- Keep dual-route architecture
- Raise budgets to balanced defaults
- Add iteration/stop-reason telemetry
- Add empty-visible retry guard
- Add explicit compaction thresholds
- Preserve provider throttle and circuit protections

### Status

- [x] Budget defaults raised and config-backed
- [x] Stop-reason metadata emitted
- [x] One-time empty-visible retry guard implemented
- [x] Session compaction policy implemented
- [x] Rate-limit protection preserved
- [x] Loop policy and retry behavior tests updated/passing

## Phase 3: `send_message` Attachment Support (Telegram v1)

### Scope

- Tool schema supports `message|text`, `attachment_path`, `caption`
- Host IPC model extended for attachment metadata
- Safe container-path to host-path translation
- Telegram document delivery with retry path
- Outbound queue persistence/audit for attachments

### Status

- [x] Tool schema and validation implemented
- [x] Host IPC parsing + safe path resolver implemented
- [x] SQLite outbound schema expanded with attachment fields
- [x] Telegram transport supports document send with caption
- [x] Queue coordinator dispatches text vs attachment kinds
- [x] Swift tests for path safety and attachment queue delivery
- [x] Explicit tool-intent parser supports deterministic `send_message` args (`message|text`, `attachment_path`, `caption`) to reduce loop variance
- [x] Live Telegram attachment smoke validated (`attachment_path` + `caption`, outbound `attachment` row acked)

## Phase 3A: Inbound Photo Analysis (Telegram)

### Scope

- Capture inbound Telegram photo metadata (`file_id`, dimensions, size)
- Download inbound photo media from Telegram API and persist under group storage
- Add host-side OCR extractor seam (`ImageTextExtracting`) with no-op default
- Enrich inbound event content with OCR text (if available) or deterministic saved-path context
- Keep implementation Swift-first in host runtime with regression tests

### Status

- [x] Inbound event model extended with `attachments` payload
- [x] Telegram inbound mapper preserves photo attachment metadata
- [x] Host media pipeline implemented (`TelegramInboundMediaPipeline`)
- [x] Telegram file fetcher wired (`getFile` + file download)
- [x] Photo persistence path wired to `/workspace/group/.nanoclaw/inbound-media/...`
- [x] OCR seam wired with no-op default backend
- [x] Content enrichment for photo-only prompts implemented
- [x] Captioned-photo prompts now include OCR enrichment context (no more photo-only gate)
- [x] Swift tests added/passing for mapper + pipeline behavior
- [x] Apple Vision OCR backend wired for host runtime (with no-op fallback when unavailable)
- [x] Deterministic OCR direct-response path added for photo-text requests (strict output, confidence, correction hints)
- [x] OCR confidence/quality policy and user-facing fallback phrasing (includes low-confidence re-capture guidance)
- [x] OCR output polish: line-wrap normalization and debug-only image-path exposure

## Phase 4: MCP Runtime Completion (Before Multi-Channel)

### Scope

- Load `.mcp.json` in active startup path
- Launch supported container runtime MCP servers
- Discover/register bridged MCP tools
- Surface diagnostics for skipped/failed servers
- Add runtime tests and smoke path

### Status

- [x] MCP bootstrap wired into active `NanoClawAgent` startup path
- [x] MCP registration pipeline bridged into runtime tool list
- [x] Startup diagnostics surfaced in agent startup context
- [x] Config/registration unit tests passing
- [x] Real local MCP server smoke test completed (container-local stdio server; `mcp_localsmoke_ping -> mcp-smoke: ok`)
- [x] User-facing `mcp_status` tool added (deterministic explicit invocation path + startup status summary)
- [x] Generic host MCP bridge added for `.mcp.json` entries with `runtime: "host"` + `transport: "stdio"`
- [x] Host relay MCP endpoints added: `/mcp/host/bootstrap`, `/mcp/host/call`, `/mcp/host/cli`, `/mcp/host/status`
- [x] Agent host MCP bootstrap/execution wired into active startup path (no per-server Swift code changes required)
- [x] Added `mcp_host_cli` tool for direct host MCP server CLI execution (token-cheap path)
- [x] Added `mcp_reload` tool for config-driven MCP reload + host rebootstrap diagnostics
- [x] Added host MCP command/server-id validation and regression tests
- [x] FocusRelay coverage audit: runtime-loaded MCP tools match FocusRelay server tool declarations exactly (9/9)
- [x] Added generic MCP user-facing output rendering so explicit MCP/CLI calls return readable summaries instead of raw JSON payloads in Telegram
- [x] Added cursor-aware MCP pagination UX for `mcp_host_cli` (`show more` continuation + next-page hint with stored cursor context)
- [x] Added terminal pagination state handling so empty continuation pages return a clear "no additional items" response instead of dropping to "no active pagination"
- [x] Added continuation page-size override for MCP pagination (`show more <n>`) with regression coverage.
- [x] Added operator guide for mixed host/container MCP server configuration and lifecycle (`docs/MCP_OPERATIONS.md`).

### FocusRelay Compatibility Notes

- [x] Existing FocusRelay convenience tools remain for backward compatibility.
- [x] Preferred path is now generic MCP config (`runtime: host`) plus bridged `mcp_<server>_<tool>` tools.

## Phase 5: Multi-Channel

### Scope

- Deferred intentionally.

### Status

- [x] Explicitly deferred until after MCP completion + stabilization

## Phase 4B: Daemon Agent Cache (Latency)

### Scope

- Keep long-running container daemon model.
- Cache `NanoClawAgent` instance inside daemon and reuse across requests when request key is unchanged.
- Rebuild cached agent on key change (`group_folder`, `chat_jid`, `is_main`, `is_scheduled_task`) or explicit invalidation.
- Invalidate cache after successful `mcp_reload` request so newly loaded MCP bridged tools are available on the next request.
- Add Swift tests for cache reuse/rebuild and invalidation trigger parsing.

### Status

- [x] Daemon cache actor implemented and wired into request processing
- [x] `mcp_reload` invalidates cached agent after success
- [x] Swift tests for cache behavior and invalidation prompts

## Phase 4C: Scheduled Report Reliability Investigation

### Scope

- Verify scheduler trigger path end-to-end for recurring reports:
  - host startup catch-up path
  - 30s poll loop due-check path
  - queue dispatch
  - post-run `next_run` advancement
- Add a deterministic operator workflow to diagnose missed reports from host log + SQLite state.
- Classify scheduled run failures by cause (`host_down`, `network_offline`, `provider_timeout`, `provider_rate_limit`, `token_overflow`, `tool_error`).
- Add user-facing failure notice for scheduled runs so silent misses are reduced.
- Add targeted retry policy for transient scheduled-run failures (429/5xx/timeout) with hard cap.
- Add Swift regression tests for:
  - startup catch-up after downtime
  - exactly-once enqueue guard for due tasks
  - failure classification + user-visible failure response

### Current Findings (2026-02-18)

- [x] No OS cron dependency: scheduling is host-driven in `NanoClawHostService.schedulerLoop()` + `store.dueTasks(nowISO:)`.
- [x] Startup catch-up exists and runs before poll loop start (`enqueueDueScheduledTasks(reason: "startup")`).
- [x] Daily report miss reproduced as execution failure, not trigger miss (`task-1770913720773-AFDA0B` ran at `2026-02-18T00:01:50Z` and failed with upstream timeout).
- [x] Direct-request watchdog false negatives observed: host watchdog (`240s`) fired before some container responses arrived (`~245s-252s`), causing user-visible timeout despite eventual container success.
- [x] Natural-language intent gaps observed for direct Telegram commands/tool mapping (e.g. `"List my scheduled tasks"`, `"Anything in my OmniFocus inbox?"`) causing avoidable LLM loop usage.
- [x] Root cause confirmed for OmniFocus "due today" failures: upstream FocusRelay `list-tasks` with due-date filters (`--due-after` / `--due-before`) can time out at bridge layer (`Bridge response timed out`).
- [x] Upstream FocusRelay timeout mitigation implemented and submitted as PR: `deverman/FocusRelayMCP#8` (extended timeout policy for heavy date/search filters).
- [x] Dev build instability root-cause findings captured:
  - containerized SwiftPM builds for agent image (`swift:6.2.3` + mounted workspace) can fail with llbuild SQLite assertions.
  - containerized SwiftPM repo cache can enter broken state (`git -C .../org.swift.swiftpm/repositories/...: No such file or directory`).
  - host static SDK build path can intermittently hang with idle `swift-build` process in this environment.
- [x] Additional root cause confirmed for local static SDK build failures on macOS 26 target:
  - static Linux SDK is musl-based; Linux-only libc imports that assume `Glibc` fail with `no such module 'Glibc'`.
  - fixed in vendored `Conduit` by using `canImport(Glibc)` / `canImport(Musl)` compatibility imports.
  - note: `Packages/` is gitignored in this repo; long-term durability requires upstreaming this fix or pinning a patched dependency revision.
- [x] `nanoclaw-devctl` reliability hardening expanded:
  - warm static SDK build path (`.build/linux-static-sdk`) instead of per-run cold temp path.
  - transient failure classifier + one clean retry after build-path reset.
  - timeout watchdog remains enforced for build/container build stages.
- [x] Clean serialized runtime update completed with new path (`swift run nanoclaw-devctl rebuild-and-restart slim`):
  - static Linux `nanoclaw-agent` build succeeded in ~118s after warm path stabilization.
  - container image `nanoclawswift-agent:slim` packaged successfully.
  - host restart completed (`nanoclaw-host` new pid + healthy socket).
- [x] Telemetry/soak spot-check (`verify-telegram-soak --since-minutes 120`) passed for recent Telegram request flow (accepted/completed parity observed).
- [x] Scheduler diagnostics confirm trigger path is healthy; current missed Apple report cause remains upstream provider timeout (`HTTP 502 timeout`) on `task-1770913720773-AFDA0B`.
- [x] Live scheduler diagnostics snapshot captured (`nanoclaw-hostctl scheduler-diagnostics`): host healthy, both recurring tasks active, `next_run` values advancing correctly (`2026-02-19T00:00:00Z`, `2026-02-19T00:30:00Z`).
- [x] DB evidence confirms scheduler trigger + run logging is functioning (`store/messages.db`: `scheduled_tasks`, `task_run_logs`), with failures concentrated in provider-side errors (`502 timeout`, prior `429`, prior token overflow), not missed cron trigger execution.
- [x] Local CLI due-window probe currently returns without timeout (`focusrelay list-tasks --due-before ... --due-after ... --limit 20` in ~2.6s); remaining validation is Telegram end-to-end behavior through MCP bridge.

### Status

- [x] Added `nanoclaw-hostctl scheduler-diagnostics` command (host health + scheduled task rows + recent task_run_logs + scheduler loop log evidence + inferred failure cause classification).
- [x] Add scheduled failure classification + structured telemetry.
- [x] Add scheduled failure user notification template with concise remediation hint.
- [x] Add transient retry policy for scheduled runs (bounded attempts + backoff + idempotent send guard).
- [x] Add Swift tests for downtime catch-up, dedupe, and transient retry behavior.
- [x] Increased default queue watchdog budget to reduce false timeout preemption (`NANOCLAW_QUEUE_JOB_WATCHDOG_MS`: `295000`).
- [x] Expanded deterministic intent parsing for direct scheduled-task listing and OmniFocus inbox/due-today asks to reduce slow LLM loop fallthrough.
- [x] Decided not to ship paging/fallback workarounds for FocusRelay due-date filter timeout; surfaced failure transparently while upstream fix was in flight.
- [x] Added serialized dev command `nanoclaw-devctl rebuild-and-restart` with repo lock to prevent concurrent devctl SwiftPM operations that can trigger llbuild SQLite build-db contention.
- [x] Started passive (no extra LLM prompt) soak baseline at `2026-02-18 17:17 +0800`; both scheduled tasks active with next runs `2026-02-19T00:00:00Z` and `2026-02-19T00:30:00Z`.
- [x] Added Swift Testing coverage for devctl static-build reliability helpers (retry classifier + warm build path).

## Parity Tools and Skills

### Status

- [x] Skills subsystem shipped (`list_skills`, `activate_skill`, `deactivate_skill`, `sync_skills`)
- [x] Parity tools shipped (`todo_*`, `sub_agent`, `get_task_history`, `export_chat`)
- [x] Natural-language tool intent mapping improved for common task operations
- [x] Added default skills discovery support for `~/.claude/skills` alongside existing `CODEX_HOME/skills` and `~/.codex/skills` (explicit `skills_root` still supported).
- [x] Added deterministic active-skill context injection before each run.
- [x] Added configurable token budget + truncation for injected skill context (`NANOCLAW_SKILLS_CONTEXT_TOKEN_BUDGET`, `NANOCLAW_SKILLS_CONTEXT_MAX`).
- [x] Added per-request auto-resolver for active skills by intent (`NANOCLAW_SKILLS_AUTO_RESOLVE`).
- [x] Added run telemetry metadata for injected skills (`nanoclaw.skills.*` keys in result metadata).

## Operational Notes

1. If code changes touch `Sources/NanoClawAgent/**`, `Package.swift`, or container runtime files, rebuild image before runtime validation:
   - `swift run nanoclaw-devctl build-agent-image slim`
2. If code changes touch `Sources/NanoClawHost/**`, restart host before runtime validation:
   - `swift run nanoclaw-hostctl restart`
3. For end-to-end changes involving both host and agent, do both steps.

## Next Priority Queue

1. Scheduled Apple report runtime hardening (`done 2026-03-06`):
   - stricter targeted-source prompt deployed to the live scheduler DB
   - scheduled runs now execute on forced `tool_calling` path
   - manual trigger validated successful completion with fresh dated Apple sources
   - accepts either fresh dated sources or explicit no-fresh-updates branch
2. Scheduled Swift tip runtime hardening (`done 2026-03-06`):
   - scheduled runs now force `tool_calling`
   - one-shot recovery path is active for missing structured tool calls
   - manual trigger validated successful completion with `toolCalls=2`
   - no-fresh-results wording corrected from "retrieval failed" to explicit no-fresh-updates messaging
   - source search policy expanded to targeted Swift sources with 14-day fallback when 7-day window is empty
3. Scheduled-report soak closure (`in progress`, narrowed scope to provider/network stability):
   - Apple and Swift scheduled tasks now both behave correctly at runtime
   - remaining soak blocker is general provider/network noise, not scheduler/task logic
4. GitHub Actions reliability hardening (`new`, production blocker):
   - observed failing GitHub Actions workflow notification for `Build Linux Binary (glibc)`
   - treat green CI on the branch head as required before production GO
   - next step: inspect workflow logs, fix the glibc build failure, and keep the workflow green across the latest scheduler/runtime commits
5. Production-readiness gate re-run and short go/no-go report:
   - rerun gate checklist with current Apple + Swift scheduled-task behavior
   - verify no new regressions in next soak window
   - require GitHub Actions success for the release branch head
6. Serialized runtime update flow (`done`, standard path): `swift run nanoclaw-devctl rebuild-and-restart slim`.
7. Swift-native dev build reliability hardening (`done 2026-02-19`, but still an operational pain point):
   - runtime-critical builds still hit static SDK cross-arch and transient network/submodule fetch failures
   - keep improving reproducibility so deploy/validate loops are less fragile
8. MCP stability hardening follow-up (`in progress`):
   - host-side MCP lifecycle fix shipped on `2026-03-04`:
     - explicit `client.disconnect()` before remove/replace/shutdown in `HostMCPRuntime`
     - restart dead same-spec host MCP servers during bootstrap
     - startup failure path now disconnects/terminates partial MCP server state
   - post-restart verification (`2026-03-04`):
     - host relay bootstrap endpoint loads FocusRelay successfully (`loadedServerCount=1`, `loaded_tools=9`)
     - host MCP status now reports loaded `focusrelay` server after bootstrap
   - upstream SDK follow-up still needed for `Client.connect(transport:)` stream-finished loop behavior.
9. Continue MCP usability polish (cursor UX + human-readable rendering) only when tied to observed user friction; avoid speculative over-architecture.
10. Dependency hardening quick win (`done 2026-02-19`; keep pin for now):
   - Root cause recap:
     - we switched the `slim` build path from containerized `swift:6.2.3` (glibc) to static Linux SDK (musl) in `nanoclaw-devctl`.
     - this surfaced a latent Conduit Linux import assumption (`os(Linux) -> import Glibc`) that previously stayed hidden in glibc-only build mode.
   - Decision:
     - keep static SDK workflow (it improved build determinism in this repo after repeated containerized SwiftPM contention/cache failures).
     - keep current pinned Swarm commit until upstream PR path is complete and validated in this repo.
     - remove local editable `Packages/Swarm` from root dependency graph and pin remote Swarm + Conduit revisions for reproducible builds.
   - Implementation details:
     - fork: `https://github.com/deverman/Conduit`
     - commit: `b84f1abeee399645bc14e11872e4e7e741c9dc17`
     - branch: `musl-libc-import-20260219`
     - change: `canImport(Glibc)` / `canImport(Musl)` import guard in `DeviceCapabilities.swift`.
     - Swarm fork: `https://github.com/deverman/Swarm`
     - Swarm commit: `def222ee68681667a6d3b7a497180454b064e61e` (pins Conduit fork revision)
     - root `Package.swift` now uses remote pinned Swarm revision (no `package(path: "Packages/Swarm")` in active graph).
     - root `Package.resolved` refreshed and `swift build --product nanoclaw-agent` passed.
   - Follow-up:
     - open upstream PR to `christopherkarani/Conduit` and replace fork pin with upstream tag/revision once merged.
     - open upstream PR to `christopherkarani/Swarm` and replace fork pin with upstream tag/revision once merged.
     - keep this note because this repo previously had musl friction and the compatibility requirement is still relevant.

11. Provider throttle safety default (`done 2026-03-04`):
   - host now backfills `NANOCLAW_PROVIDER_RPM_LIMIT` into container passthrough when unset/invalid.
   - resolution order: explicit `NANOCLAW_PROVIDER_RPM_LIMIT` (if valid) -> valid `KIMI_RPM_LIMIT` -> default `18`.
   - regression coverage added in `HostEnvironmentConfigTests`.

### Soak Checkpoint (2026-02-19)

- [x] Cycle 1 evidence captured:
  - `task-1770913720773-AFDA0B` executed and delivered successfully at `2026-02-19T00:03:53Z`.
  - `next_run` advanced to `2026-02-20T00:00:00Z`.
- [x] Scheduler trigger path verified from host diagnostics/logs (`poll` enqueue + queue processing + run logs).
- [x] Post-restart diagnostics snapshot captured (`nanoclaw-hostctl scheduler-diagnostics` on 2026-02-19):
  - host healthy (`nanoclaw-host` running, socket valid)
  - Apple report task still active with next run `2026-02-20T00:00:00Z`
  - prior success evidence retained (`2026-02-19T00:03:53Z`)
- [x] Cycle 2 closure recorded on `2026-03-04` after runtime restart/catch-up:
  - `scheduler-diagnostics` shows `host.healthy=true` and startup catch-up evidence for all active tasks.
  - `scheduled_tasks` rows advanced (`next_run`: `2026-03-04T23:00:00Z`, `2026-03-05T00:00:00Z`, `2026-03-05T00:30:00Z`).
  - `task_run_logs` show successful runs at `2026-03-04T12:15:42Z`, `2026-03-04T12:16:24Z`, `2026-03-04T12:18:24Z`.
- [x] Noted transient failure cluster on `task-1771244294918-8232D9` at `00:30/00:45/00:50Z` caused by `network_offline`; retry policy fired as designed.

## Backlog

1. Repository identity update after stabilization:
   - evaluate project rename and standalone non-fork repo branding
   - align package/product naming only after runtime/doc stabilization completes
2. OmniFocus due-today Telegram E2E validation against FocusRelay timeout patch:
   - defer until external workstream is complete
   - validate no timeout/error path through MCP bridge before promoting to active priority

## Immediate Operator Command Set

1. Scheduler health snapshot:
   - `swift run nanoclaw-hostctl scheduler-diagnostics`
2. DB verification snapshots:
   - `sqlite3 store/messages.db "SELECT id,status,schedule_type,schedule_value,next_run,last_run,last_result FROM scheduled_tasks ORDER BY id;"`
   - `sqlite3 store/messages.db "SELECT task_id,run_at,status,duration_ms,substr(result,1,120),substr(error,1,120) FROM task_run_logs ORDER BY run_at DESC LIMIT 10;"`
