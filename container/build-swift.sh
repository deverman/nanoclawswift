#!/bin/bash
# Build the NanoClawSwift agent container image.
#
# Supported modes:
# - slim  (default): build Linux binary inside swift:6.2.3, then package with Dockerfile.slim
# - static: legacy static-SDK path (best-effort)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

IMAGE_NAME="nanoclawswift-agent"
MODE="${1:-slim}"
TAG="${IMAGE_NAME}:${MODE}"

# Prefer Homebrew container CLI if available.
CONTAINER_CLI="${CONTAINER_CLI:-container}"
if [ -x "/opt/homebrew/opt/container/bin/container" ]; then
    CONTAINER_CLI="/opt/homebrew/opt/container/bin/container"
fi

echo "Building NanoClawSwift agent container image..."
echo "Mode: ${MODE}"
echo "Tag:  ${TAG}"
echo

build_slim() {
    echo "Step 1: Building Linux executable product in swift:6.2.3..."
    "$CONTAINER_CLI" run --rm --memory 8g \
        -v "${REPO_ROOT}:/work" \
        -w /work \
        docker.io/library/swift:6.2.3 \
        sh -lc 'swift build -c release --product nanoclaw-agent && cp .build/release/nanoclaw-agent /work/.build/linux-output-nanoclaw-agent'

    if [ ! -f ".build/linux-output-nanoclaw-agent" ]; then
        echo "ERROR: .build/linux-output-nanoclaw-agent was not produced"
        exit 1
    fi

    file ".build/linux-output-nanoclaw-agent"
    echo

    echo "Step 2: Packaging image with container/Dockerfile.slim..."
    "$CONTAINER_CLI" build -f "${SCRIPT_DIR}/Dockerfile.slim" -t "${TAG}" .
}

build_static() {
    echo "Using legacy static SDK flow..."
    SDK_NAME="swift-6.2.3-RELEASE_static-linux-0.0.1"
    if ! swift sdk list | grep -q "$SDK_NAME"; then
        echo "ERROR: Static Linux SDK not found"
        echo "Install with:"
        echo "  swift sdk install \\"
        echo "    https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz \\"
        echo "    --checksum d4f46ba40e11e697387468e189897bb5f7bc6c93"
        exit 1
    fi

    swift build -c release --product nanoclaw-agent --swift-sdk "$SDK_NAME"

    BINARY_PATH=".build/aarch64-swift-linux-musl/release/nanoclaw-agent"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "ERROR: Binary not found at $BINARY_PATH"
        exit 1
    fi

    DOCKERFILE="${SCRIPT_DIR}/Dockerfile.static"
    cat > "$DOCKERFILE" << 'EOF'
FROM swift:6.2.3-slim
COPY .build/aarch64-swift-linux-musl/release/nanoclaw-agent /app/nanoclaw-agent
ENV SWIFT_BACKTRACE=none
ENV ASSISTANT_NAME=Andy
ENTRYPOINT ["/app/nanoclaw-agent"]
EOF

    "$CONTAINER_CLI" build -f "$DOCKERFILE" -t "${TAG}" .
    rm -f "$DOCKERFILE"
}

case "$MODE" in
    slim)
        build_slim
        ;;
    static)
        build_static
        ;;
    *)
        echo "ERROR: Unsupported mode '$MODE'. Use: slim | static"
        exit 2
        ;;
esac

echo
echo "Build complete: ${TAG}"
