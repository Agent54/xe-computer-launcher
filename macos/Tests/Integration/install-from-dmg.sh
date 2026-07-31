#!/bin/bash

set -euo pipefail

APP_NAME="XE Launcher"
BUNDLE_ID="dev.xe.computer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
MANAGED_DARC_APP="${APP_DATA}/shims/default/Darc.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_DMG="$(cd "$SCRIPT_DIR/../.." && pwd)/dist/XE Launcher.dmg"
DMG_PATH="${DMG_PATH:-$REPOSITORY_DMG}"
MOUNT_POINT=""
DEV_MODE=false
DEV_INSTALL_ARGUMENT="--xe-computer-development-install"
INSTALLED_RELAUNCH_ARGUMENT="--xe-computer-installed-relaunch"
TEST_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
    printf '[installer-integration] %s\n' "$*"
}

fail() {
    printf '[installer-integration] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dev]

  --dev  Test an ad-hoc-signed development DMG. Strict code-signature checks
         still run, but Gatekeeper assessments requiring Developer ID signing
         and notarization are skipped.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --dev)
            DEV_MODE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

# Apple Events can wait forever when the process running this test has not yet
# been granted Automation or Accessibility access. Keep every UI operation
# bounded so the test reports the real setup problem instead of deadlocking.
run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local command_pid
    local watchdog_pid
    local command_status

    "$@" <&0 &
    command_pid=$!
    (
        sleep "$timeout_seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -TERM "$command_pid" 2>/dev/null || true
        fi
    ) &
    watchdog_pid=$!

    if wait "$command_pid" 2>/dev/null; then
        command_status=0
    else
        command_status=$?
    fi

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [[ "$command_status" -eq 143 ]]; then
        printf '[installer-integration] ERROR: UI command timed out after %s seconds\n' \
            "$timeout_seconds" >&2
        return 124
    fi
    return "$command_status"
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

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
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
                            set matchedProcessName to ""
                            try
                                set matchedProcessName to name of uiProcess as text
                            end try
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
                            return matchedProcessName
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

# Directly launched development apps appear to System Events under their
# executable name ("bin") instead of their bundle identifier. Target that
# process without enumerating every GUI process.
press_process_button() {
    local process_name="$1"
    local button_name="$2"
    local context_text="$3"
    local timeout_seconds="$4"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$process_name" "$button_name" "$context_text" "$timeout_seconds" <<'APPLESCRIPT'
on run argv
    set processName to item 1 of argv
    set wantedButtonName to item 2 of argv
    set wantedContext to item 3 of argv
    set timeoutSeconds to item 4 of argv as integer

    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            if exists application process processName then
                tell application process processName
                    repeat with uiWindow in windows
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
                            try
                                perform action "AXPress" of targetButton
                            end try
                            return processName
                        end if
                    end repeat
                end tell
            end if
            delay 0.25
        end repeat
        error "Timed out waiting for " & processName & " button “" & wantedButtonName & "”"
    end tell
end run
APPLESCRIPT
}

# Accessibility requests are presented by macOS in a dedicated system process.
# A previous interrupted run can leave another request for the same app queued
# in front of the current one. Press every matching native prompt so none remain
# pending when the test enables the app in System Settings.
drain_accessibility_permission_prompts() {
    local app_name="$1"
    local timeout_seconds="$2"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$app_name" "$timeout_seconds" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set timeoutSeconds to item 2 of argv as integer
    set pressedCount to 0
    set quietPollCount to 0

    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            set pressedPrompt to false

            if exists application process "universalAccessAuthWarn" then
                tell application process "universalAccessAuthWarn"
                    repeat with uiWindow in windows
                        set uiElements to {}
                        try
                            set uiElements to entire contents of uiWindow
                        end try

                        set contextMatches to false
                        set targetButton to missing value
                        repeat with uiElement in uiElements
                            try
                                set elementName to name of uiElement as text
                                if elementName is "Open System Settings" and role of uiElement is "AXButton" then
                                    set targetButton to uiElement
                                end if
                                if elementName contains appName and elementName contains "accessibility features" then
                                    set contextMatches to true
                                end if
                            end try
                            try
                                set elementValue to value of uiElement as text
                                if elementValue contains appName and elementValue contains "accessibility features" then
                                    set contextMatches to true
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

                            set pressedPrompt to true
                            exit repeat
                        end if
                    end repeat
                end tell
            end if

            if pressedPrompt then
                set pressedCount to pressedCount + 1
                set quietPollCount to 0
            else if pressedCount > 0 then
                set quietPollCount to quietPollCount + 1
                if quietPollCount ≥ 8 then return pressedCount
                delay 0.25
            else
                delay 0.25
            end if
        end repeat
        error "Timed out waiting for the native macOS Accessibility prompt for " & appName
    end tell
end run
APPLESCRIPT
}

grant_accessibility_permission() {
    local app_name="$1"
    local timeout_seconds="$2"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
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
                        set isAccessibilityPane to false
                        try
                            set isAccessibilityPane to (name of uiWindow as text) is "Accessibility"
                        end try

                        if isAccessibilityPane then
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
                        end if
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

if ! run_with_timeout 8 osascript \
    -e 'tell application "System Events" to tell first application process whose frontmost is true to get count of menu bars' \
    >/dev/null 2>&1; then
    fail "UI automation lacks Accessibility access (or macOS blocked its Automation request). In System Settings > Privacy & Security > Accessibility, enable the GUI-session runner that launches this test, then quit and reopen it before retrying. The current test runner must be trusted; Terminal's grant does not transfer to ChatGPT/Codex, and SSH sessions do not inherit it."
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
volume_relative_path="${SOURCE_APP#/Volumes/}"
volume_name="${volume_relative_path%%/*}"
MOUNT_POINT="/Volumes/${volume_name}"
log "found source app at $SOURCE_APP"

log "verifying source signature"
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP" \
    || fail "source app has an invalid code signature: $SOURCE_APP"
if [[ "$DEV_MODE" == true ]]; then
    log "development mode: skipping source Gatekeeper assessment"
else
    log "verifying source Gatekeeper assessment"
    spctl --assess --type execute --verbose=2 "$SOURCE_APP" \
        || fail "Gatekeeper rejected the source app: $SOURCE_APP"
fi

if [[ "$DEV_MODE" == true ]]; then
    log "development mode: dismissing stale Gatekeeper denial dialogs"
    if press_ui_button "" "Done" "free of malware" 2 2>/dev/null; then
        log "dismissed a stale Gatekeeper denial dialog"
    fi
    log "development mode: launching the app directly from the disk image"
    "$SOURCE_APP/Contents/MacOS/bin" "$DEV_INSTALL_ARGUMENT" &
else
    log "opening the app from the disk image through Launch Services"
    open "$SOURCE_APP"

    log "checking for the Gatekeeper first-open confirmation"
    if press_ui_button "" "Open" "downloaded from the Internet" 15; then
        log "approved the Gatekeeper first-open confirmation"
    else
        log "no Gatekeeper first-open confirmation appeared"
    fi
fi

log "approving the real installer alert"
if [[ "$DEV_MODE" == true ]]; then
    press_process_button "bin" "Install in Applications" "Install XE Launcher?" 60
else
    press_ui_button "$BUNDLE_ID" "Install in Applications" "" 60
fi

log "waiting for the installed bundle to be created"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )) && [[ ! -d "$INSTALLED_APP" ]]; do
    sleep 0.25
done
[[ -d "$INSTALLED_APP" ]] || fail "installed app was not created at $INSTALLED_APP"

if [[ "$DEV_MODE" == true ]]; then
    log "development mode: skipping Gatekeeper confirmation for the installed copy"
    log "development mode: waiting for the disk-image copy to exit"
    deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )) && pgrep -f "${MOUNT_POINT}/.*\.app/Contents/MacOS/bin" >/dev/null; do
        sleep 0.1
    done
    pgrep -f "${MOUNT_POINT}/.*\.app/Contents/MacOS/bin" >/dev/null \
        && fail "disk-image copy did not exit after development installation"

    log "development mode: removing quarantine from the installed copy"
    xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
    if xattr -pr com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1; then
        fail "could not remove quarantine from the development installation"
    fi

    log "development mode: launching the installed app through Launch Services"
    # Launching the Mach-O directly makes the test runner the TCC-responsible
    # process. Launch Services gives the installed bundle its own audit identity,
    # which is required for the native Accessibility prompt and settings row to
    # be attributed to XE Launcher.
    open -n "$INSTALLED_APP" --args "$INSTALLED_RELAUNCH_ARGUMENT"
else
    log "checking for a Gatekeeper confirmation for the installed copy"
    if press_ui_button "" "Open" "downloaded from the Internet" 10; then
        log "approved the Gatekeeper confirmation for the installed copy"
    else
        log "no Gatekeeper confirmation appeared for the installed copy"
    fi
fi

log "accepting the native macOS Accessibility permission prompt"
drain_accessibility_permission_prompts "$APP_NAME" 60

log "granting Accessibility access to the installed app"
grant_accessibility_permission "$APP_NAME" 90

log "waiting for installation and relaunch"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$INSTALLED_APP" ]] && pgrep -f '/Applications/XE Launcher.app/Contents/MacOS/bin' >/dev/null; then
        break
    fi
    sleep 1
done

pgrep -f '/Applications/XE Launcher.app/Contents/MacOS/bin' >/dev/null \
    || fail "installed app did not relaunch from /Applications"

log "verifying installed signature"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
if [[ "$DEV_MODE" == true ]]; then
    log "development mode: skipping installed Gatekeeper assessment"
else
    log "verifying installed Gatekeeper assessment"
    spctl --assess --type execute --verbose=2 "$INSTALLED_APP"
fi

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

log "waiting for the managed Darc app shim"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$MANAGED_DARC_APP" ]] \
        && pgrep -f "${MANAGED_DARC_APP}/Contents/MacOS/app_mode_loader" >/dev/null; then
        break
    fi
    sleep 1
done
[[ -d "$MANAGED_DARC_APP" ]] \
    || fail "Darc app shim was not provisioned at $MANAGED_DARC_APP"
pgrep -f "${MANAGED_DARC_APP}/Contents/MacOS/app_mode_loader" >/dev/null \
    || fail "Darc app shim did not launch from its managed location"

log "checking that setup did not request App Management permission"
app_management_events="$(
    /usr/bin/log show \
        --start "$TEST_STARTED_AT" \
        --style compact \
        --predicate \
        'process == "tccd" AND eventMessage CONTAINS[c] "kTCCServiceSystemPolicyAppBundles" AND eventMessage CONTAINS[c] "identifier=dev.xe.computer"' \
        2>/dev/null \
        | tail -n +2
)"
[[ -z "$app_management_events" ]] \
    || fail "XE Launcher triggered macOS App Management protection:\n$app_management_events"

app_management_denials="$(
    /usr/bin/log show \
        --start "$TEST_STARTED_AT" \
        --style compact \
        --predicate \
        'process == "tccd" AND eventMessage CONTAINS[c] "kTCCServiceSystemPolicyAppBundles" AND eventMessage CONTAINS[c] "returning denied"' \
        2>/dev/null \
        | tail -n +2
)"
[[ -z "$app_management_denials" ]] \
    || fail "macOS denied an App Management request during XE Launcher setup:\n$app_management_denials"

if [[ "$DEV_MODE" == true ]]; then
    log "PASS: development DMG installation, relaunch, signature, quarantine, Colima, Darc, and permission checks succeeded"
else
    log "PASS: DMG installation, relaunch, signature, Gatekeeper, quarantine, Colima, Darc, and permission checks succeeded"
fi
