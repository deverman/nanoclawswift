#!/bin/bash
# Local testing script for NanoClawSwift without WhatsApp

echo "=== NanoClawSwift Local Test Script ==="
echo ""

# Set API key (from .zshenv or environment)
export OPENAI_API_KEY="${OPENAI_API_KEY:-$(grep OPENAI_API_KEY ~/.zshenv 2>/dev/null | cut -d'=' -f2 | tr -d '"')}"

# Force OpenAI for local testing (Kimi is often overloaded)
export MODEL_PROVIDER="openai"
export MODEL_NAME="gpt-5.2"
export NANOCLAW_BASE_PATH="/tmp/test"

if [ -z "$OPENAI_API_KEY" ]; then
    echo "❌ ERROR: OPENAI_API_KEY not set"
    echo "   Add to ~/.zshenv: export OPENAI_API_KEY='your-key'"
    exit 1
fi

echo "✅ API key loaded"
echo ""

# Build if needed
if [ ! -f ".build/debug/nanoclaw-agent" ]; then
    echo "🔨 Building..."
    swift build
fi

echo "🧪 Running tests..."
echo ""

# Clean previous session state
rm -rf /tmp/test/.nanoclaw

# Test 1: Simple Q&A (GPT-5.2)
echo "Test 1: Simple Q&A"
echo '{"prompt":"What is 2+2? Answer with one word."}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 2: Read file (force tool call, GPT-4o for tool reliability)
echo "Test 2: Read a file"
export MODEL_NAME="gpt-4o"
echo "Hello World" > /tmp/test/hello.txt
NANOCLAW_TOOL_CHOICE=read \
echo '{"prompt":"Read the file hello.txt and return its contents."}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 3: Bash command (force tool call, GPT-4o)
echo "Test 3: Run a bash command"
NANOCLAW_TOOL_CHOICE=bash \
echo '{"prompt":"List files in current directory using ls"}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 4: Multi-turn conversation (GPT-5.2)
export MODEL_NAME="gpt-5.2"
echo "Test 4: Multi-turn (Session persistence)"
echo '{"prompt":"My name is Bob. Remember it."}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us --session-id test-session
echo '{"prompt":"What is my name?"}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us --session-id test-session
echo ""

# Check session file
echo "📁 Session file created:"
ls -la /tmp/test/.nanoclaw/ 2>/dev/null || echo "   (no session directory yet)"
echo ""

echo "✅ Tests complete!"
