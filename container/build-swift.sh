#!/bin/bash
# Build the NanoClawSwift agent container image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

IMAGE_NAME="nanoclawswift-agent"
VERSION="${1:-slim}"
TAG="${IMAGE_NAME}:${VERSION}"

echo "Building NanoClawSwift agent container image..."
echo "Image: ${TAG}"

# Stage binary into container/bin for build context
LINUX_BIN_SOURCE="${REPO_ROOT}/.build/aarch64-swift-linux-musl/release/nanoclaw-agent"
DARWIN_BIN_SOURCE="${REPO_ROOT}/.build/release/nanoclaw-agent"
BIN_SOURCE="${LINUX_BIN_SOURCE}"

if [ ! -f "$BIN_SOURCE" ]; then
    BIN_SOURCE="${DARWIN_BIN_SOURCE}"
fi
BIN_TARGET="${REPO_ROOT}/container/bin/nanoclaw-agent"

if [ ! -f "$BIN_SOURCE" ]; then
    echo "❌ Release binary not found."
    echo "   Expected Linux: ${LINUX_BIN_SOURCE}"
    echo "   Expected macOS: ${DARWIN_BIN_SOURCE}"
    echo "   Run: swift build --swift-sdk aarch64-swift-linux-musl -c release"
    exit 1
fi

mkdir -p "${REPO_ROOT}/container/bin"
cp -f "$BIN_SOURCE" "$BIN_TARGET"
chmod +x "$BIN_TARGET"

if [ "$VERSION" = "slim" ]; then
    echo "Building slim version (swift:6.2.3-slim base)..."
    container build -f container/Dockerfile.slim -t "${TAG}" .
elif [ "$VERSION" = "static" ]; then
    echo "Static build not yet implemented"
    exit 1
else
    echo "Unknown version: ${VERSION}"
    echo "Usage: $0 [slim|static]"
    exit 1
fi

echo ""
echo "Build complete!"
echo "Image: ${TAG}"
echo ""
echo "Test with:"
echo "  echo '{\"prompt\":\"What is 2+2?\",\"groupFolder\":\"test\",\"chatJid\":\"test@g.us\",\"isMain\":false}' | container run -i ${TAG}"
