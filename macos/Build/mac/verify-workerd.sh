#!/usr/bin/env bash
set -euo pipefail
helper="${1:?usage: verify-workerd.sh HELPER [--release]}"
[[ -x "$helper" ]]
file "$helper" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict --verbose=2 "$helper"
signature="$(codesign -dvv "$helper" 2>&1)"
[[ "$signature" == *"runtime)"* ]] || { echo 'workerd requires hardened runtime signing' >&2; exit 1; }
if [[ "${2:-}" == '--release' && "$signature" == *'Signature=adhoc'* ]]; then
    echo 'Release workerd is ad-hoc signed' >&2; exit 1
fi
codesign -d --entitlements :- "$helper" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit'
"$helper" --version
