#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH="${1:-arm64}"
VERSION="${VERSION:-dev}"

case "$ARCH" in
  arm64|aarch64)
    GOARCH=arm64
    MAKE_TARGET=build-agent-linux-arm64
    BINARY="$GO_DIR/bin/wendy-agent-linux-arm64"
    ;;
  amd64|x86_64)
    GOARCH=amd64
    MAKE_TARGET=build-agent-linux-amd64
    BINARY="$GO_DIR/bin/wendy-agent-linux-amd64"
    ;;
  *)
    echo "Usage: $0 [arm64|amd64]"
    echo "  Default: arm64"
    exit 1
    ;;
esac

echo "Cross-compiling wendy-agent for linux/$GOARCH..."
make -C "$GO_DIR" VERSION="$VERSION" "$MAKE_TARGET"

echo "Deploying to device via 'wendy device update'..."
wendy device update --binary "$BINARY"
