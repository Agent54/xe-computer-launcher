#!/usr/bin/env bash
set -euo pipefail

helper="${1:?usage: verify-compose-server.sh HELPER [--release]}"
mode="${2:-}"
[[ -x "$helper" ]] || { echo "Missing Compose server executable: $helper" >&2; exit 1; }
file "$helper" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict --verbose=2 "$helper"
signature="$(codesign -dvv "$helper" 2>&1)"
[[ "$signature" == *"runtime)"* ]] || { echo "Compose server is missing hardened runtime signing" >&2; exit 1; }
if [[ "$mode" == "--release" && "$signature" == *"Signature=adhoc"* ]]; then
    echo "Release Compose server is ad-hoc signed" >&2
    exit 1
fi
"$helper" serve --help | grep -q 'Serve a Compose HTTP API'
echo "Embedded Compose server verified"
