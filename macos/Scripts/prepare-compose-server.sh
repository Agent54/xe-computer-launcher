#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
macos_dir="$(dirname "$script_dir")"
source "$macos_dir/ComposeServer.lock"

destination="${1:?usage: prepare-compose-server.sh DESTINATION}"
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
            echo "Could not download Compose server. Provide GH_TOKEN with read access to $COMPOSE_SERVER_GITHUB_REPOSITORY, authenticate gh, or set COMPOSE_SERVER_ASSET_DIR." >&2
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
