#!/bin/bash
# Download pre-built Linux binary (glibc) from GitHub releases
# This avoids building with musl on macOS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

BINARY_DIR=".build/linux-glibc/release"
BINARY_PATH="$BINARY_DIR/nanoclaw-agent"

# GitHub repo info
REPO="deverman/nanoclawswift"
RELEASE_TAG="${1:-nightly}"

echo "=== Downloading NanoClawSwift Linux Binary ==="
echo "Repository: $REPO"
echo "Release: $RELEASE_TAG"
echo ""

# Create directory
mkdir -p "$BINARY_DIR"

# Download URL
if [ "$RELEASE_TAG" = "nightly" ]; then
  # Get latest nightly release
  DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/$REPO/releases" | \
    grep -o '"browser_download_url": "[^"]*nanoclaw-agent"' | \
    head -1 | \
    sed 's/"browser_download_url": "//;s/"$//')
else
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/nanoclaw-agent"
fi

if [ -z "$DOWNLOAD_URL" ]; then
  echo "❌ Could not find download URL"
  echo ""
  echo "Available releases:"
  curl -s "https://api.github.com/repos/$REPO/releases" | \
    grep -o '"tag_name": "[^"]*"' | \
    sed 's/"tag_name": "//;s/"$//' | \
    head -10
  exit 1
fi

echo "📥 Downloading from:"
echo "   $DOWNLOAD_URL"
echo ""

# Download binary
curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"

# Make executable
chmod +x "$BINARY_PATH"

echo "✅ Binary downloaded: $BINARY_PATH"
echo ""

# Verify it's a Linux binary
file "$BINARY_PATH"
echo ""

# Check if it's dynamically linked
if ldd "$BINARY_PATH" 2>/dev/null | grep -q "libc.so"; then
  echo "✅ Binary is dynamically linked with glibc (good!)"
else
  echo "⚠️  Binary appears to be statically linked (may have DNS issues)"
fi

echo ""
echo "Next steps:"
echo "  ./container/build-swift.sh local"
echo "  # or just run: npm run dev"
