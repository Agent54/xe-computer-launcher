#!/bin/bash

set -euo pipefail

APP_NAME="Xe Computer"
BUNDLE_ID="dev.xe.xecomputer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
DEFAULT_DMG="$(cd "$(dirname "$0")/../.." && pwd)/.build/Xenon Computer.dmg"
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
    if mount | grep -Fq " on ${mount_point} "; then
        hdiutil detach "$mount_point" -force >/dev/null
    fi
}

cleanup_mount() {
    if [[ -n "$MOUNT_POINT" ]]; then
        detach_if_mounted "$MOUNT_POINT" || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}

trap cleanup_mount EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "this test must run on macOS"
[[ -f "$DMG_PATH" ]] || fail "DMG not found at: $DMG_PATH"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"

log "stopping existing app processes"
pkill -f '/Xe Computer.app/Contents/MacOS/bin' 2>/dev/null || true
pkill -f '/Xenon Computer.app/Contents/MacOS/bin' 2>/dev/null || true

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
done < <(find /Volumes -maxdepth 1 -type d \( -name 'Xenon Computer*' -o -name 'Xe Computer*' \) -print 2>/dev/null)

log "uninstalling Colima so first-run dependency installation is exercised"
if brew list --formula colima >/dev/null 2>&1; then
    brew uninstall --force colima
fi

MOUNT_POINT="$(mktemp -d /tmp/xe-computer-installer.XXXXXX)"
log "mounting $DMG_PATH"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -readonly >/dev/null

SOURCE_APP=""
while IFS= read -r -d '' candidate; do
    candidate_bundle_id="$(defaults read "$candidate/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    if [[ "$candidate_bundle_id" == "$BUNDLE_ID" ]]; then
        SOURCE_APP="$candidate"
        break
    fi
done < <(find "$MOUNT_POINT" -maxdepth 2 -type d -name '*.app' -print0)
[[ -n "$SOURCE_APP" ]] || fail "DMG does not contain an app with bundle identifier $BUNDLE_ID"
log "found source app at $SOURCE_APP"

log "registering the source bundle and resetting app privacy permissions"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREGISTER" ]] || fail "Launch Services registration tool was not found"
"$LSREGISTER" -f "$SOURCE_APP"
tccutil reset All "$BUNDLE_ID" >/dev/null

log "checking the distributed app before launch"
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
spctl --assess --type execute --verbose=2 "$SOURCE_APP"

log "launching the app from the disk image"
open -n "$SOURCE_APP"

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

if pgrep -f '/Volumes/.*/Xenon Computer.app/Contents/MacOS/bin' >/dev/null; then
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
