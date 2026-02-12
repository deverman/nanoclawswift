# NanoClawSwift Implementation Plan

**Repository**: https://github.com/deverman/nanoclawswift  
**Base**: https://github.com/gavrielc/nanoclaw  
**Branch**: swift-agent  
**Status**: Big-bang migration in progress. Swift host orchestrator is active, long-running container daemon path is implemented, GRDB is integrated, cron scheduling now runs through `CronEngineKit`, and relay/web-broker parity is restored on the new single runtime path. Remaining blockers are final documentation and dependency cleanup.

## Big-Bang Migration Tracker (Authoritative)

This section is the source of truth for the current cutover status.

### Completed
- [x] Added Swift host runtime (`nanoclaw-host`) with Unix socket API:
  - `POST /v1/events/inbound`
  - `POST /v1/outbound/claim`
  - `POST /v1/outbound/ack`
  - `GET /v1/health`
- [x] Implemented Swift `GroupQueue` with one worker per group and global concurrency cap.
- [x] Implemented long-running container sessions via `ContainerSessionManager`.
- [x] Added container daemon mode in `NanoClawAgentCLI` (`--daemon`) with mounted IPC request/response protocol.
- [x] Cut Node runtime to channel adapters + host client (`src/host-client.ts`).
- [x] Moved host state to Swift + SQLite (GRDB) in `Sources/NanoClawHost/SQLiteStore.swift`.
- [x] Added inbound dedupe (`channel + chat_jid + message_id`) to prevent reconnect duplicate replies.
- [x] Added outbound claim lease recovery to avoid stuck claimed messages.
- [x] Added new test suites:
  - `Tests/NanoClawHostTests/*`
  - `Tests/CronEngineKitTests/*`
- [x] Added standalone cron package-style library target `CronEngineKit` and wired host scheduler to it.
- [x] Restored host relay + web broker parity on the cutover path (`src/host-relay.ts` + adapter bootstrap wiring in `src/index.ts`) so `BASE_URL`/`NANOCLAW_WEB_BROKER_URL` are configured before host startup.

### In Progress
- [ ] Documentation cleanup for the big-bang cutover (remove stale references to deleted Node orchestrator files).

### Completed (Recent)
- [x] Node dependency cleanup for removed orchestration components:
  - removed `better-sqlite3`, `cron-parser`, `zod`, and `@types/better-sqlite3` from `package.json`.
  - refreshed `package-lock.json` to remove corresponding lock entries.
- [x] Started documentation cutover updates for the new runtime path:
  - refreshed architecture and bring-up guidance in `README.md`.
  - updated `docs/HANDOVER.md` and `docs/TELEGRAM_STATUS.md` to reference `nanoclaw-host` + `src/host-relay.ts`/`src/index.ts`.
  - added explicit legacy warning in `docs/SPEC.md` until full spec refresh is completed.

### Next Steps (Execution Order)
1. Update all runbooks and architecture docs to match Swift-host orchestration reality.
2. Run Telegram E2E regression checklist on the cutover path:
   - DM prompt-response
   - schedule/list/cancel across restart
   - duplicate inbound replay check
   - timeout/retry behavior
3. Produce a clean commit with the full big-bang delta and updated operational docs.

### Performance Backlog (2026-02-12)

Observed timings for prompt `what is the latest vision pro?`:
- Inbound event received at `2026-02-12T03:12:36Z` (`inbound_events.message_id=227`).
- Long-running container session started at `11:12:36` local (same second as inbound).
- First web-broker policy access at `11:12:43` local (`Web policy global file not found` warning indicates first web tool call).
- Outbound response created at `2026-02-12T03:13:52Z`.
- End-to-end latency was ~76 seconds.

Interpretation:
- Primary previous failure cause (fixed): agent default timeout was 60 seconds when `TIMEOUT` env was unset.
- Current latency bottleneck is not a hard timeout; it is mostly run-time latency from cold session startup + multi-step tool/LLM turn for web retrieval and synthesis.

Backlog items:
- [x] Add per-stage latency instrumentation and persistence (host logs now emit queue wait + stage durations):
  - queue wait
  - container warm/cold start time
  - each tool call duration
  - each provider inference duration
  - final render/send duration
- [x] Add structured host logs for request lifecycle with `request_id` correlation across:
  - inbound event
  - queue dequeue
  - container dispatch
  - tool execution
  - outbound enqueue
- [x] Optimize web tool payload size before model synthesis:
  - default HTML-to-text extraction
  - cap and summarize tool outputs before passing full page content to the model
  - targeted extraction of title/meta/headings/paragraphs for web pages
- [x] Add warm-session policy for active groups:
  - proactively start/keep alive most active groups on host boot (`NANOCLAW_PREWARM_GROUP_SESSIONS`, `NANOCLAW_PREWARM_LIMIT`)
  - avoid first-message cold start penalty (verified in startup logs for `telegram-direct`)
- [x] Add latency SLO and alert thresholds:
  - host health now exposes `response_p50_ms`, `response_p95_ms`, `timeout_rate`, `retry_rate`, and `completed_jobs`
  - host emits periodic SLO warning logs when thresholds are breached (`NANOCLAW_LATENCY_SLO_P50_MS`, `NANOCLAW_LATENCY_SLO_P95_MS`, `NANOCLAW_TIMEOUT_ALERT_RATE`, `NANOCLAW_RETRY_ALERT_RATE`)
- [x] Add user-facing “working” ack policy when runtime exceeds threshold (for example >8s) to improve UX during long web-assisted runs.
  - host now enqueues delayed ack after `NANOCLAW_WORKING_ACK_THRESHOLD_MS` (default `8000`) with `NANOCLAW_WORKING_ACK_ENABLED` control
- [ ] Rewrite web payload optimization path in Swift host runtime (replace Node regex extraction with Swift-native parser utility):
  - target: move HTML extraction/summarization from `src/host-relay.ts` into Swift host service
  - evaluate `SwiftSoup` first; if needed, wrap parser behind a small `WebContentExtractor` protocol for future engine swap
  - keep existing broker response contract stable (`contentFormat`, truncation flags, redirect/policy behavior)

## Current Progress

### ✅ Phase 0: Foundation & CI/CD (COMPLETE)

#### ✅ Step 0.1: Repository Setup
- [x] Fork repository from gavrielc/nanoclaw to deverman/nanoclawswift
- [x] Clone the forked repository locally
- [x] Create and switch to swift-agent branch
- [x] Verify clean working directory

#### ✅ Step 0.2: Swift Package Structure
- [x] Create Package.swift with dependencies:
  - SwiftAgents 0.3.1 (EXACT VERSION - PINNED, sourced from `Swarm.git`)
  - swift-argument-parser 1.5.0+
  - swift-configuration 1.0.2+
- [x] Create Sources/NanoClawAgent/ directory structure
- [x] Create Tests/NanoClawAgentTests/ directory
- [x] Add placeholder main.swift
- [x] Add placeholder test file

#### ✅ Step 0.3: CI/CD Pipeline
- [x] Create .github/workflows/ci.yml
- [x] Configure Swift setup (version 6.2.3)
- [x] Add build step
- [x] Add test step
- [x] Add container build step
- [x] Push to GitHub (origin swift-agent)
- [x] Verify repository is accessible via gh CLI

#### ✅ Step 0.4: Container Setup
- [x] Create container/Dockerfile.slim (swift:6.2.3-slim)
- [x] Create container/build-swift.sh script
- [x] Make scripts executable
- [x] Install Swift Static Linux SDK (aarch64-swift-linux-musl)
- [x] Build Linux release binary with SDK
- [x] Stage Linux binary for container build

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           HOST (macOS)                                  │
│  ┌──────────────────────┐    Unix socket HTTP     ┌──────────────────┐ │
│  │ Node channel adapters │  ───────────────────▶   │ Swift host        │ │
│  │ Telegram + WhatsApp   │                         │ (nanoclaw-host)   │ │
│  │ outbound claim/ack    │  ◀───────────────────   │ queue/scheduler/DB│ │
│  └──────────────────────┘                          └────────┬─────────┘ │
│                                                              │           │
│                                      mounted IPC files       │           │
│                                      (request/response)      ▼           │
├─────────────────────────────────────────────────────────────────────────┤
│                      APPLE CONTAINER (Linux VM)                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    nanoclaw-agent (Swift Binary)                  │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ NanoClawAgent (ToolCallingAgent runtime)                    │ │  │
│  │  │ ├─ structured tool-call execution only                      │ │  │
│  │  │ ├─ File, Bash, IPC, Web tools                               │ │  │
│  │  │ ├─ CLAUDEMemory + per-group session state                   │ │  │
│  │  │ └─ daemon mode processing mounted IPC requests              │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  │                                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Mounts:                                                                │
│    • groups/{group}/ → /workspace/group                                 │
│    • store/runtime/{group}/ipc → /workspace/ipc                         │
│    • store/sessions/{group}/.claude → /home/nanoclaw/.claude            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Implementation Checklist

### Phase 0: Foundation & CI/CD (Shift-Left) ✅ COMPLETE

### Phase 1: Core Infrastructure (IN PROGRESS)

#### Step 1.1: Type-Safe Configuration
- [x] Create Configuration/ModelProvider.swift (enum: kimi, openai, anthropic)
- [x] Create Configuration/ModelName.swift (enum with all model variants)
- [x] Create Configuration/NanoClawConfig.swift (struct with Codable)
- [x] Create Configuration/ConfigLoader.swift (manual JSON + env var loading)
- [x] **FIXED:** Changed from "API_KEY" to "MOONSHOT_API_KEY" to match your env
- [x] Write tests for config loading

#### Step 1.2: Async CLI
- [x] Create NanoClawAgentCLI.swift with AsyncParsableCommand
- [x] Implement argument parsing
- [x] Implement stdin reading
- [x] Add output markers (---NANOCLAW_OUTPUT_START--- / END)
- [x] Write tests for CLI parsing

#### Step 1.3: OpenAI-Compatible Provider ✅
- [x] Create Providers/OpenAICompatibleProvider.swift
- [x] Implement InferenceProvider protocol
- [x] Implement chat completion request/response
- [x] Implement error handling
- [x] **RETRY LOGIC WITH EXPONENTIAL BACKOFF** - Implemented for 429 errors:
  - Max 5 retries with exponential backoff (1s, 2s, 4s, 8s, 16s)
  - Total max wait: 31 seconds before giving up
  - Logs each retry attempt with timing
  - Only retries on HTTP 429 (rate limit/overloaded)
- [ ] Write unit tests (pending)

### Phase 2: File-Based Session Persistence ✅ COMPLETE
- [x] Create FileBasedSession with JSON persistence
- [x] **FIXED:** Support both container and local paths (absolute paths starting with "/")
- [x] Secure file permissions
- [x] Write tests
- [x] Verified working in Apple Containers

### Phase 3: Tools Implementation 🔄
- [x] FileSystem tools (Read, Write, Edit, Glob, Grep)
- [x] BashTool
- [x] IPC Tools
- [x] Write tests

### Phase 4: Agent Assembly 🔄
- [x] CLAUDEMemory
- [x] NanoClawAgent
- [x] ArchivingHooks (with local path support)
- [x] Write integration tests (tool-call loop)

### Phase 5: Web Tools ✅ COMPLETE
- [x] Host web broker (`/web/fetch`, `/web/search`, `/web/policy/list`) with allow/deny enforcement
- [x] Global + group overlay web policy model
- [x] Swift tools: `web_fetch`, `web_search`, `web_policy_add_domain`, `web_policy_remove_domain`, `web_policy_list`
- [x] Group overlay persistence in `groups/{group}/.nanoclaw/web-policy.overlay.json`
- [x] Test coverage for web policy overlay tools
- [x] Rebuild `nanoclawswift-agent:slim` from current sources and verify tool availability in-container

## Retry Logic Implementation

### Exponential Backoff for 429 Errors

**Location:** `OpenAICompatibleProvider.swift`

**Behavior:**
- Detects HTTP 429 (rate limited / engine overloaded)
- Retries up to 5 times with exponential backoff
- Delays: 1s → 2s → 4s → 8s → 16s
- Total max delay: 31 seconds
- Logs each retry: `[OpenAICompatibleProvider] Rate limited (429), attempt N/5. Retrying in X.Xs...`

**Configuration:**
```swift
public init(
    apiKey: String,
    baseURL: String,
    model: String,
    timeout: Int = 180,
    maxRetries: Int = 5,      // Configurable
    baseDelay: Double = 1.0   // Configurable
)
```

**Why This Matters:**
Kimi API frequently returns 429 (overloaded) during peak times. Without retry logic, requests fail immediately. With retry logic, the agent waits and retries, significantly improving success rates.

## Environment Variables

### Required (choose at least one provider)
- `OPENAI_API_KEY` - OpenAI API key (recommended)
- `MOONSHOT_API_KEY` - Kimi API key (starts with sk-)
- `ANTHROPIC_API_KEY` - Anthropic API key

### Optional
- `MODEL_PROVIDER` - "kimi" (default), "openai", or "anthropic"
- `MODEL_NAME` - Model to use (e.g., "kimi-k2.5")
- `NANOCLAW_BASE_PATH` - Base path for group folders (default: "/workspace/group")
- `WEB_POLICY_GLOBAL_PATH` - Host global web policy path (default `~/.config/nanoclaw/web-policy.global.json`)
- `WEB_BROKER_PORT` - Host relay/web broker port (default `18081`)
- `WEB_FETCH_TIMEOUT_MS` - Default broker timeout (default `30000`)
- `WEB_FETCH_MAX_BYTES` - Default max response bytes (default `1048576`)

## Local Testing (No WhatsApp Required)

You can test the agent locally via CLI:

```bash
export MODEL_PROVIDER=openai
export MODEL_NAME=gpt-5.2
export OPENAI_API_KEY=...your_key...
export NANOCLAW_BASE_PATH=/tmp/test-group

mkdir -p /tmp/test-group

echo '{"prompt":"What is 2+2?"}' | \
  ./.build/debug/nanoclaw-agent --config /tmp/fake.json --group-folder /tmp/test-group --chat-jid test@g.us

echo "Hello" > /tmp/test-group/hello.txt
echo '{"prompt":"Read the file hello.txt"}' | \
  ./.build/debug/nanoclaw-agent --config /tmp/fake.json --group-folder /tmp/test-group --chat-jid test@g.us
```

## Testing Status

**✅ Working:**
- Build on macOS 26 (Tahoe) with Swift 6.2.3
- Apple Containers (tested with ubuntu + swift base)
- API key loading from environment
- OpenAI API calls (GPT-5.2) successful
- Retry logic with exponential backoff (429 handling)
- Local path support (absolute paths)
- CLI argument parsing (no duplicate flags)
- Tool calling verified (ReadTool, WriteTool, BashTool via OpenAI)
- Container networking with `--dns 8.8.8.8`
- Tailscale/`utun` default-route environments auto-switch to host relay path for LLM calls
- Node.js orchestration spawns Swift agent
- File tools work in Apple Containers
- Local CLI test suite passes (test-local.sh)
- `swift test` passing (13 tests: CLI/config/tools/session/tool-call integration, pseudo-tool rejection, schedule/cancel IPC persistence, web policy tool coverage)
- `npm run typecheck` and `npm run build` passing
- `npm run container:smoke` passing (image inspect, metadata list, `--env-file` + `-i` runtime)
- `npm run container:netcheck` passing (default route + DNS + container egress diagnostics)
- **Telegram Integration** (grammY library):
  - Direct message support (DMs without @Andy trigger)
  - Owner-only security (TELEGRAM_OWNER_ID)
  - Auto-creates `telegram-direct` folder
  - Runs alongside WhatsApp (dual channel support)

**⏳ Pending:**
- End-to-end WhatsApp integration test
- Comprehensive unit test coverage
- Production deployment validation

## Known Issues

1. **Kimi API Overloaded** - Getting 429 errors consistently. Retry logic implemented to handle this.
2. **E2E Channel Validation Pending** - Full WhatsApp end-to-end flow still needs live validation.
3. **Local Container Metadata Drift Can Recur** - Stale digest refs in local `container` state can break image-management commands.

## Release Blockers (Must Fix Before Release)

### ✅ FIXED - Container Build + Run
- **Cross-compilation**: Swift binary built for Linux using Static Linux SDK
- **Container image**: `nanoclawswift-agent:static` built successfully
- **Base image**: Uses `swift:6.2.3-slim` (has CA certificates pre-installed)

### ✅ FIXED - Node.js Integration
- Node runtime now acts as channel adapters only (`src/index.ts`, `src/telegram-bot.ts`)
- Swift host (`nanoclaw-host`) owns queueing, scheduling, sessions, and container lifecycle
- Host relay/web broker (`src/host-relay.ts`) provides:
  - provider relay path (`/relay/{provider}/v1`)
  - web policy-enforced broker endpoints (`/web/*`)
- Startup resilience added:
  - relay conflict diagnosis for `EADDRINUSE` on `:18081`
  - clear operational recovery (`lsof` + terminate stale listener + restart)

### ✅ FIXED - Kimi request compatibility
- `OpenAICompatibleProvider` now normalizes temperature for Moonshot/Kimi requests.
- Kimi models that only accept `temperature=1` no longer fail with HTTP 400.
- Validation completed via Telegram E2E after rebuild/restart.

### ✅ MITIGATED - Local container image metadata mismatch
**Observed**: host-level stale digest refs caused `container image ls` failures.

**Mitigation performed**:
- Backed up local state file.
- Removed stale references for `docker.io/library/swift:6.2.3*`.
- Restarted `container` services.

**Validation**:
- `container image ls` succeeds.
- `container run --rm docker.io/alpine:3.20 echo ok` succeeds.
- `container run -i --env-file ...` correctly injects env vars on container 0.9.0.

### 🔄 REMAINING - Test Coverage
- [ ] End-to-end WhatsApp integration test
- [ ] Add comprehensive unit tests
- [ ] Production deployment validation

### ✅ Deployment Gate Completed
- [x] Pull/update builder base image: `docker.io/library/swift:6.2.3-slim`
- [x] Rebuild runtime image: `./container/build-swift.sh slim`
- [x] Confirm runtime behavior after rebuild via Telegram DM flows
- [x] Verify tool availability in-container (`web_fetch`/`web_search`/`web_policy_*`)

## Offline-Mode Checklist (Can Continue Without Image Pull)

- [x] Type safety and compile checks: `npm run typecheck`, `npm run build`
- [x] Swift tests and tool tests passing: `swift test`
- [x] Container runtime smoke checks: `npm run container:smoke`
- [x] Container/VPN diagnostics: `npm run container:netcheck`
- [x] Relay reliability improvement applied in `src/host-relay.ts` with shared upstream keep-alive agents
- [x] Documentation and handover updated for Tailscale/relay behavior and web policy architecture
- [x] Final rebuilt-image E2E (Telegram) completed

## Next Steps

1. **Mac mini bring-up**: follow the runbook in `README.md` ("Mac Mini Bring-Up (Telegram First)").
2. **Resilience**: add optional guarded auto-remediation for stale local image metadata when preflight detects digest drift.
3. **Observability**: emit structured preflight metrics/events for image inspect and metadata checks.
4. **Production Rollout Gate**: collect baseline performance/latency metrics before production cutover.

## Notes

- Kimi API is OpenAI-compatible: https://api.moonshot.ai/v1/chat/completions
- Retry logic is essential for production use due to frequent 429 errors
- File operations use Foundation FileManager (battle-tested)
- All file permissions follow security best practices
- SwiftAgents fork only as last resort
- Swarm migration is phased: dependency source aligned to `Swarm.git` while keeping SwiftAgents 0.3.1 API surface
