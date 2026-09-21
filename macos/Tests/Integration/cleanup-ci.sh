#!/bin/bash

set -euo pipefail

# CI runners are disposable. Never use cleanup.sh's recoverable Trash behavior
# here: permanently remove only the exact allowlisted Xe paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XE_INSTALLER_CLEANUP_PERMANENT=1 \
    exec bash "${SCRIPT_DIR}/cleanup.sh"
