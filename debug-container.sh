#!/bin/bash
# Debug Telegram container issue

echo "=== Debugging Telegram Container ==="
echo ""

# Test 1: Check if container can reach internet
echo "Test 1: Checking container network..."
container run --rm --dns 8.8.8.8 swift:6.2.3-slim curl -s --max-time 10 https://api.openai.com/v1/models 2>&1 | head -5 || echo "Failed to reach API"

echo ""
echo "Test 2: Checking DNS resolution..."
container run --rm --dns 8.8.8.8 swift:6.2.3-slim sh -c "cat /etc/resolv.conf" 2>&1

echo ""
echo "Test 3: Running Swift agent with debug output..."
echo "Hello" | container run -i --rm \
  --dns 8.8.8.8 \
  -e MODEL_PROVIDER=openai \
  -e MODEL_NAME=gpt-5.2 \
  -e OPENAI_API_KEY="${OPENAI_API_KEY}" \
  -v "$(pwd)/groups/telegram-direct":/workspace/group \
  nanoclawswift-agent:static \
  --config /tmp/fake.json \
  --group-folder /workspace/group \
  --chat-jid telegram_135937217@direct 2>&1 &
PID=$!
sleep 30
kill $PID 2>/dev/null

echo ""
echo "Test complete"
