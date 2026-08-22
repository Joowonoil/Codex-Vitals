#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SPARKLE_FRAMEWORK_DIR="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swift build -c debug
BIN_DIR="$(swift build -c debug --show-bin-path)"
DYLD_FRAMEWORK_PATH="$SPARKLE_FRAMEWORK_DIR" \
    "$BIN_DIR/CodexVitals" --render-sanitized-screenshot
test -f docs/screenshot.png
sips -g pixelWidth -g pixelHeight docs/screenshot.png
