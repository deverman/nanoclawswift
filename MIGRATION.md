# Migration Guide: Node.js → Swift

## Overview

This project is migrating from the Node.js/Claude SDK implementation to a Swift/SwiftAgents implementation for better performance, type safety, and model agnosticism.

## What Changed

### Architecture Changes

| Component | Old (Node.js) | New (Swift) | Status |
|-----------|---------------|-------------|--------|
| **Agent SDK** | Claude SDK | SwiftAgents 0.3.1 | ✅ Complete |
| **Language** | TypeScript | Swift 6.0 | ✅ Complete |
| **Container Base** | Node.js Alpine | Swift 6.0 Slim | ✅ Complete |
| **LLM Provider** | Anthropic only | Kimi/OpenAI/Anthropic | ✅ Complete |
| **Session Storage** | Claude SDK managed | File-based JSON | ✅ Complete |
| **Tools** | Claude SDK built-in | SwiftAgents @Tool macros | ✅ Complete |

### File Structure Changes

**Old Structure:**
```
nanoclaw/
├── container/
│   ├── agent-runner/          # Node.js TypeScript
│   │   ├── src/
│   │   │   ├── index.ts
│   │   │   └── ipc-mcp.ts
│   │   └── package.json
│   └── Dockerfile
├── src/                       # Node.js orchestration
│   ├── index.ts
│   ├── container-runner.ts
│   ├── task-scheduler.ts
│   └── db.ts
└── package.json
```

**New Structure:**
```
nanoclawswift/
├── Sources/NanoClawAgent/     # Swift implementation
│   ├── NanoClawAgent.swift
│   ├── NanoClawAgentCLI.swift
│   ├── Configuration/
│   ├── Providers/
│   ├── Tools/
│   ├── Memory/
│   └── Hooks/
├── container/
│   ├── Dockerfile.slim        # Swift container
│   └── build-swift.sh
└── Package.swift
```

## Files Being Replaced

### Container Agent (Complete Replacement)
- ❌ `container/agent-runner/` → ✅ `Sources/NanoClawAgent/`
- ❌ `container/agent-runner/src/index.ts` → ✅ `Sources/NanoClawAgent/NanoClawAgentCLI.swift`
- ❌ `container/agent-runner/src/ipc-mcp.ts` → ✅ `Sources/NanoClawAgent/Tools/IPC/IPCTools.swift`

### Orchestration Layer (Unchanged)
- ✅ `src/index.ts` - Still used (Node.js WhatsApp/scheduler)
- ✅ `src/container-runner.ts` - Still used (spawns containers)
- ✅ `src/task-scheduler.ts` - Still used
- ✅ `src/db.ts` - Still used

### Configuration
- ❌ `container/agent-runner/package.json` → ✅ `Package.swift`
- ❌ `container/Dockerfile` → ✅ `container/Dockerfile.slim`

## What to Do with Old Files

### Option 1: Archive (Recommended)
Keep old files for reference during migration:
```bash
# Create archive directory
mkdir -p archive/node-agent
mv container/agent-runner archive/node-agent/
mv container/Dockerfile archive/node-agent/
```

### Option 2: Delete (After Testing)
Once Swift agent is fully tested:
```bash
rm -rf container/agent-runner
rm container/Dockerfile
# Keep package.json in root for Node.js orchestration
```

### Option 3: Parallel Operation
Run both implementations side-by-side during transition:
- Rename old container image: `nanoclaw-agent:nodejs`
- New container image: `nanoclawswift-agent:swift`
- Update `src/container-runner.ts` to choose based on config

## Migration Steps

### Phase 1: Setup (Current)
1. ✅ Swift package structure created
2. ✅ CI/CD workflow configured
3. ✅ Basic CLI implemented
4. ✅ Container image ready

### Phase 2: Testing (Next)
1. Test Swift binary locally
2. Test container build
3. Test with Node.js orchestration
4. Verify IPC communication
5. Test session persistence

### Phase 3: Cutover (After Testing)
1. Update `src/container-runner.ts` to use new image
2. Test in development environment
3. Deploy to production
4. Monitor for issues
5. Archive old files

### Phase 4: Cleanup (After Stable)
1. Remove old agent-runner directory
2. Update documentation
3. Remove Node.js dependencies from container
4. Clean up git history

## Breaking Changes

### API Changes
| Old (Claude SDK) | New (SwiftAgents) | Impact |
|------------------|-------------------|--------|
| `query({ prompt, options })` | `agent.run(input, session:)` | Medium |
| `resume: sessionId` | Pass `session` parameter | Low |
| `allowedTools: ['Bash', ...]` | `agent.tools` array | Low |
| `mcpServers` | Tools implement IPC directly | Medium |
| `hooks: { PreCompact: ... }` | `ArchivingHooks` actor | Low |

### Configuration Changes
**Old (config.json for Claude SDK):**
```json
{
  "mcpServers": {
    "nanoclaw": { ... }
  }
}
```

**New (config.json for Swift agent):**
```json
{
  "api_key": "sk-...",
  "model_provider": "kimi",
  "model_name": "kimi-k2.5",
  "timeout": 60
}
```

### Tool Names
**Old:**
- `mcp__nanoclaw__send_message`
- `mcp__nanoclaw__schedule_task`
- `Bash`, `Read`, `Write`, `Edit`

**New:**
- `send_message` (SendMessageTool)
- `schedule_task` (ScheduleTaskTool)
- `bash` (BashTool)
- `read_file` (ReadTool)
- `write_file` (WriteTool)
- `edit_file` (EditTool)

## Rollback Plan

If issues occur after migration:

1. **Immediate Rollback:**
   ```bash
   # Update container-runner.ts to use old image
   git checkout main -- src/container-runner.ts
   npm run build
   ```

2. **Data Preservation:**
   - Sessions stored in different formats (Claude SDK vs JSON)
   - Conversations archived to same location
   - IPC files use same format

3. **Monitoring:**
   - Watch error rates
   - Monitor response times
   - Check session continuity
   - Verify tool execution

## Verification Checklist

Before declaring migration complete:

- [ ] Swift binary builds successfully
- [ ] Container image builds successfully
- [ ] Local test passes (echo test)
- [ ] Integration with Node.js works
- [ ] WhatsApp messages process correctly
- [ ] Sessions persist across restarts
- [ ] Tools execute (Bash, Read, Write)
- [ ] IPC communication functions
- [ ] Scheduled tasks work
- [ ] Conversation archiving works
- [ ] Performance is acceptable (< 5s response)
- [ ] No memory leaks (24h test)
- [ ] Error handling works
- [ ] Rollback tested

## Current Status

**✅ Phase 1 Complete:** Swift implementation ready
**⏳ Phase 2 Ready:** Testing phase can begin
**⏸️ Phase 3 Waiting:** Needs integration testing
**⏸️ Phase 4 Waiting:** Needs production validation

## Questions?

See PRODUCTION_READINESS.md for detailed issues and mitigations.
See README.md for setup instructions.
