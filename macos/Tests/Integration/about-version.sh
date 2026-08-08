#!/bin/bash

set -euo pipefail

APP_NAME="Xe Launcher"
INSTALLED_APP="${INSTALLED_APP:-/Applications/${APP_NAME}.app}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
STATUS_MENU_IDENTIFIER="dev.xe.computer.status-menu"
STATUS_MENU_LABEL="Xe Launcher status menu"

log() {
    printf '[about-version-integration] %s\n' "$*"
}

fail() {
    printf '[about-version-integration] ERROR: %s\n' "$*" >&2
    exit 1
}

osascript_with_timeout() {
    local timeout_seconds="$1"
    shift

    perl -e '
        use strict;
        use warnings;
        my $timeout = shift @ARGV;
        $SIG{ALRM} = sub { die "__ABOUT_UI_TIMEOUT__\n" };
        alarm $timeout;
        exec @ARGV or die "exec @ARGV failed: $!\n";
    ' "$timeout_seconds" "$@"
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

pgrep -f "$INSTALLED_APP/Contents/MacOS/bin" >/dev/null \
    || fail "the installed app is not running"

log "opening About from the status menu and expecting version $EXPECTED_VERSION"
if ! osascript_with_timeout 45 osascript - \
    "$APP_NAME" "$EXPECTED_VERSION" \
    "$STATUS_MENU_IDENTIFIER" "$STATUS_MENU_LABEL" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set expectedVersion to item 2 of argv
    set statusMenuIdentifier to item 3 of argv
    set statusMenuLabel to item 4 of argv

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

        -- Close any menu left open by the previously active application.
        key code 53

        set statusMenuItem to missing value
        repeat with uiMenuBar in menu bars of targetProcess
            repeat with uiMenuBarItem in menu bar items of uiMenuBar
                set itemMatches to false
                try
                    set elementIdentifier to value of attribute "AXIdentifier" of uiMenuBarItem as text
                    if elementIdentifier is statusMenuIdentifier then set itemMatches to true
                end try
                try
                    if (name of uiMenuBarItem as text) is statusMenuLabel then set itemMatches to true
                end try
                try
                    if (description of uiMenuBarItem as text) is statusMenuLabel then set itemMatches to true
                end try
                try
                    if (subrole of uiMenuBarItem as text) is "AXMenuExtra" then set itemMatches to true
                end try

                if itemMatches then
                    set statusMenuItem to uiMenuBarItem
                    exit repeat
                end if
            end repeat
            if statusMenuItem is not missing value then exit repeat
        end repeat

        if statusMenuItem is missing value then
            error "Could not find the Xe Launcher status item"
        end if

        click statusMenuItem
        set statusMenuOpened to false
        repeat 20 times
            if exists menu 1 of statusMenuItem then
                set statusMenuOpened to true
                exit repeat
            end if
            delay 0.25
        end repeat
        if not statusMenuOpened then
            error "Xe Launcher status menu did not open"
        end if
        if not (exists menu item "About" of menu 1 of statusMenuItem) then
            error "Could not find About in the Xe Launcher status menu"
        end if
        click menu item "About" of menu 1 of statusMenuItem
        log "Opened About from the status menu"

        set foundAboutPanel to false
        log "Inspecting the About panel contents"
        repeat 80 times
            repeat with uiWindow in windows of targetProcess
                set headingMatches to false
                set versionMatches to false
                set uiElements to {}
                try
                    set uiElements to entire contents of uiWindow
                end try

                -- Depending on the macOS release, Accessibility may expose the
                -- heading and version as separate elements or coalesce them into
                -- one value such as "Xe Launcher Version 1.0 (1)".
                repeat with uiElement in uiElements
                    set displayedTexts to {}
                    try
                        set end of displayedTexts to name of uiElement as text
                    end try
                    try
                        set end of displayedTexts to value of uiElement as text
                    end try
                    try
                        set end of displayedTexts to description of uiElement as text
                    end try

                    repeat with displayedText in displayedTexts
                        set displayedTextValue to displayedText as text
                        if displayedTextValue contains appName then
                            set headingMatches to true
                        end if
                        if displayedTextValue contains expectedVersion then
                            set versionMatches to true
                        end if
                    end repeat
                end repeat

                if headingMatches then set foundAboutPanel to true
                if headingMatches and versionMatches then
                    set aboutFocused to false
                    try
                        set aboutFocused to value of attribute "AXFocused" of uiWindow
                    end try
                    if aboutFocused is not true then
                        error "About dialog opened without focusing its window"
                    end if

                    try
                        perform action "AXClose" of uiWindow
                    end try
                    return expectedVersion
                end if
            end repeat
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
