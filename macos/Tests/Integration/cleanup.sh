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

trash_generated_shim_if_owned() {
    local shim_path="$1"
    local plist_path="${shim_path}/Contents/Info.plist"
    local shim_user_data_dir
    local trashed_shim

    [[ -d "$shim_path" && -f "$plist_path" ]] || return 0
    shim_user_data_dir="$(
        /usr/libexec/PlistBuddy -c 'Print :CrAppModeUserDataDir' "$plist_path" 2>/dev/null \
            || true
    )"
    [[ "$shim_user_data_dir" == "${APP_DATA}/profiles/"* ]] || return 0

    trashed_shim="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-shim-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    rmdir "$trashed_shim"
    log "moving stale generated app shim to $trashed_shim"
    mv "$shim_path" "$trashed_shim"
}

stop_matching_processes() {
    local description="$1"
    local pattern="$2"
    local process_ids

    process_ids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    [[ -n "$process_ids" ]] || return 0

    log "stopping $description"
    while IFS= read -r process_id; do
        kill -TERM "$process_id" 2>/dev/null || true
    done <<<"$process_ids"

    # Chromium helpers and app shims normally exit with their parent. Give them
    # a short grace period, then ensure stale instances cannot keep app-data
    # files open while cleanup moves the directory.
    for _ in {1..20}; do
        pgrep -f "$pattern" >/dev/null 2>&1 || return 0
        sleep 0.1
    done

    process_ids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] && kill -KILL "$process_id" 2>/dev/null || true
    done <<<"$process_ids"

    sleep 0.1
    pgrep -f "$pattern" >/dev/null 2>&1 \
        && fail "could not stop $description"
    return 0
}

[[ "$(uname -s)" == "Darwin" ]] || fail "cleanup must run on macOS"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"

log "stopping existing app processes"
bundle_id_pattern="${BUNDLE_ID//./[.]}"
stop_matching_processes \
    "Xe Computer instances" \
    '/Xe Computer[.]app/Contents/MacOS/bin'
stop_matching_processes \
    "Darc app shims" \
    "/Library/Application Support/${bundle_id_pattern}/shims/.*/Darc[^/]*[.]app/Contents/MacOS/app_mode_loader"
stop_matching_processes \
    "Darc app shims launched by Xe Computer's Helium" \
    "app_mode_loader .*--launched-by-chrome-bundle-path=.*/Library/Application Support/${bundle_id_pattern}/Helium[.]app"
stop_matching_processes \
    "Xe Computer's Helium and helper processes" \
    "/Library/Application Support/${bundle_id_pattern}/Helium[.]app/"

log "removing stale generated app shims"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chromium Apps.localized/Darc.app"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chrome Canary Apps.localized/Darc.app"

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
            matches_xe_dmg = image_path ~ /\/Xe Computer\.dmg$/ || image_path ~ /\/Xe\.Computer\.dmg$/
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
