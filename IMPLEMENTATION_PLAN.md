# NanoClawSwift Implementation Plan

**Repository**: https://github.com/deverman/nanoclawswift  
**Base**: https://github.com/gavrielc/nanoclaw  
**Branch**: swift-agent  
**Status**: Build Mode

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

### Phase 0: Foundation & CI/CD (Shift-Left)

#### Step 0.1: Repository Setup
- [x] Fork repository from gavrielc/nanoclaw to deverman/nanoclawswift
- [ ] Clone the forked repository locally
- [ ] Create and switch to swift-agent branch
- [ ] Verify clean working directory

#### Step 0.2: Swift Package Structure
- [ ] Create Package.swift with dependencies:
  - SwiftAgents 0.3.1 (EXACT VERSION - PINNED)
  - swift-argument-parser 1.5.0+
  - swift-configuration 1.0.2+
- [ ] Create Sources/NanoClawAgent/ directory structure
- [ ] Create Tests/NanoClawAgentTests/ directory
- [ ] Run `swift package resolve` to verify dependencies
- [ ] Run `swift build` to verify empty package builds

#### Step 0.3: CI/CD Pipeline
- [ ] Create .github/workflows/ci.yml
- [ ] Configure Swift setup (version 6.2.3)
- [ ] Add build step
- [ ] Add test step
- [ ] Add container build step
- [ ] Push to trigger workflow
- [ ] Validate using `gh run list` and `gh workflow view`

#### Step 0.4: Container Setup
- [ ] Create container/Dockerfile.slim (swift:6.2.3-slim)
- [ ] Create container/build.sh script
- [ ] Test container builds locally
- [ ] Verify container runs with echo test

### Phase 1: Core Infrastructure

#### Step 1.1: Type-Safe Configuration
- [ ] Create Configuration/ModelProvider.swift (enum: kimi, openai, anthropic)
- [ ] Create Configuration/ModelName.swift (enum with all model variants)
- [ ] Create Configuration/NanoClawConfig.swift (struct with Codable)
- [ ] Create Configuration/ConfigLoader.swift (swift-configuration integration)
- [ ] Write tests for config loading
- [ ] Write tests for enum validation

#### Step 1.2: Async CLI
- [ ] Create main.swift with AsyncParsableCommand
- [ ] Implement argument parsing:
  - --config (default: /workspace/config.json)
  - --group-folder (required)
  - --session-id (optional)
  - --chat-jid (required)
  - --is-main (flag)
  - --is-scheduled-task (flag)
- [ ] Implement async stdin reading
- [ ] Add output markers (---NANOCLAW_OUTPUT_START--- / END)
- [ ] Write tests for CLI parsing

#### Step 1.3: OpenAI-Compatible Provider
- [ ] Create Providers/OpenAICompatibleProvider.swift
- [ ] Implement InferenceProvider protocol:
  - generate(prompt:options:)
  - generateWithToolCalls(prompt:tools:options:)
  - stream(prompt:options:)
- [ ] Implement chat completion request/response
- [ ] Implement tool calling support
- [ ] Implement streaming with AsyncThrowingStream
- [ ] Add error handling (401, 429, 500, timeout)
- [ ] Write unit tests with mock HTTP responses
- [ ] Write integration test (connect to real API with test key)

### Phase 2: File-Based Session Persistence

#### Step 2.1: Secure FileBasedSession
- [ ] Create Memory/FileBasedSession.swift
- [ ] Implement Session protocol:
  - sessionId: String
  - itemCount: Int
  - getItems(limit:)
  - addItems(_:)
  - popItem()
  - clearSession()
- [ ] Implement secure file operations:
  - Directory creation with 0o750 permissions
  - File write with 0o640 permissions
  - Atomic writes (temp file + rename)
- [ ] Implement JSON persistence with Codable
- [ ] Write tests for session persistence
- [ ] Write tests for file permissions
- [ ] Write tests for concurrent access

#### Step 2.2: Conversation Archiving
- [ ] Create Hooks/ArchivingHooks.swift
- [ ] Implement RunHooks protocol:
  - onAgentEnd(context:agent:result:)
- [ ] Implement transcript archiving:
  - Parse session messages
  - Generate summary for filename
  - Format as Markdown
  - Write to conversations/{date}-{summary}.md
- [ ] Update sessions-index.json
- [ ] Write tests for archiving

### Phase 3: Tools Implementation

#### Step 3.1: File System Tools
- [ ] Create Tools/FileSystem/ReadTool.swift:
  - Use FileManager to read files
  - Support line limit parameter
  - Handle missing files gracefully
- [ ] Create Tools/FileSystem/WriteTool.swift:
  - Use FileManager for atomic writes
  - Support append mode
  - Create intermediate directories
- [ ] Create Tools/FileSystem/EditTool.swift:
  - Use String.replacingOccurrences with .regularExpression
  - Support regex and literal matching
  - Atomic file updates
- [ ] Create Tools/FileSystem/GlobTool.swift:
  - Use FileManager.enumerator for ** patterns
  - Use FileManager.contentsOfDirectory for simple patterns
  - Support *, **, ? wildcards
- [ ] Create Tools/FileSystem/GrepTool.swift:
  - Use String.range(of:options: .regularExpression)
  - Support regex and literal search
  - Return file:line:content format
- [ ] Write comprehensive tests for all tools

#### Step 3.2: Bash Tool
- [ ] Create Tools/BashTool.swift:
  - Use Foundation Process API
  - Support working directory parameter
  - Implement timeout handling
  - Capture stdout/stderr
  - Handle non-zero exit codes
- [ ] Write tests for command execution
- [ ] Write tests for timeout handling
- [ ] Write tests for error handling

#### Step 3.3: IPC Tools
- [ ] Create Tools/IPC/SendMessageTool.swift:
  - Write JSON to /workspace/ipc/messages/
- [ ] Create Tools/IPC/ScheduleTaskTool.swift
- [ ] Create Tools/IPC/ListTasksTool.swift
- [ ] Create Tools/IPC/PauseTaskTool.swift
- [ ] Create Tools/IPC/ResumeTaskTool.swift
- [ ] Create Tools/IPC/CancelTaskTool.swift
- [ ] Write tests for IPC file creation
- [ ] Write tests for JSON format

### Phase 4: Agent Assembly

#### Step 4.1: CLAUDEMemory
- [ ] Create Memory/CLAUDEMemory.swift
- [ ] Implement Memory protocol:
  - context(for:tokenLimit:)
  - add(_:)
- [ ] Load global CLAUDE.md from parent directory
- [ ] Load group CLAUDE.md from current directory
- [ ] Combine contexts with headers

#### Step 4.2: NanoClawAgent
- [ ] Create NanoClawAgent.swift (main agent struct)
- [ ] Create NanoClawAgentCore (Agent protocol implementation)
- [ ] Implement run() method with:
  - Prompt formatting (messages XML)
  - Scheduled task prefix handling
  - Provider creation
  - Session management
  - Memory loading
  - Tool assembly
  - Hooks setup
- [ ] Define instructions with assistant name (ASSISTANT_NAME env)
- [ ] Define AgentLoop with Guard + Relay + Guard
- [ ] Write integration tests

#### Step 4.3: Container Integration
- [ ] Finalize Dockerfile.slim
- [ ] Create non-root user (nanoclaw, uid 1000)
- [ ] Set proper file permissions
- [ ] Test end-to-end in container:
  - Message processing
  - Tool execution
  - Session persistence
  - Conversation archiving
- [ ] Test IPC communication with Node.js

### Phase 5: Web Tools (Deferred)

#### Step 5.1: WebFetch Tool (Post-MVP)
- [ ] Create WebFetchTool using URLSession
- [ ] Handle HTTP GET requests
- [ ] Support timeout and redirects

#### Step 5.2: WebSearch Tool (Post-MVP)
- [ ] Integrate with Tavily or SerpAPI
- [ ] Implement search query handling
- [ ] Format search results

## Dependencies

### Swift Packages
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/SwiftAgents.git", exact: "0.3.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "1.0.2"),
]
```

### Container
- Base: `swift:6.2.3-slim` (initially)
- Target: `scratch` + static binary (future)

## Security Measures

### File Permissions
- Directories: `0o750` (rwxr-x---)
- Files: `0o640` (rw-r-----)
- No chmod 777 anywhere

### API Keys
- Loaded from environment variables or config file
- Never logged or exposed
- Mounted securely into container

### Container
- Runs as non-root user (nanoclaw, uid 1000)
- Minimal attack surface (slim image)
- Read-only mounts where possible

## Testing Strategy

### Unit Tests
- Each component tested in isolation
- Mock dependencies where appropriate
- Test error conditions

### Integration Tests
- Container builds and runs
- Agent processes messages end-to-end
- Session persistence works
- IPC communication functions

### CI/CD
- GitHub Actions runs on every push
- Tests run on macOS (matching deployment target)
- Container build verified

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| SwiftAgents API changes | Pin to exact version (0.3.1), only fork if necessary |
| File permission issues | Use POSIX permissions (750/640), proper ownership |
| Tool bugs | Use battle-tested Foundation APIs only |
| Kimi API changes | OpenAI-compatible format, works with standard client |
| Container startup failures | Use slim image first, debuggable |
| Concurrency bugs | Proper actor isolation, async/await patterns |

## Progress Tracking

- [ ] Phase 0 Complete
- [ ] Phase 1 Complete
- [ ] Phase 2 Complete
- [ ] Phase 3 Complete
- [ ] Phase 4 Complete
- [ ] Phase 5 Complete (Deferred)

## Notes

- Kimi API is OpenAI-compatible: https://api.moonshot.ai/v1/chat/completions
- File operations use Foundation FileManager (battle-tested)
- String operations use Swift standard library
- All file permissions follow security best practices
- No external dependencies for core file operations
- SwiftAgents fork only as last resort
