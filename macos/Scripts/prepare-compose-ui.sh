#!/usr/bin/env bash
set -euo pipefail
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$macos_dir/ComposeUI.lock"
destination="${1:?usage: prepare-compose-ui.sh DESTINATION}"
cache="${COMPOSE_UI_ASSET_DIR:-$macos_dir/.build/compose-ui-assets/$COMPOSE_UI_RELEASE_TAG}"
archive="$cache/$COMPOSE_UI_ASSET"
mkdir -p "$cache"
if [[ ! -f "$archive" && -z "${COMPOSE_UI_ASSET_DIR:-}" ]]; then
    temporary="$(mktemp "$cache/.download.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    gh release download "$COMPOSE_UI_RELEASE_TAG" --repo "$COMPOSE_UI_GITHUB_REPOSITORY" \
        --pattern "$COMPOSE_UI_ASSET" --output "$temporary" --clobber
    mv "$temporary" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$COMPOSE_UI_SHA256" ]] || {
    echo "Compose UI checksum mismatch: $archive" >&2; exit 1;
}
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# This archive is trusted only after matching the independently pinned checksum.
tar -xzf "$archive" -C "$stage"
test -s "$stage/index.html"
test -d "$stage/_app/immutable"
mkdir -p "$destination"
rsync -a --delete "$stage/" "$destination/"
echo "Staged Compose UI $COMPOSE_UI_RELEASE_TAG"
