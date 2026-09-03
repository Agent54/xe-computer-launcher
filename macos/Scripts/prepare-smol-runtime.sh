#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
macos_dir="$(dirname "$script_dir")"
source "$macos_dir/SmolVM.lock"

destination="${1:?usage: prepare-smol-runtime.sh DESTINATION}"
expected_destination="$macos_dir/.build/smol-runtime/SmolRuntime"
if [[ "$destination" == ".build/smol-runtime/SmolRuntime" ]]; then
    destination="$expected_destination"
fi
if [[ "$destination" != "$expected_destination" ]]; then
    echo "refusing to stage SmolVM into unexpected destination: $destination" >&2
    exit 1
fi

runtime_asset="smolvm-${SMOLVM_VERSION}-darwin-arm64.tar.gz"
compose_asset="smolvm-${SMOLVM_VERSION}-docker-compose-darwin-arm64.smolmachine"
cache_dir="${SMOLVM_CACHE_DIR:-$macos_dir/.build/smolvm-assets}"
asset_dir="${SMOLVM_ASSET_DIR:-}"

mkdir -p "$cache_dir"

resolve_asset() {
    local filename="$1"
    local source_path
    local cached_path="$cache_dir/$filename"

    if [[ -n "$asset_dir" ]]; then
        source_path="$asset_dir/$filename"
        [[ -f "$source_path" ]] || {
            echo "SmolVM asset not found: $source_path" >&2
            exit 1
        }
        printf '%s\n' "$source_path"
        return
    fi

    if [[ ! -f "$cached_path" ]]; then
        local temporary_path="$cached_path.download"
        rm -f "$temporary_path"
        if ! command -v gh >/dev/null 2>&1; then
            echo "GitHub CLI is required to download private SmolVM release assets." >&2
            echo "Install gh and authenticate it, or set SMOLVM_ASSET_DIR." >&2
            exit 1
        fi
        if ! gh release download "$SMOLVM_RELEASE_TAG" \
            --repo "$SMOLVM_GITHUB_REPOSITORY" \
            --pattern "$filename" \
            --output "$temporary_path"; then
            rm -f "$temporary_path"
            echo "Could not download private SmolVM release asset: $filename" >&2
            echo "Run 'gh auth login' or provide GH_TOKEN, or set SMOLVM_ASSET_DIR." >&2
            exit 1
        fi
        mv "$temporary_path" "$cached_path"
    fi
    printf '%s\n' "$cached_path"
}

verify_asset() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "checksum mismatch for $(basename "$path")" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    fi
}

verify_compose_agent_boot() {
    local path="$1"
    local entries
    local listing
    local mode
    local required

    # A .smolmachine may have data after its tar payload, which can make the
    # outer tar return non-zero even though agent-rootfs.tar was read correctly.
    # This is a Darwin-only bundle, so use the system bsdtar rather than a
    # Homebrew/GNU tar that may appear earlier in a CI runner's PATH.
    entries="$(
        set +o pipefail
        /usr/bin/tar -xOf "$path" agent-rootfs.tar 2>/dev/null |
            /usr/bin/tar -tf - 2>/dev/null |
            sed 's#^\./##'
    )"
    for required in sbin/init usr/local/bin/smolvm-agent; do
        if ! grep -Fxq "$required" <<<"$entries"; then
            echo "Compose image is missing top-level $required" >&2
            exit 1
        fi
    done

    listing="$(
        set +o pipefail
        /usr/bin/tar -xOf "$path" agent-rootfs.tar 2>/dev/null |
            /usr/bin/tar -tvf - 2>/dev/null |
            awk '{
                name = $NF
                sub(/^\.\//, "", name)
                if (name == "usr/local/bin/smolvm-agent") {
                    print $1, name
                }
        }'
    )"

    mode="$(printf '%s\n' "$listing" | awk '$2 == "usr/local/bin/smolvm-agent" { print $1; exit }')"
    if [[ -z "$mode" || "$mode" != *x* ]]; then
        echo "Compose image has a missing or non-executable usr/local/bin/smolvm-agent" >&2
        exit 1
    fi
}

runtime_path="$(resolve_asset "$runtime_asset")"
compose_path="$(resolve_asset "$compose_asset")"
verify_asset "$runtime_path" "$SMOLVM_RUNTIME_SHA256"
verify_asset "$compose_path" "$SMOLVM_COMPOSE_SHA256"
verify_compose_agent_boot "$compose_path"

empty_dir="$macos_dir/.build/empty"
mkdir -p "$destination" "$empty_dir"
rsync -a --delete "$empty_dir/" "$destination/"
/usr/bin/tar -xzf "$runtime_path" --strip-components 1 -C "$destination"
runtime_source="$destination"

for required in \
    smolvm-bin \
    agent-rootfs \
    storage-template.ext4.zst \
    overlay-template.ext4.zst \
    lib/libkrun.dylib \
    lib/libkrun.2.dylib \
    lib/libkrunfw.5.dylib; do
    [[ -e "$runtime_source/$required" ]] || {
        echo "SmolVM distribution is missing $required" >&2
        exit 1
    }
done

cp "$compose_path" "$runtime_source/docker-compose.smolmachine"
cp "$macos_dir/SmolVM.lock" "$runtime_source/SmolVM.lock"

echo "Staged SmolVM $SMOLVM_VERSION with Docker Compose at $destination"
