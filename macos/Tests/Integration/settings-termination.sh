#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_BINARY="$MACOS_DIR/.build/settings-termination-test"

mkdir -p "$MACOS_DIR/.build"
/usr/bin/xcrun swiftc -swift-version 6 -parse-as-library -framework AppKit \
    "$MACOS_DIR/Sources/macos/ApplicationTermination.swift" \
    "$SCRIPT_DIR/settings-termination.swift" \
    -o "$TEST_BINARY"
"$TEST_BINARY"
