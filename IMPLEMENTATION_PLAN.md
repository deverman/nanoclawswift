# NanoClawSwift Implementation Plan

**Repository**: https://github.com/deverman/nanoclawswift  
**Base**: https://github.com/gavrielc/nanoclaw  
**Branch**: swift-agent  
**Status**: Build Mode - Phase 0-1 Complete, Retry Logic Implemented

## Current Progress

### ✅ Phase 0: Foundation & CI/CD (COMPLETE)

#### ✅ Step 0.1: Repository Setup
- [x] Fork repository from gavrielc/nanoclaw to deverman/nanoclawswift
- [x] Clone the forked repository locally
- [x] Create and switch to swift-agent branch
- [x] Verify clean working directory

#### ✅ Step 0.2: Swift Package Structure
- [x] Create Package.swift with dependencies:
  - SwiftAgents 0.3.1 (EXACT VERSION - PINNED)
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
│                    Node.js Orchestration (UNCHANGED)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────────────┐ │
│  │ WhatsApp │  │Scheduler │  │  IPC     │  │  Container Spawner      │ │
│  │ (baileys)│  │  Loop    │  │ Watcher  │  │  (container-runner.ts)  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────────┬─────────────┘ │
│       │             │             │                    │               │
│       └─────────────┴─────────────┴────────────────────┘               │
│                              │                                         │
│                              ▼                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                      APPLE CONTAINER (Linux VM)                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    nanoclaw-agent (Swift Binary)                  │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ NanoClawAgent (Agent Protocol)                              │ │  │
│  │  │ ├─ Instructions: "You are Andy..."                           │ │  │
│  │  │ ├─ Loop: Guard(.input) → Relay() → Guard(.output)           │ │  │
│  │  │ ├─ Tools: [Read, Write, Edit, Bash, Glob, Grep, IPC*]       │ │  │
│  │  │ ├─ Memory: CLAUDEMemory (global + group CLAUDE.md)          │ │  │
│  │  │ └─ Session: FileBasedSession (JSON persistence)             │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ OpenAICompatibleProvider (InferenceProvider)                │ │  │
│  │  │ ├─ Supports: Kimi, OpenAI, Anthropic (OpenAI-compatible)    │ │  │
│  │  │ ├─ HTTP client (Foundation URLSession)                      │ │  │
│  │  │ ├─ API key from config                                     │ │  │
│  │  │ ├─ Retry logic with exponential backoff for 429 errors     │ │  │
│  │  │ └─ Tool calling support                                     │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ ArchivingHooks (RunHooks)                                   │ │  │
│  │  │ └─ onAgentEnd: Archive to conversations/{date}-{summary}.md│ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  │                                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Mounts:                                                                │
│    • groups/{name}/ → /workspace/group                                  │
│    • groups/CLAUDE.md → /workspace/group/../CLAUDE.md (global)         │
│    • data/ipc/ → /workspace/ipc                                         │
│    • data/sessions/{group}.json → /workspace/session.json               │
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

### Phase 2: File-Based Session Persistence 🔄
- [x] Create FileBasedSession with JSON persistence
- [x] **FIXED:** Support both container and local paths (absolute paths starting with "/")
- [x] Secure file permissions
- [x] Write tests

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

### Phase 5: Web Tools (Deferred) ⏳

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
    timeout: Int = 60,
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
- Apple Containers (tested with alpine)
- API key loading from environment
- OpenAI API calls (GPT-5.2) successful
- Retry logic with exponential backoff (429 handling)
- Local path support (absolute paths)
- CLI argument parsing (no duplicate flags)
- Tool calling verified (ReadTool via OpenAI)
- Tool calling verified (BashTool via OpenAI)
- Local CLI test suite passes (test-local.sh)

**⏳ Pending:**
- Container build test (Swift agent image)
- Integration with Node.js orchestration
- Unit test suite (still minimal)
 - Container network access to external APIs (blocked in Apple containers)

## Known Issues

1. **Kimi API Overloaded** - Getting 429 errors consistently. Retry logic implemented to handle this.
2. **No Comprehensive Tests** - Only placeholder tests exist.
3. **Container Not Tested** - Dockerfile created but not validated.

## Release Blockers (Must Fix Before Release)

1. **Container Build + Run**
   - Build Swift container image
   - Run end-to-end agent inside Apple container

2. **Node.js Integration**
   - Verify container runner spawns Swift agent
   - Validate IPC files are written and consumed

3. **Test Coverage**
   - Add unit tests for ConfigLoader, tools, sessions
   - Add integration test for tool calling

4. **Container Networking**
   - Apple containers currently cannot resolve external hosts (DNS failure)
   - `container run` has no outbound network even with `--dns 8.8.8.8`
   - Must enable outbound networking or configure container system networking
   - Without this, OpenAI/Kimi API calls fail inside container

## Next Steps

1. Wait for Kimi API capacity or try during off-peak hours
2. Test container build: `./container/build-swift.sh slim`
3. Write comprehensive unit tests
4. Integration test with Node.js orchestration
5. Production deployment

## Notes

- Kimi API is OpenAI-compatible: https://api.moonshot.ai/v1/chat/completions
- Retry logic is essential for production use due to frequent 429 errors
- File operations use Foundation FileManager (battle-tested)
- All file permissions follow security best practices
- SwiftAgents fork only as last resort
