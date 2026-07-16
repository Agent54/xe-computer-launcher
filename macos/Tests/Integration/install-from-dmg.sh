#!/bin/bash

set -euo pipefail

APP_NAME="Xe Computer"
BUNDLE_ID="dev.xe.xecomputer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
DEFAULT_DMG="$(cd "$(dirname "$0")/../.." && pwd)/.build/Xe Computer.dmg"
DMG_PATH="${DMG_PATH:-$DEFAULT_DMG}"
MOUNT_POINT=""

log() {
    printf '[installer-integration] %s\n' "$*"
}

fail() {
    printf '[installer-integration] ERROR: %s\n' "$*" >&2
    exit 1
}

detach_if_mounted() {
    local mount_point="$1"
    if [[ -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 \
            || hdiutil detach "$mount_point" -force >/dev/null
    fi
}

cleanup_mount() {
    if [[ -n "$MOUNT_POINT" ]]; then
        detach_if_mounted "$MOUNT_POINT" || true
    fi
}

trap cleanup_mount EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "this test must run on macOS"
[[ -f "$DMG_PATH" ]] || fail "DMG not found at: $DMG_PATH"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"

log "stopping existing app processes"
pkill -f '/Xe Computer.app/Contents/MacOS/bin' 2>/dev/null || true

log "resetting app privacy permissions"
if ! tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then
    log "bundle is not registered yet; there are no registered app permissions to reset"
fi

log "removing existing installed app"
if [[ -e "$INSTALLED_APP" ]]; then
    sudo rm -rf "$INSTALLED_APP"
fi

if [[ -e "$APP_DATA" ]]; then
    trash_dir="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    rmdir "$trash_dir"
    log "moving existing app data to $trash_dir"
    mv "$APP_DATA" "$trash_dir"
fi

log "detaching stale installer disk images"
while IFS= read -r stale_mount; do
    detach_if_mounted "$stale_mount"
done < <(find /Volumes -maxdepth 1 -type d -name 'Xe Computer*' -print 2>/dev/null)

log "uninstalling Colima so first-run dependency installation is exercised"
if brew list --formula colima >/dev/null 2>&1; then
    brew uninstall --force colima
fi

log "opening the DMG through Launch Services"
open "$DMG_PATH"

SOURCE_APP=""
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )) && [[ -z "$SOURCE_APP" ]]; do
    while IFS= read -r -d '' candidate; do
        candidate_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$candidate_bundle_id" == "$BUNDLE_ID" ]]; then
            SOURCE_APP="$candidate"
            break
        fi
    done < <(find /Volumes -maxdepth 3 -type d -name '*.app' -print0 2>/dev/null)
    [[ -n "$SOURCE_APP" ]] || sleep 1
done
[[ -n "$SOURCE_APP" ]] || fail "DMG does not contain an app with bundle identifier $BUNDLE_ID"
MOUNT_POINT="$(stat -f '%m' "$SOURCE_APP")"
log "found source app at $SOURCE_APP"

log "opening the app from the disk image through Launch Services"
open "$SOURCE_APP"

log "approving the real installer alert"
osascript <<'APPLESCRIPT'
tell application "System Events"
    set deadline to (current date) + 60
    repeat
        if (current date) > deadline then error "Timed out waiting for the installer alert"
        set matches to every application process whose bundle identifier is "dev.xe.xecomputer"
        repeat with appProcess in matches
            tell appProcess
                if exists button "Install in Applications" of window 1 then
                    click button "Install in Applications" of window 1
                    return
                end if
            end tell
        end repeat
        delay 0.25
    end repeat
end tell
APPLESCRIPT

log "waiting for installation and relaunch"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$INSTALLED_APP" ]] && pgrep -f '/Applications/Xe Computer.app/Contents/MacOS/bin' >/dev/null; then
        break
    fi
    sleep 1
done

[[ -d "$INSTALLED_APP" ]] || fail "installed app was not created at $INSTALLED_APP"
pgrep -f '/Applications/Xe Computer.app/Contents/MacOS/bin' >/dev/null \
    || fail "installed app did not relaunch from /Applications"

log "verifying installed signature and Gatekeeper assessment"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
spctl --assess --type execute --verbose=2 "$INSTALLED_APP"

installed_bundle_id="$(defaults read "$INSTALLED_APP/Contents/Info" CFBundleIdentifier)"
[[ "$installed_bundle_id" == "$BUNDLE_ID" ]] \
    || fail "unexpected installed bundle identifier: $installed_bundle_id"

if xattr -p com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1; then
    fail "installed app still has a quarantine attribute"
fi

if pgrep -f "${MOUNT_POINT}/.*\.app/Contents/MacOS/bin" >/dev/null; then
    fail "a copy of the app is still running from the disk image"
fi

log "waiting for the app to reinstall Colima"
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
    if brew list --formula colima >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
brew list --formula colima >/dev/null 2>&1 \
    || fail "Colima was not installed during first-run setup"

log "PASS: DMG installation, relaunch, signature, Gatekeeper, quarantine, and Colima checks succeeded"
