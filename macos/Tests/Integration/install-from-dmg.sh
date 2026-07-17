#!/bin/bash

set -euo pipefail

APP_NAME="Xe Computer"
BUNDLE_ID="dev.xe.xecomputer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_DMG="$(cd "$SCRIPT_DIR/../.." && pwd)/.build/Xe Computer.dmg"
LOCAL_DMG="$SCRIPT_DIR/Xe.Computer.dmg"
if [[ -f "$LOCAL_DMG" ]]; then
    DEFAULT_DMG="$LOCAL_DMG"
else
    DEFAULT_DMG="$REPOSITORY_DMG"
fi
DMG_PATH="${DMG_PATH:-$DEFAULT_DMG}"
MOUNT_POINT=""

log() {
    printf '[installer-integration] %s\n' "$*"
}

fail() {
    printf '[installer-integration] ERROR: %s\n' "$*" >&2
    exit 1
}

# Apple Events can wait forever when the process running this test has not yet
# been granted Automation or Accessibility access. Keep every UI operation
# bounded so the test reports the real setup problem instead of deadlocking.
osascript_with_timeout() {
    local timeout_seconds="$1"
    shift

    perl -e '
        use strict;
        use warnings;
        my $timeout = shift @ARGV;
        $SIG{ALRM} = sub { die "__INSTALLER_UI_TIMEOUT__\n" };
        alarm $timeout;
        exec @ARGV or die "exec @ARGV failed: $!\n";
    ' "$timeout_seconds" "$@"
}

# Find a button anywhere in a process window. NSAlert buttons are commonly in
# sheets or nested groups, so addressing "button ... of window 1" is not
# reliable. AXPress is preferred; a click at the AX frame center is the
# fallback for protected dialogs that expose a button but ignore AXPress.
press_ui_button() {
    local process_bundle_id="$1"
    local button_name="$2"
    local context_text="$3"
    local timeout_seconds="$4"

    osascript_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$process_bundle_id" "$button_name" "$context_text" "$timeout_seconds" <<'APPLESCRIPT'
on run argv
    set wantedBundleID to item 1 of argv
    set wantedButtonName to item 2 of argv
    set wantedContext to item 3 of argv
    set timeoutSeconds to item 4 of argv as integer

    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            -- LSUIElement/menu-bar apps report visible=false even while an
            -- NSAlert is onscreen. Inspect all GUI processes and use the
            -- bundle/context filters below to select the intended dialog.
            set candidateProcesses to application processes
            repeat with uiProcess in candidateProcesses
                set bundleMatches to false
                try
                    set bundleMatches to (wantedBundleID is "" or bundle identifier of uiProcess is wantedBundleID)
                end try

                if bundleMatches then
                    repeat with uiWindow in windows of uiProcess
                        set uiElements to {}
                        try
                            set uiElements to entire contents of uiWindow
                        end try

                        set contextMatches to (wantedContext is "")
                        set targetButton to missing value
                        repeat with uiElement in uiElements
                            try
                                set elementName to name of uiElement as text
                                if elementName is wantedButtonName and role of uiElement is "AXButton" then
                                    set targetButton to uiElement
                                end if
                                if wantedContext is not "" and elementName contains wantedContext then
                                    set contextMatches to true
                                end if
                            end try
                            try
                                if wantedContext is not "" then
                                    set elementValue to value of uiElement as text
                                    if elementValue contains wantedContext then set contextMatches to true
                                end if
                            end try
                        end repeat

                        if targetButton is not missing value and contextMatches then
                            set buttonPosition to position of targetButton
                            set buttonSize to size of targetButton

                            try
                                perform action "AXPress" of targetButton
                            end try
                            delay 0.5

                            set buttonStillExists to false
                            try
                                set buttonStillExists to exists targetButton
                            end try
                            if buttonStillExists then
                                click at {item 1 of buttonPosition + (item 1 of buttonSize div 2), item 2 of buttonPosition + (item 2 of buttonSize div 2)}
                                delay 0.5
                            end if
                            return name of uiProcess as text
                        end if
                    end repeat
                end if
            end repeat

            delay 0.25
        end repeat
        error "Timed out waiting for button “" & wantedButtonName & "”"
    end tell
end run
APPLESCRIPT
}

grant_accessibility_permission() {
    local app_name="$1"
    local timeout_seconds="$2"

    osascript_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$app_name" "$timeout_seconds" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set timeoutSeconds to item 2 of argv as integer
    set wantedIdentifier to appName & "_Toggle"

    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            if exists application process "System Settings" then
                tell application process "System Settings"
                    repeat with uiWindow in windows
                        set uiElements to {}
                        try
                            set uiElements to entire contents of uiWindow
                        end try

                        repeat with uiElement in uiElements
                            set elementIdentifier to ""
                            try
                                set elementIdentifier to value of attribute "AXIdentifier" of uiElement as text
                            end try

                            if elementIdentifier is wantedIdentifier then
                                set toggleValue to 0
                                try
                                    set toggleValue to value of uiElement as integer
                                end try
                                if toggleValue is 1 then return "already enabled"

                                set togglePosition to position of uiElement
                                set toggleSize to size of uiElement
                                try
                                    perform action "AXPress" of uiElement
                                end try
                                delay 0.5

                                try
                                    set toggleValue to value of uiElement as integer
                                end try
                                if toggleValue is not 1 then
                                    click at {item 1 of togglePosition + (item 1 of toggleSize div 2), item 2 of togglePosition + (item 2 of toggleSize div 2)}
                                end if

                                -- macOS may require the user to authenticate
                                -- before changing this security-sensitive
                                -- setting. Keep the test alive while that
                                -- system-owned sheet is completed manually.
                                repeat (timeoutSeconds * 4) times
                                    delay 0.25
                                    try
                                        if value of uiElement as integer is 1 then return "enabled"
                                    end try
                                end repeat
                                error "The Accessibility switch for " & appName & " did not turn on"
                            end if
                        end repeat
                    end repeat
                end tell
            end if

            delay 0.25
        end repeat
        error "Timed out waiting for the Accessibility switch for " & appName
    end tell
end run
APPLESCRIPT
}

detach_disk_image() {
    local target="$1"
    if [[ -d "$target" || -b "$target" ]]; then
        hdiutil detach "$target" >/dev/null 2>&1 \
            || hdiutil detach "$target" -force >/dev/null
    fi
}

cleanup_mount() {
    if [[ -n "$MOUNT_POINT" ]]; then
        detach_disk_image "$MOUNT_POINT" || true
    fi
}

trap cleanup_mount EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "this test must run on macOS"
[[ -f "$DMG_PATH" ]] || fail "DMG not found at: $DMG_PATH"
command -v brew >/dev/null 2>&1 || fail "Homebrew is required"

assistive_access="$(osascript_with_timeout 8 osascript \
    -e 'tell application "System Events" to get UI elements enabled' 2>/dev/null || true)"
if [[ "$assistive_access" != "true" ]]; then
    fail "UI automation lacks Accessibility access (or macOS blocked its Automation request). In System Settings > Privacy & Security > Accessibility, enable the GUI-session runner that launches this test, then quit and reopen it before retrying. The current test runner must be trusted; Terminal's grant does not transfer to ChatGPT/Codex, and SSH sessions do not inherit it."
fi

log "stopping existing app processes"
pkill -f '/Xe Computer.app/Contents/MacOS/bin' 2>/dev/null || true

log "detaching stale installer disk images"
while IFS= read -r stale_mount; do
    detach_disk_image "$stale_mount"
done < <(find /Volumes -maxdepth 1 -type d -name 'Xe Computer*' -print 2>/dev/null)

# An interrupted first-open confirmation can leave the image attached to a
# /dev/disk node with no mounted volume. `open` then returns successfully but
# never creates /Volumes/Xe Computer, so clean up matching device attachments
# as well as normal mount points.
while IFS= read -r stale_device; do
    detach_disk_image "$stale_device"
done < <(
    hdiutil info | awk -v target="$DMG_PATH" '
        /^image-path[[:space:]]*:/ {
            image_path = $0
            sub(/^[^:]*:[[:space:]]*/, "", image_path)
            matches_target = (image_path == target)
            next
        }
        matches_target && /^\/dev\/disk[0-9]+[[:space:]]/ {
            print $1
            matches_target = 0
        }
    '
)

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
volume_relative_path="${SOURCE_APP#/Volumes/}"
volume_name="${volume_relative_path%%/*}"
MOUNT_POINT="/Volumes/${volume_name}"
log "found source app at $SOURCE_APP"

# The same signature and Gatekeeper requirements are asserted again on the
# installed copy below. Check the source before deleting an existing install,
# app data, or Colima so a broken release artifact cannot damage test state.
log "verifying source signature and Gatekeeper assessment"
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP" \
    || fail "source app has an invalid code signature: $SOURCE_APP"
spctl --assess --type execute --verbose=2 "$SOURCE_APP" \
    || fail "Gatekeeper rejected the source app: $SOURCE_APP"

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

if [[ -e "$APP_DATA" ]]; then
    trash_dir="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    rmdir "$trash_dir"
    log "moving existing app data to $trash_dir"
    mv "$APP_DATA" "$trash_dir"
fi

log "uninstalling Colima so first-run dependency installation is exercised"
if brew list --formula colima >/dev/null 2>&1; then
    brew uninstall --force colima
fi

log "opening the app from the disk image through Launch Services"
open "$SOURCE_APP"

log "checking for the Gatekeeper first-open confirmation"
if press_ui_button "" "Open" "downloaded from the Internet" 15; then
    log "approved the Gatekeeper first-open confirmation"
else
    log "no Gatekeeper first-open confirmation appeared"
fi

log "approving the real installer alert"
press_ui_button "$BUNDLE_ID" "Install in Applications" "" 60

log "waiting for the installed bundle to be created"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )) && [[ ! -d "$INSTALLED_APP" ]]; do
    sleep 0.25
done
[[ -d "$INSTALLED_APP" ]] || fail "installed app was not created at $INSTALLED_APP"

log "checking for a Gatekeeper confirmation for the installed copy"
if press_ui_button "" "Open" "downloaded from the Internet" 10; then
    log "approved the Gatekeeper confirmation for the installed copy"
else
    log "no Gatekeeper confirmation appeared for the installed copy"
fi

log "opening the Accessibility privacy pane"
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'

log "granting Accessibility access to the installed app"
grant_accessibility_permission "$APP_NAME" 90

log "waiting for installation and relaunch"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$INSTALLED_APP" ]] && pgrep -f '/Applications/Xe Computer.app/Contents/MacOS/bin' >/dev/null; then
        break
    fi
    sleep 1
done

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
