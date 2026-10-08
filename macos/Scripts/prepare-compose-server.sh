#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
macos_dir="$(dirname "$script_dir")"
source "$macos_dir/ComposeServer.lock"

destination="${1:?usage: prepare-compose-server.sh DESTINATION}"
source_dir="${COMPOSE_SERVER_SOURCE_DIR:-}"

if [[ -n "$source_dir" ]]; then
    [[ -f "$source_dir/go.mod" ]] || { echo "Compose server source is missing go.mod: $source_dir" >&2; exit 1; }
    command -v go >/dev/null 2>&1 || { echo "Install Go to build COMPOSE_SERVER_SOURCE_DIR." >&2; exit 1; }
    source_dir="$(cd "$source_dir" && pwd)"
    mkdir -p "$(dirname "$destination")"
    destination="$(cd "$(dirname "$destination")" && pwd)/$(basename "$destination")"
    source_version="$(git -C "$source_dir" describe --tags --always --dirty 2>/dev/null || echo local)"
    (
        cd "$source_dir"
        go build -trimpath -tags fsnotify \
            -ldflags "-w -X github.com/docker/compose/v5/internal.Version=$source_version" \
            -o "$destination" ./cmd
    )
    file "$destination" | grep -q 'Mach-O 64-bit executable arm64'
    echo "Built local Compose server $source_version from $source_dir at $destination"
    exit 0
fi

cache_dir="${COMPOSE_SERVER_CACHE_DIR:-$macos_dir/.build/compose-server-assets/$COMPOSE_SERVER_RELEASE_TAG}"
asset_dir="${COMPOSE_SERVER_ASSET_DIR:-}"

if [[ -n "$asset_dir" ]]; then
    asset_path="$asset_dir/$COMPOSE_SERVER_ASSET"
else
    mkdir -p "$cache_dir"
    asset_path="$cache_dir/$COMPOSE_SERVER_ASSET"
    if [[ ! -f "$asset_path" ]]; then
        command -v gh >/dev/null 2>&1 || {
            echo "Install and authenticate gh, or set COMPOSE_SERVER_ASSET_DIR." >&2
            exit 1
        }
        temporary_path="$(mktemp "$cache_dir/.download.XXXXXX")"
        trap 'rm -f "$temporary_path"' EXIT
        if ! gh release download "$COMPOSE_SERVER_RELEASE_TAG" \
            --repo "$COMPOSE_SERVER_GITHUB_REPOSITORY" \
            --pattern "$COMPOSE_SERVER_ASSET" --output "$temporary_path" --clobber; then
            echo "Could not download Compose server release $COMPOSE_SERVER_RELEASE_TAG from $COMPOSE_SERVER_GITHUB_REPOSITORY." >&2
            echo "Checking releases visible to the build's GitHub credentials (no token values are printed):" >&2
            if ! gh release list --repo "$COMPOSE_SERVER_GITHUB_REPOSITORY" --limit 10 \
                --json tagName,isDraft --jq '.[] | {tagName, isDraft}' >&2; then
                echo "Could not list releases. Check that the token selects this repository and has Contents read permission." >&2
            fi
            echo "Draft releases are visible only to users with push access. Selecting a public repository alone does not grant access to its draft assets." >&2
            echo "Verify that CI's SMOLVM_GITHUB_TOKEN contains the intended token, or set COMPOSE_SERVER_ASSET_DIR for an offline build." >&2
            exit 1
        fi
        mv "$temporary_path" "$asset_path"
    fi
fi

[[ -s "$asset_path" ]] || { echo "Compose server asset is missing or empty: $asset_path" >&2; exit 1; }
actual="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
[[ "$actual" == "$COMPOSE_SERVER_SHA256" ]] || {
    echo "Compose server checksum mismatch: expected $COMPOSE_SERVER_SHA256, got $actual" >&2
    exit 1
}
file "$asset_path" | grep -q 'Mach-O 64-bit executable arm64'

mkdir -p "$(dirname "$destination")"
cp "$asset_path" "$destination"
chmod 755 "$destination"
echo "Staged Compose server $COMPOSE_SERVER_RELEASE_TAG (SHA-256 $actual) at $destination"
