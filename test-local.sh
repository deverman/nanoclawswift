#!/bin/bash
# Local testing script for NanoClawSwift without WhatsApp

echo "=== NanoClawSwift Local Test Script ==="
echo ""

# Set API key (from .zshenv or environment)
export OPENAI_API_KEY="${OPENAI_API_KEY:-$(grep OPENAI_API_KEY ~/.zshenv 2>/dev/null | cut -d'=' -f2 | tr -d '"')}"

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

# Test 1: Simple Q&A
echo "Test 1: Simple Q&A"
echo '{"prompt":"What is 2+2? Answer with one word."}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 2: Read file
echo "Test 2: Read a file"
echo "Hello World" > /tmp/test/hello.txt
echo '{"prompt":"Read the file /tmp/test/hello.txt"}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 3: Bash command
echo "Test 3: Run a bash command"
echo '{"prompt":"List files in current directory using ls"}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us
echo ""

# Test 4: Multi-turn conversation
echo "Test 4: Multi-turn (Session persistence)"
echo '{"prompt":"My name is Bob. Remember it."}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us --session-id test-session
echo '{"prompt":"What is my name?"}' | ./.build/debug/nanoclaw-agent --config /tmp/test.json --group-folder /tmp/test --chat-jid test@g.us --session-id test-session
echo ""

# Check session file
echo "📁 Session file created:"
ls -la /tmp/test/.nanoclaw/ 2>/dev/null || echo "   (no session directory yet)"
echo ""

echo "✅ Tests complete!"