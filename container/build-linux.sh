#!/bin/bash
# Build NanoClawSwift agent for Linux (cross-compile on macOS)
# Uses Swift Static Linux SDK to create a fully static binary

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

echo "=== NanoClawSwift Linux Build ==="
echo ""

# Find the static Linux SDK
SDK_PATH="${HOME}/.swiftpm/swift-sdks/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle"
if [ ! -d "$SDK_PATH" ]; then
    echo "❌ Static Linux SDK not found at $SDK_PATH"
    echo "   Install with: swift sdk install \
        https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \
        --checksum d4f46ba40e11e697387468e189897bb5f7bc6c93"
    exit 1
fi

echo "✅ Found Static Linux SDK"

# Build directory for Linux
BUILD_DIR=".build/linux/release"
mkdir -p "$BUILD_DIR"

echo "🔨 Building static Linux binary..."
echo "   Target: aarch64-unknown-linux-musl"
echo "   Output: $BUILD_DIR/nanoclaw-agent"
echo ""

# Build with static SDK (use correct SDK name)
swift build -c release \
    --product nanoclaw-agent \
    --swift-sdk swift-6.2.3-RELEASE_static-linux-0.0.1 \
    --build-path "$BUILD_DIR"

# The binary is actually in a different location with the SDK
# Let's find it
BINARY_PATH=$(find "$BUILD_DIR" -name "nanoclaw-agent" -type f | head -1)

if [ -z "$BINARY_PATH" ]; then
    echo "❌ Binary not found in $BUILD_DIR"
    exit 1
fi

echo "✅ Binary built: $BINARY_PATH"
echo ""

# Check if it's actually static
echo "📊 Binary info:"
file "$BINARY_PATH"
echo ""

# Copy to expected location for Dockerfile
mkdir -p "$BUILD_DIR"
cp "$BINARY_PATH" "$BUILD_DIR/nanoclaw-agent"

echo "✅ Build complete!"
echo ""
echo "Next steps:"
echo "  1. Build container: swift run nanoclaw-devctl build-agent-image slim"
echo "  2. Test locally: ./container/test-swift.sh"
