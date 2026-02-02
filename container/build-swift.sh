#!/bin/bash
# Build the NanoClawSwift agent container image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="nanoclawswift-agent"
VERSION="${1:-slim}"
TAG="${IMAGE_NAME}:${VERSION}"

echo "Building NanoClawSwift agent container image..."
echo "Image: ${TAG}"

if [ "$VERSION" = "slim" ]; then
    echo "Building slim version (swift:6.2.3-slim base)..."
    container build -f Dockerfile.slim -t "${TAG}" .
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
