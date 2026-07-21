#!/bin/bash

set -euo pipefail

APP_NAME="Xe Computer"
BUNDLE_ID="dev.xe.computer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"

log() {
    printf '[installer-cleanup] %s\n' "$*"
}

fail() {
    printf '[installer-cleanup] ERROR: %s\n' "$*" >&2
    exit 1
}

detach_disk_image() {
    local target="$1"
    if [[ -d "$target" || -b "$target" ]]; then
        hdiutil detach "$target" >/dev/null 2>&1 \
            || hdiutil detach "$target" -force >/dev/null
    fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "cleanup must run on macOS"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"

log "stopping existing app processes"
pkill -f '/Xe Computer.app/Contents/MacOS/bin' 2>/dev/null || true

log "detaching stale installer disk images"
while IFS= read -r stale_mount; do
    detach_disk_image "$stale_mount"
done < <(find /Volumes -maxdepth 1 -type d -name 'Xe Computer*' -print 2>/dev/null)

# An interrupted first-open confirmation can leave an image attached to a
# /dev/disk node without a mounted volume. Detach both the normal build name
# and the historical local-override name.
while IFS= read -r stale_device; do
    detach_disk_image "$stale_device"
done < <(
    hdiutil info | awk '
        /^image-path[[:space:]]*:/ {
            image_path = $0
            sub(/^[^:]*:[[:space:]]*/, "", image_path)
            matches_xe_dmg = (
                image_path ~ /\/Xe Computer\.dmg$/ ||
                image_path ~ /\/Xe\.Computer\.dmg$/
            )
            next
        }
        matches_xe_dmg && /^\/dev\/disk[0-9]+[[:space:]]/ {
            print $1
            matches_xe_dmg = 0
        }
    '
)

log "resetting app privacy permissions"
if ! tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then
    log "bundle is not registered yet; there are no registered app permissions to reset"
fi

log "removing existing installed app"
if [[ -e "$INSTALLED_APP" ]]; then
    trashed_app="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-app-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    rmdir "$trashed_app"
    log "moving existing installed app to $trashed_app"
    mv "$INSTALLED_APP" "$trashed_app"
fi

log "removing existing app data"
if [[ -e "$APP_DATA" ]]; then
    trashed_data="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    rmdir "$trashed_data"
    log "moving existing app data to $trashed_data"
    mv "$APP_DATA" "$trashed_data"
fi

log "uninstalling Colima so first-run dependency installation is exercised"
if brew list --formula colima >/dev/null 2>&1; then
    brew uninstall --force colima
fi

log "cleanup complete"
