#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$MACOS_DIR"
# Built by SwiftPM with the runtime suite; never recompile production sources.
exec /usr/bin/xcrun swift run --skip-build --configuration "${BUILD_CONFIG:-debug}" settings-termination-test
