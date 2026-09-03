#!/usr/bin/env bash

set -euo pipefail

runtime="${1:?usage: verify-smol-runtime.sh RUNTIME [--release]}"
mode="${2:-}"
guest_runtime="$(cd "$runtime/../../Resources/SmolRuntime" && pwd)"

for required in \
    smolvm-bin \
    lib/libkrun.dylib \
    lib/libkrun.2.dylib \
    lib/libkrunfw.5.dylib; do
    [[ -e "$runtime/$required" ]] || {
        echo "embedded SmolVM host runtime is missing $required" >&2
        exit 1
    }
done

for required in \
    agent-rootfs.tar \
    storage-template.ext4.zst \
    overlay-template.ext4.zst \
    docker-compose.smolmachine \
    SmolVM.lock; do
    [[ -e "$guest_runtime/$required" ]] || {
        echo "embedded SmolVM guest runtime is missing $required" >&2
        exit 1
    }
done

rootfs_entries="$(tar -tf "$guest_runtime/agent-rootfs.tar" | sed 's#^\./##')"
for required in sbin/init usr/local/bin/smolvm-agent bin/busybox; do
    if ! grep -Fxq "$required" <<<"$rootfs_entries"; then
        echo "agent rootfs archive is missing top-level $required" >&2
        exit 1
    fi
done
if grep -Eq '^agent-rootfs/' <<<"$rootfs_entries"; then
    echo "agent rootfs archive must contain rootfs contents, not an agent-rootfs directory" >&2
    exit 1
fi
for required in usr/local/bin/smolvm-agent bin/busybox; do
    mode_bits="$(
        tar -tvf "$guest_runtime/agent-rootfs.tar" |
            awk -v expected="$required" '{ name = $NF; sub(/^\.\//, "", name); if (name == expected) { print $1; exit } }'
    )"
    if [[ -z "$mode_bits" || "$mode_bits" != *x* ]]; then
        echo "agent rootfs archive has a missing or non-executable file: $required" >&2
        exit 1
    fi
done

[[ -L "$runtime/lib/libkrun.2.dylib" ]] || {
    echo "libkrun.2.dylib must remain a symlink" >&2
    exit 1
}
[[ -L "$runtime/lib/libkrunfw.dylib" ]] || {
    echo "libkrunfw.dylib must remain a symlink" >&2
    exit 1
}

file "$runtime/smolvm-bin" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict --verbose=2 "$runtime/smolvm-bin"
helper_signature="$(codesign -dvv "$runtime/smolvm-bin" 2>&1)"
[[ "$helper_signature" == *"runtime)"* ]] || {
    echo "smolvm-bin is missing hardened runtime signing" >&2
    exit 1
}

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/xe-smol-entitlements.XXXXXX")"
trap 'rm -f "$entitlements_file"' EXIT
codesign -d --entitlements - --xml "$runtime/smolvm-bin" >"$entitlements_file" 2>/dev/null

for entitlement in \
    com.apple.security.hypervisor \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-jit; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_file")" == "true" ]] || {
        echo "smolvm-bin is missing entitlement: $entitlement" >&2
        exit 1
    }
done

while IFS= read -r -d '' library; do
    codesign --verify --strict --verbose=2 "$library"
    library_signature="$(codesign -dvv "$library" 2>&1)"
    [[ "$library_signature" == *"runtime)"* ]] || {
        echo "$library is missing hardened runtime signing" >&2
        exit 1
    }
    if [[ "$mode" == "--release" && "$library_signature" == *"Signature=adhoc"* ]]; then
        echo "release SmolVM library is ad-hoc signed: $library" >&2
        exit 1
    fi
done < <(find "$runtime/lib" -type f -name '*.dylib' -print0)

if [[ "$mode" == "--release" ]]; then
    if [[ "$helper_signature" == *"Signature=adhoc"* ]]; then
        echo "release SmolVM helper is ad-hoc signed" >&2
        exit 1
    fi
fi

echo "Embedded SmolVM runtime verified"
