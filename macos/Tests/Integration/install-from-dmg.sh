#!/bin/bash

set -euo pipefail

APP_NAME="Xe Launcher"
BUNDLE_ID="dev.xe.computer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
MANAGED_XE_COMPUTER_APP="${APP_DATA}/shims/default/Xe Computer.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_DMG="$(cd "$SCRIPT_DIR/../.." && pwd)/dist/Xe Launcher.dmg"
DMG_PATH="${DMG_PATH:-$REPOSITORY_DMG}"
MOUNT_POINT=""
DEV_MODE=false
DEV_INSTALL_ARGUMENT="--xe-computer-development-install"
INSTALLED_RELAUNCH_ARGUMENT="--xe-computer-installed-relaunch"
TEST_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
runner_password="${XE_CI_MAC_PASSWORD:-}"
unset XE_CI_MAC_PASSWORD
runner_permission_auth_pid=""
runner_certificate_auth_pid=""

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

# The optional secret is passed only to this short-lived GUI helper, never as
# a command-line argument or to the applications under test. Only enter it in
# a matching macOS authorization dialog with a password field and text tying
# the request to Xe Launcher, System Settings, or Xe's generated certificate.
start_runner_auth_helper() {
    local auth_kind="${1:-permission}"
    [[ -n "$runner_password" ]] || return 0
    XE_CI_MAC_PASSWORD="$runner_password" \
        XE_CI_AUTH_KIND="$auth_kind" \
        XE_CI_CERT_PATH="$APP_DATA/workerd/ui-https/root.crt" \
        osascript -l JavaScript "$SCRIPT_DIR/authorize-macos-dialog.jxa" 2>/dev/null &
    if [[ "$auth_kind" == certificate ]]; then
        runner_certificate_auth_pid=$!
    else
        runner_permission_auth_pid=$!
    fi
    log "optional macOS authorization helper is watching for a $auth_kind password dialog"
}

stop_runner_auth_helper() {
    local auth_kind="${1:-all}"
    if [[ "$auth_kind" == all || "$auth_kind" == permission ]]; then
        if [[ -n "$runner_permission_auth_pid" ]]; then
            kill "$runner_permission_auth_pid" 2>/dev/null || true
            wait "$runner_permission_auth_pid" 2>/dev/null || true
            runner_permission_auth_pid=""
        fi
    fi
    if [[ "$auth_kind" == all || "$auth_kind" == certificate ]]; then
        if [[ -n "$runner_certificate_auth_pid" ]]; then
            kill "$runner_certificate_auth_pid" 2>/dev/null || true
            wait "$runner_certificate_auth_pid" 2>/dev/null || true
            runner_certificate_auth_pid=""
        fi
    fi
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
    local control_role="${5:-AXButton}"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$process_bundle_id" "$button_name" "$context_text" "$timeout_seconds" "$control_role" <<'APPLESCRIPT'
on run argv
    set wantedBundleID to item 1 of argv
    set wantedButtonName to item 2 of argv
    set wantedContext to item 3 of argv
    set timeoutSeconds to item 4 of argv as integer
    set wantedRole to item 5 of argv

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
                                if elementName is wantedButtonName and role of uiElement is wantedRole then
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
                            if wantedRole is "AXCheckBox" then
                                if value of targetButton as integer is 1 then return matchedProcessName
                            end if
                            set buttonPosition to position of targetButton
                            set buttonSize to size of targetButton

                            try
                                perform action "AXPress" of targetButton
                            end try
                            delay 0.5

                            if wantedRole is "AXCheckBox" then
                                if value of targetButton as integer is 1 then return matchedProcessName
                                click at {item 1 of buttonPosition + (item 1 of buttonSize div 2), item 2 of buttonPosition + (item 2 of buttonSize div 2)}
                                delay 0.5
                                if value of targetButton as integer is not 1 then error "Could not select standard app ports"
                                return matchedProcessName
                            end if

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
        error "Timed out waiting for control “" & wantedButtonName & "”"
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
    local certificate_path="$APP_DATA/workerd/ui-https/root.crt"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$app_name" "$timeout_seconds" "$certificate_path" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set timeoutSeconds to item 2 of argv as integer
    set certificatePath to item 3 of argv
    set wantedIdentifier to appName & "_Toggle"

    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            if exists disk item certificatePath of application "System Events" then return "app continued"
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
                                    set toggleValue to -1
                                    try
                                        set toggleValue to value of uiElement as integer
                                    end try
                                    if toggleValue is 1 then return "Accessibility switch is on"
                                    if toggleValue is 0 then
                                        set togglePosition to position of uiElement
                                        set toggleSize to size of uiElement
                                        try
                                            perform action "AXPress" of uiElement
                                        on error
                                            click at {item 1 of togglePosition + (item 1 of toggleSize div 2), item 2 of togglePosition + (item 2 of toggleSize div 2)}
                                        end try
                                        log "Clicked the Xe Launcher Accessibility switch; waiting for macOS approval"
                                        return "Accessibility switch was clicked"
                                    end if
                                    exit repeat
                                end if
                            end repeat
                        end if
                    end repeat
                end tell
            end if

            if attemptNumber mod 40 is 0 then log "Still waiting for the Accessibility switch for " & appName
            delay 0.25
        end repeat
        error "Timed out waiting for the Accessibility switch for " & appName
    end tell
end run
APPLESCRIPT

    # The switch can show on before the running app sees its new TCC grant.
    # Certificate generation is the first step after the app's own trust check.
    # Poll the filesystem here so a subsequent password prompt cannot block
    # another System Settings Accessibility traversal.
    local deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        [[ -f "$certificate_path" ]] && return 0
        sleep 1
    done
    fail "Xe Launcher did not continue after Accessibility approval; no local HTTPS certificate was generated"
}

grant_background_port_helper_permission() {
    local app_name="$1"
    local timeout_seconds="$2"

    run_with_timeout "$((timeout_seconds + 10))" osascript - \
        "$app_name" "$timeout_seconds" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set timeoutSeconds to item 2 of argv as integer
    set foundAppRow to false
    set foundLoginWindow to false

    log "Inspecting System Settings for the " & appName & " background switch"
    tell application "System Events"
        repeat with attemptNumber from 1 to (timeoutSeconds * 4)
            if exists application process "System Settings" then
                tell application process "System Settings"
                    repeat with uiWindow in windows
                        set windowTitle to ""
                        try
                            set windowTitle to name of uiWindow as text
                        end try
                        if windowTitle contains "Login Items" then
                            if not foundLoginWindow then
                                log "Found the Login Items & Extensions window"
                                set foundLoginWindow to true
                            end if
                            set uiElements to {}
                            try
                                set uiElements to entire contents of uiWindow
                            end try

                            set appLabel to missing value
                            set targetToggle to missing value
                            repeat with uiElement in uiElements
                                set elementName to ""
                                set elementValue to ""
                                set elementRole to ""
                                set elementIdentifier to ""
                                try
                                    set elementName to name of uiElement as text
                                end try
                                try
                                    set elementValue to value of uiElement as text
                                end try
                                try
                                    set elementRole to role of uiElement as text
                                end try
                                try
                                    set elementIdentifier to value of attribute "AXIdentifier" of uiElement as text
                                end try
                                if elementName is appName or elementValue is appName or ¬
                                    (elementRole is "AXStaticText" and (elementName contains appName or elementValue contains appName)) then
                                    set appLabel to uiElement
                                end if
                                if elementIdentifier contains appName and elementIdentifier contains "Toggle" then
                                    set targetToggle to uiElement
                                end if
                            end repeat

                            if appLabel is not missing value then
                                if not foundAppRow then log "Found the " & appName & " background item"
                                set foundAppRow to true
                                if targetToggle is missing value then
                                    set labelPosition to position of appLabel
                                    set labelSize to size of appLabel
                                    set labelY to item 2 of labelPosition + (item 2 of labelSize div 2)
                                    set bestDistance to 100000
                                    repeat with uiElement in uiElements
                                        set elementRole to ""
                                        try
                                            set elementRole to role of uiElement as text
                                        end try
                                        if elementRole is "AXCheckBox" or elementRole is "AXSwitch" then
                                            set togglePosition to position of uiElement
                                            set toggleSize to size of uiElement
                                            set rowDistance to item 2 of togglePosition + (item 2 of toggleSize div 2) - labelY
                                            if rowDistance < 0 then set rowDistance to -rowDistance
                                            set horizontalDistance to item 1 of togglePosition - item 1 of labelPosition
                                            if rowDistance ≤ 30 and horizontalDistance > 0 and horizontalDistance < bestDistance then
                                                set targetToggle to uiElement
                                                set bestDistance to horizontalDistance
                                            end if
                                        end if
                                    end repeat
                                end if
                            end if

                            if targetToggle is not missing value then
                                set toggleValue to -1
                                try
                                    set toggleValue to value of targetToggle as integer
                                end try
                                if toggleValue is 1 then return "switch-on"
                                if toggleValue is 0 then
                                    set togglePosition to position of targetToggle
                                    set toggleSize to size of targetToggle
                                    try
                                        perform action "AXPress" of targetToggle
                                    on error
                                        click at {item 1 of togglePosition + (item 1 of toggleSize div 2), item 2 of togglePosition + (item 2 of toggleSize div 2)}
                                    end try
                                    log "Clicked the Xe Launcher background switch; approval will be checked through launchd"
                                    return "switch-clicked"
                                end if
                            end if
                        end if
                    end repeat
                end tell
            end if
            if attemptNumber mod 40 is 0 then
                if foundAppRow then
                    log "Found the Xe Launcher row; still looking for its background switch"
                else
                    log "Still looking for Xe Launcher in Login Items & Extensions"
                end if
            end if
            delay 0.25
        end repeat
    end tell

    if not foundAppRow then error "The " & appName & " row did not appear in Login Items & Extensions > Allow in Background"
    error "The " & appName & " background switch was not found in System Settings"
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
    stop_runner_auth_helper
    if [[ -n "$MOUNT_POINT" ]]; then
        detach_disk_image "$MOUNT_POINT" || true
    fi
}

trap cleanup_mount EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "this test must run on macOS"
[[ -f "$DMG_PATH" ]] || fail "DMG not found at: $DMG_PATH"
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

log "verifying the Applications drag-and-drop target"
[[ -L "$MOUNT_POINT/Applications" ]] \
    || fail "DMG does not contain an Applications folder link"
[[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
    || fail "DMG Applications link does not target /Applications"

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
    press_process_button "bin" "Install in Applications" "Install Xe Launcher?" 60
else
    press_ui_button "$BUNDLE_ID" "Install in Applications" "" 60
fi

log "waiting for the installed bundle to be created"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )) && [[ ! -d "$INSTALLED_APP" ]]; do
    sleep 0.25
done
[[ -d "$INSTALLED_APP" ]] || fail "installed app was not created at $INSTALLED_APP"
[[ -f "$INSTALLED_APP/Contents/Library/LaunchDaemons/dev.xe.computer.ports.plist" ]] \
    || fail "installed app is missing the port helper launch daemon plist"
[[ -x "$INSTALLED_APP/Contents/MacOS/port-helper" ]] \
    || fail "installed app is missing the port helper executable"

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
    # be attributed to Xe Launcher.
    open -n "$INSTALLED_APP" --args "$INSTALLED_RELAUNCH_ARGUMENT"
else
    log "checking for a Gatekeeper confirmation for the installed copy"
    if press_ui_button "" "Open" "downloaded from the Internet" 10; then
        log "approved the Gatekeeper confirmation for the installed copy"
    else
        log "no Gatekeeper confirmation appeared for the installed copy"
    fi
fi

log "selecting standard app ports 80/443"
if ! press_ui_button "$BUNDLE_ID" "Use ports 80/443 for local apps (requires administrator approval)" "Choose user data storage" 60 AXCheckBox; then
    log "listeners on standard ports, if any:"
    lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN || true
    fail "standard app ports could not be selected in the setup dialog"
fi
log "choosing the default user data storage folder"
press_ui_button "$BUNDLE_ID" "Use Default Folder" "Choose user data storage" 60
saved_http_port=""
saved_https_port=""
saved_port_choice=""
deadline=$((SECONDS + 10))
while (( SECONDS < deadline )); do
    saved_http_port="$(plutil -extract app_http_port raw "$APP_DATA/settings.json" 2>/dev/null || true)"
    saved_https_port="$(plutil -extract app_https_port raw "$APP_DATA/settings.json" 2>/dev/null || true)"
    saved_port_choice="$(plutil -extract app_port_choice_confirmed raw "$APP_DATA/settings.json" 2>/dev/null || true)"
    [[ "$saved_http_port" == "80" && "$saved_https_port" == "443" && "$saved_port_choice" == "true" ]] && break
    sleep 0.25
done
[[ "$saved_http_port" == "80" && "$saved_https_port" == "443" && "$saved_port_choice" == "true" ]] \
    || fail "setup saved app ports ${saved_http_port:-unset}/${saved_https_port:-unset} (confirmed: ${saved_port_choice:-unset}), expected confirmed 80/443"

log "checking whether the background port helper needs administrator approval"
if launchctl print system/dev.xe.computer.ports >/dev/null 2>&1; then
    log "port helper is already active"
elif press_ui_button "$BUNDLE_ID" "Open System Settings" "Port Helper Needs Attention" 30 >/dev/null 2>&1; then
    log "enabling Xe Launcher under Allow in Background"
    # Opening the pane is asynchronous. Activate the already-open Settings app
    # without a blocking Apple Event, then bound the optional AX click. macOS
    # may put up a separate administrator dialog that requires a human response.
    run_with_timeout 8 open -a "System Settings" || true
    if ! launchctl print system/dev.xe.computer.ports >/dev/null 2>&1; then
        start_runner_auth_helper
        if ! grant_background_port_helper_permission "$APP_NAME" 60; then
            log "could not confirm the background switch through Accessibility; enable Xe Launcher in System Settings and complete any password prompt"
        fi
    fi

    log "waiting for macOS to finish approving the port helper"
    deadline=$((SECONDS + 120))
    next_approval_update=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        if launchctl print system/dev.xe.computer.ports >/dev/null 2>&1; then
            break
        fi
        if (( SECONDS >= next_approval_update )); then
            log "port helper is not active yet; complete any macOS password prompt"
            next_approval_update=$((SECONDS + 10))
        fi
        sleep 1
    done
    launchctl print system/dev.xe.computer.ports >/dev/null 2>&1 \
        || fail "macOS did not activate the approved port helper; leave its background switch on and complete administrator authentication"
    stop_runner_auth_helper

    log "Xe Launcher should activate ports 80/443 without restarting"
else
    launchctl print system/dev.xe.computer.ports >/dev/null 2>&1 \
        || fail "port helper is not active and its approval dialog did not appear"
fi

# The background-item pane must not be reused for the next permission. The
# native Accessibility prompt opens its own System Settings destination.
log "closing System Settings before Accessibility approval"
pkill -x "System Settings" 2>/dev/null || true
for _ in {1..20}; do
    pgrep -x "System Settings" >/dev/null 2>&1 || break
    sleep 0.25
done
if pgrep -x "System Settings" >/dev/null 2>&1; then
    fail "System Settings did not close before Accessibility approval"
fi

log "accepting the native macOS Accessibility permission prompt"
start_runner_auth_helper
drain_accessibility_permission_prompts "$APP_NAME" 60

log "granting Accessibility access to the installed app"
start_runner_auth_helper certificate
grant_accessibility_permission "$APP_NAME" 90
stop_runner_auth_helper permission

log "approving the generated local HTTPS certificate in the macOS user Keychain"
root_certificate="$APP_DATA/workerd/ui-https/root.crt"
leaf_certificate="$APP_DATA/workerd/ui-https/ui.crt"
certificate_trusted=false
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -f "$root_certificate" && -f "$leaf_certificate" ]] \
        && security verify-cert -q -L -p ssl -n compose-ui.localhost \
            -c "$leaf_certificate" -c "$root_certificate" >/dev/null 2>&1; then
        certificate_trusted=true
        break
    fi
    sleep 1
done
stop_runner_auth_helper certificate
[[ "$certificate_trusted" == true ]] \
    || fail "macOS did not trust Xe Launcher's generated local HTTPS certificate; approve the Keychain authentication prompt"

log "waiting for Compose UI on ports 80 and 443"
standard_ports_ready=false
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
    if /usr/bin/curl --disable --silent --fail --max-time 2 --noproxy '*' \
        --resolve 'compose-ui.localhost:80:127.0.0.1' \
        --output /dev/null 'http://compose-ui.localhost/' \
        && [[ -f "$APP_DATA/workerd/ui-https/root.crt" ]] \
        && /usr/bin/curl --disable --silent --fail --max-time 2 --noproxy '*' \
            --cacert "$APP_DATA/workerd/ui-https/root.crt" \
            --resolve 'compose-ui.localhost:443:127.0.0.1' \
            --output /dev/null 'https://compose-ui.localhost/'; then
        standard_ports_ready=true
        break
    fi
    sleep 1
done
if [[ "$standard_ports_ready" != true ]]; then
    log "listeners on standard ports, if any:"
    lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN || true
    fail "Compose UI did not answer on both 80 and 443; check that the port helper was approved and the ports are free"
fi

/bin/bash "$SCRIPT_DIR/verify-compose-api.sh" "$APP_DATA/stacks/compose.sock"

log "waiting for installation and relaunch"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$INSTALLED_APP" ]] && pgrep -f '/Applications/Xe Launcher.app/Contents/MacOS/bin' >/dev/null; then
        break
    fi
    sleep 1
done

pgrep -f '/Applications/Xe Launcher.app/Contents/MacOS/bin' >/dev/null \
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

sources_manifest="$INSTALLED_APP/Contents/Resources/sources.json"
[[ -f "$sources_manifest" ]] || fail "installed sources manifest is missing"
helium_version="$(plutil -extract helium.version raw "$sources_manifest")"
helium_chromium_version="$(plutil -extract helium.chromiumVersion raw "$sources_manifest")"
helium_sha256="$(plutil -extract helium.sha256 raw "$sources_manifest")"
[[ "$helium_version" == "0.17.2.1" ]] \
    || fail "unexpected pinned Helium version: $helium_version"
[[ "$helium_chromium_version" == "153.0.8010.52" ]] \
    || fail "unexpected pinned Chromium version: $helium_chromium_version"
[[ "$helium_sha256" == "f1a3fecde3c08254f1b1eec30e36ecd25f98cf3799644427fbcefd6e6beafacf" ]] \
    || fail "unexpected pinned Helium SHA-256: $helium_sha256"
installed_helium="$APP_DATA/helium/$helium_version/Helium.app"
[[ -d "$installed_helium" ]] || fail "versioned Helium engine was not installed"
installed_helium_version="$(plutil -extract CFBundleShortVersionString raw "$installed_helium/Contents/Info.plist")"
[[ "$installed_helium_version" == "$helium_version" ]] \
    || fail "installed Helium $installed_helium_version does not match pin $helium_version"
codesign --verify --deep --strict --verbose=2 "$installed_helium"
codesign -dv --verbose=4 "$installed_helium" 2>&1 \
    | grep -Fq 'TeamIdentifier=S4Q33XPHB4' \
    || fail "installed Helium is not signed by the expected Developer ID team"
darc_major="$(plutil -extract darc.version.major raw "$sources_manifest")"
darc_minor="$(plutil -extract darc.version.minor raw "$sources_manifest")"
darc_patch="$(plutil -extract darc.version.patch raw "$sources_manifest")"
darc_bundle="$APP_DATA/darc.${darc_major}.${darc_minor}.${darc_patch}.swbn"

if xattr -p com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1; then
    fail "installed app still has a quarantine attribute"
fi

if pgrep -f "${MOUNT_POINT}/.*\.app/Contents/MacOS/bin" >/dev/null; then
    fail "a copy of the app is still running from the disk image"
fi

log "waiting for the managed Xe Computer app shim"
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if [[ -d "$MANAGED_XE_COMPUTER_APP" ]] \
        && pgrep -f "${MANAGED_XE_COMPUTER_APP}/Contents/MacOS/app_mode_loader" >/dev/null; then
        break
    fi
    sleep 1
done
[[ -d "$MANAGED_XE_COMPUTER_APP" ]] \
    || fail "Xe Computer app shim was not provisioned at $MANAGED_XE_COMPUTER_APP"
[[ -f "$darc_bundle" ]] \
    || fail "versioned Xe Computer bundle was not saved at $darc_bundle"
pgrep -f "${MANAGED_XE_COMPUTER_APP}/Contents/MacOS/app_mode_loader" >/dev/null \
    || fail "Xe Computer app shim did not launch from its managed location"

darc_profile_bundle=""
while IFS= read -r candidate_bundle; do
    if cmp -s "$darc_bundle" "$candidate_bundle"; then
        darc_profile_bundle="$candidate_bundle"
        break
    fi
done < <(
    find "$APP_DATA/profiles/default/Default/iwa" \
        -mindepth 2 -maxdepth 2 -type f -name main.swbn -print
)
[[ -n "$darc_profile_bundle" ]] \
    || fail "Chromium profile is not using the configured Xe Computer bundle"

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
    || fail "Xe Launcher triggered macOS App Management protection:\n$app_management_events"

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
    || fail "macOS denied an App Management request during Xe Launcher setup:\n$app_management_denials"

if [[ "$DEV_MODE" == true ]]; then
    log "PASS: development DMG installation, relaunch, signature, quarantine, Xe Computer, and permission checks succeeded"
else
    log "PASS: DMG installation, relaunch, signature, Gatekeeper, quarantine, Xe Computer, and permission checks succeeded"
fi
