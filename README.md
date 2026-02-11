<p align="center">
  <img src="assets/nanoclaw-logo.png" alt="NanoClawSwift" width="400">
</p>

<p align="center">
  My personal AI assistant that runs securely in Apple containers. 
  Now with Swift Agents, multi-model support (Kimi, OpenAI, Anthropic), and blazing fast performance.
</p>

## Overview

**NanoClawSwift** is a complete rewrite of NanoClaw in Swift, built with the SwiftAgents framework (from the renamed `Swarm` repository). It maintains the same security-by-isolation philosophy while adding model agnosticism, better performance, and modern Swift concurrency.

### Key Improvements

- **🚀 Swift Performance** - Native binary, no Node.js overhead
- **🤖 Multi-Model Support** - Kimi K2.5, OpenAI GPT-4, Anthropic Claude
- **🔒 Type Safety** - Swift's type system catches errors at compile time
- **⚡ Modern Concurrency** - async/await throughout
- **🧪 Better Testing** - Swift Testing framework
- **📦 Smaller Containers** - ~20MB static binary vs 200MB+ Node.js

## Quick Start

```bash
# Clone the Swift fork
git clone https://github.com/deverman/nanoclawswift.git
cd nanoclawswift
git checkout swift-agent

# Build the Swift agent
swift build -c release

# Configure your API key
export MOONSHOT_API_KEY="your-kimi-api-key"

# Test locally
echo '{"prompt":"What is 2+2?"}' | ./.build/release/nanoclaw-agent --group-folder test --chat-jid test@g.us
```

## Mac Mini Bring-Up (Telegram First)

```bash
# 1) Clone and enter repo
git clone https://github.com/deverman/nanoclawswift.git
cd nanoclawswift
git checkout swift-agent

# 2) Use Node 24.6.0
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm use 24.6.0
export PATH="$NVM_DIR/versions/node/v24.6.0/bin:$PATH"

# 3) Install dependencies
npm ci

# 4) Build/verify Swift runtime
swift test
./container/build-swift.sh slim

# 5) Export required env vars
export MOONSHOT_API_KEY="sk-..."
export TELEGRAM_BOT_TOKEN="..."
export TELEGRAM_OWNER_ID="..."
export MODEL_PROVIDER="kimi"
export MODEL_NAME="kimi-k2.5"
export CONTAINER_LLM_RELAY_MODE="auto"

# 6) Start app (Telegram-only mode)
WHATSAPP_ENABLED=0 npm run dev
```

Troubleshooting:
- If you see `EADDRINUSE ... 0.0.0.0:18081`, another stale dev process is holding relay port 18081; stop it, then restart `npm run dev`.
- If Kimi returns `invalid temperature: only 1 is allowed for this model`, rebuild the image (`./container/build-swift.sh slim`) and restart; provider now forces compatible temperature for Kimi.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           HOST (macOS)                                  │
│                    Node.js Orchestration (UNCHANGED)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────────────┐ │
│  │ WhatsApp │  │Scheduler │  │  IPC     │  │  Container Spawner      │ │
│  │ (baileys)│  │  Loop    │  │ Watcher  │  │  (container-runner.ts)  │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────────┬─────────────┘ │
│       └─────────────┴─────────────┴────────────────────┘               │
│                              │                                         │
│                              ▼                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                      APPLE CONTAINER (Linux VM)                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    nanoclaw-agent (Swift Binary)                  │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ NanoClawAgent (SwiftAgents Framework)                       │ │  │
│  │  │ ├─ ToolCallingAgent (native structured tool calls)          │ │  │
│  │  │ ├─ FileSystem, Bash, IPC, WebFetch/WebSearch Tools          │ │  │
│  │  │ ├─ CLAUDEMemory (CLAUDE.md context)                         │ │  │
│  │  │ └─ FileBasedSession (JSON persistence)                      │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐ │  │
│  │  │ OpenAICompatibleProvider                                    │ │  │
│  │  │ ├─ Kimi API (Moonshot)                                      │ │  │
│  │  │ ├─ OpenAI API                                               │ │  │
│  │  │ └─ Anthropic API (via OpenRouter)                          │ │  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

## Configuration

### API Key Setup

**Option 1: Environment Variables**
```bash
export MOONSHOT_API_KEY="sk-your-kimi-key"
export MODEL_PROVIDER="kimi"  # or "openai", "anthropic"
export MODEL_NAME="kimi-k2.5"
```

**Option 2: Config File**
Create `/workspace/config.json`:
```json
{
  "api_key": "sk-your-kimi-key",
  "model_provider": "kimi",
  "model_name": "kimi-k2.5",
  "timeout": 60
}
```

**Getting a Kimi API Key:**
1. Visit https://platform.moonshot.ai/
2. Create an account
3. Generate API key in console
4. Copy key (starts with `sk-`)

### CLI Arguments

```bash
./nanoclaw-agent \
  --config /workspace/config.json \
  --group-folder myproject \
  --chat-jid 12345@g.us \
  --session-id optional-session-id \
  --is-main \
  --is-scheduled-task
```

### Web Policy Configuration

NanoClaw now uses a two-layer web policy model:

- Global baseline (host-managed): `~/.config/nanoclaw/web-policy.global.json`
- Group overlay (container-writable): `groups/<group>/.nanoclaw/web-policy.overlay.json`

Use `config-examples/web-policy.global.json` as a template.

## Philosophy (Still True)

**Small enough to understand.** The Swift implementation is ~2,000 lines vs 10,000+ in the original.

**Secure by isolation.** Agents still run in Apple containers with filesystem isolation. Nothing runs on your Mac directly.

**Built for one user.** Fork it, customize it. The codebase is small enough to be safe to modify.

**Customization = code changes.** No YAML configs. Want different behavior? Edit the Swift code.

**AI-native.** Claude Code guides setup and debugging.

**Best harness, best model.** Now using SwiftAgents framework with your choice of model (Kimi K2.5 recommended).

## What It Supports

- **WhatsApp I/O** - Message your AI from your phone
- **Multi-Model LLMs** - Kimi K2.5, OpenAI GPT-4, Anthropic Claude
- **Isolated group context** - Each group has its own CLAUDE.md and filesystem sandbox
- **Main channel** - Private admin channel with special privileges
- **Scheduled tasks** - Recurring jobs with cron syntax
- **Container isolation** - Apple containers with filesystem mounts
- **File tools** - Read, write, edit, glob, grep files safely
- **Bash execution** - Commands run inside container, not on host
- **Web tools** - `web_fetch` / `web_search` via host broker (works with Tailscale exit-node routing)
- **Group-scoped web policy** - Container can directly manage per-group overlay allowlist
- **Strict tool-call policy** - Raw ````tool ...```` text blocks are never executed
- **IPC communication** - Send WhatsApp messages, schedule tasks
- **Session persistence** - Conversation history in JSON files
- **Conversation archiving** - Automatic transcript saving

## Swarm Version Note

This repo currently pins `Swarm` to `0.3.1` for build stability.  
`0.3.4` introduces a transitive `Hive` dependency path that is not consumable in this environment (`/Package.swift` resolution failure), so migration work targets Swarm-native APIs while staying on the stable pin.

## Project Structure

```
nanoclawswift/
├── Sources/NanoClawAgent/         # Swift implementation
│   ├── NanoClawAgentCLI.swift     # CLI entry point
│   ├── NanoClawAgent.swift        # Agent implementation
│   ├── Configuration/             # Config loading
│   ├── Providers/                 # LLM providers (Kimi, OpenAI)
│   ├── Tools/                     # FileSystem, Bash, IPC, Web tools
│   ├── Memory/                    # Session & CLAUDE.md
│   └── Hooks/                     # Conversation archiving
├── Tests/                         # Swift tests
├── container/
│   ├── Dockerfile.slim            # Swift 6.0 container
│   └── build-swift.sh             # Build script
├── Package.swift                  # Swift Package Manager
└── .github/workflows/ci.yml       # CI/CD
```

## Development

### Build
```bash
swift build
swift build -c release
```

### Test
```bash
swift test
```

### Run
```bash
# Local development
echo '{"prompt":"Hello"}' | swift run nanoclaw-agent --group-folder test --chat-jid test@g.us

# With container
./container/build-swift.sh slim

# Or use container CLI directly:
container build -f container/Dockerfile.slim -t nanoclawswift-agent:slim .

container run -i --rm \
  -e MODEL_PROVIDER=openai \
  -e MODEL_NAME=gpt-5.2 \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  --mount type=bind,source=/tmp/test,target=/workspace/group \
  nanoclawswift-agent:slim \
  --config /tmp/fake.json \
  --group-folder /workspace/group \
  --chat-jid test@g.us
```

## Telegram E2E Smoke

After `WHATSAPP_ENABLED=0 npm run dev`:
1. DM the bot: `what tools do you have?`
2. DM: `what is scheduled?`
3. DM: `schedule a recurring 08:00 test task`
4. DM: `list tasks`
5. DM: `cancel task <id>`
6. DM: `list tasks`

## Production Readiness

See PRODUCTION_READINESS.md for:
- Issues encountered and mitigations
- Monitoring via GitHub CLI
- Production checklist
- Security hardening
- Performance optimization

## CI/CD Status

[![CI](https://github.com/deverman/nanoclawswift/actions/workflows/ci.yml/badge.svg?branch=swift-agent)](https://github.com/deverman/nanoclawswift/actions/workflows/ci.yml)

**Build:** Swift 6.0 on macOS  
**Test:** Automated on every push  
**Container:** Automatic builds  

## Documentation

- **Setup:** This README
- **Migration:** MIGRATION.md
- **Production:** PRODUCTION_READINESS.md
- **Architecture:** IMPLEMENTATION_PLAN.md

## Status

**Current:** Phase 1 (Core Implementation) ✅ Complete  
**Next:** Phase 2 (Integration Testing)  
**Target:** Production ready by Q1 2026

## License

Same as original NanoClaw - see LICENSE file.

## Credits

- Original NanoClaw by Gavriel Cohen
- SwiftAgents framework by Christopher Karani (repo renamed to Swarm)
- Kimi API by Moonshot AI
- Swift Argument Parser by Apple
