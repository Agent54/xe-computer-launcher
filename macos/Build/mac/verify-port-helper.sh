#!/usr/bin/env bash
set -euo pipefail
helper="${1:?usage: verify-port-helper.sh HELPER PLIST [--release]}"
plist="${2:?usage: verify-port-helper.sh HELPER PLIST [--release]}"
[[ -x "$helper" ]]
file "$helper" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict --verbose=2 "$helper"
signature="$(codesign -dvv "$helper" 2>&1)"
[[ "$signature" == *"runtime)"* ]] || { echo 'Port helper requires hardened runtime signing' >&2; exit 1; }
if [[ "${3:-}" == '--release' && "$signature" == *'Signature=adhoc'* ]]; then
    echo 'Release port helper is ad-hoc signed' >&2
    exit 1
fi
plutil -lint "$plist"
[[ "$(plutil -extract BundleProgram raw "$plist")" == 'Contents/MacOS/port-helper' ]]
[[ "$(plutil -extract Sockets.ingest.SockNodeName raw "$plist")" == '127.0.0.1' ]]
[[ "$(plutil -extract Sockets.ingest.SockServiceName raw "$plist")" == '80' ]]
[[ "$(plutil -extract Sockets.tls.SockNodeName raw "$plist")" == '127.0.0.1' ]]
[[ "$(plutil -extract Sockets.tls.SockServiceName raw "$plist")" == '443' ]]
