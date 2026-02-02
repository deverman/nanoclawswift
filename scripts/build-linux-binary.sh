#!/bin/bash
# Build Linux (aarch64 musl) binary using Swift static Linux SDK

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="${REPO_ROOT}/patches/conduit-musl.patch"

cd "$REPO_ROOT"

echo "Preparing Conduit dependency for musl..."
swift package edit Conduit

if [ -f "$PATCH_FILE" ]; then
  (cd Packages/Conduit && git apply "$PATCH_FILE")
else
  echo "Patch file not found: $PATCH_FILE"
  exit 1
fi

echo "Building Linux binary..."
swift build --swift-sdk aarch64-swift-linux-musl -c release

echo "Cleaning editable package..."
swift package unedit Conduit

echo "Linux build complete."
echo "Binary: .build/aarch64-swift-linux-musl/release/nanoclaw-agent"
