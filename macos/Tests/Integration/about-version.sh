#!/bin/bash

set -euo pipefail

APP_NAME="Xe Computer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"

log() {
    printf '[about-version-integration] %s\n' "$*"
}

fail() {
    printf '[about-version-integration] ERROR: %s\n' "$*" >&2
    exit 1
}

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
        printf '[about-version-integration] ERROR: UI command timed out after %s seconds\n' \
            "$timeout_seconds" >&2
        return 124
    fi
    return "$command_status"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "this test must run on macOS"
[[ -d "$INSTALLED_APP" ]] || fail "installed app not found at: $INSTALLED_APP"

if [[ -z "$EXPECTED_VERSION" ]]; then
    EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :XeReleaseVersion' \
        "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "$EXPECTED_VERSION" ]]; then
    EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
[[ -n "$EXPECTED_VERSION" ]] || fail "could not determine the expected version"

pgrep -f '/Applications/Xe Computer.app/Contents/MacOS/bin' >/dev/null \
    || fail "the installed app is not running"

log "opening About from the status menu and expecting version $EXPECTED_VERSION"
if ! run_with_timeout 45 osascript - \
    "$APP_NAME" "$EXPECTED_VERSION" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set expectedVersion to item 2 of argv
    set aboutOpened to false

    tell application "System Events"
        set targetProcess to missing value
        repeat 80 times
            try
                if exists application process appName then
                    set targetProcess to application process appName
                end if
            end try
            if targetProcess is not missing value then exit repeat
            delay 0.25
        end repeat
        if targetProcess is missing value then error "Could not find the installed app process"
        log "Located the " & appName & " process"

        -- Locate the status item by behavior instead of relying on its menu-bar
        -- index or accessibility title, both of which vary between macOS hosts.
        repeat with uiMenuBar in menu bars of targetProcess
            repeat with uiMenuBarItem in menu bar items of uiMenuBar
                try
                    click uiMenuBarItem
                    delay 0.2
                    if exists menu 1 of uiMenuBarItem then
                        if exists menu item "About" of menu 1 of uiMenuBarItem then
                            click menu item "About" of menu 1 of uiMenuBarItem
                            set aboutOpened to true
                            exit repeat
                        end if
                    end if
                    key code 53
                end try
            end repeat
            if aboutOpened then exit repeat
        end repeat
        if not aboutOpened then error "Could not find About in the status menu"
        log "Opened About from the status menu"

        set foundAboutPanel to false
        log "Inspecting the About panel contents"
        repeat 80 times
            if exists window 1 of targetProcess then
                set uiWindow to window 1 of targetProcess
                set headingMatches to false
                set versionMatches to false
                set displayedTexts to {}

                -- The standard panel exposes its visible heading and version
                -- as direct static texts. Do not request "entire contents":
                -- recursive AX traversal can block System Events indefinitely.
                try
                    set displayedTexts to displayedTexts & (name of every static text of uiWindow)
                end try
                try
                    set displayedTexts to displayedTexts & (value of every static text of uiWindow)
                end try

                repeat with displayedText in displayedTexts
                    try
                        set displayedTextValue to displayedText as text
                        if displayedTextValue is appName then set headingMatches to true
                        if displayedTextValue is expectedVersion or displayedTextValue is ("Version " & expectedVersion) or displayedTextValue starts with ("Version " & expectedVersion & " (") then
                            set versionMatches to true
                        end if
                    end try
                end repeat

                if headingMatches then set foundAboutPanel to true
                if headingMatches and versionMatches then
                    if (frontmost of targetProcess) is false then
                        error "About dialog opened without bringing the app to the foreground"
                    end if

                    try
                        perform action "AXClose" of uiWindow
                    end try
                    return expectedVersion
                end if
            end if
            delay 0.25
        end repeat
        if foundAboutPanel then
            error "About dialog displayed the " & appName & " heading but not expected version " & expectedVersion
        end if
        error "Could not identify the About dialog by its " & appName & " heading"
    end tell
end run
APPLESCRIPT
then
    fail "About dialog verification failed"
fi

log "PASS: About dialog opened in front and displayed version $EXPECTED_VERSION"
