#!/bin/bash

set -euo pipefail

APP_NAME="Xe Launcher"
BUNDLE_ID="dev.xe.computer"
INSTALLED_APP="/Applications/${APP_NAME}.app"
APP_DATA="${HOME}/Library/Application Support/${BUNDLE_ID}"
PERMANENT_CLEANUP=0
STOP_ONLY=0

log() {
    printf '[installer-cleanup] %s\n' "$*"
}

fail() {
    printf '[installer-cleanup] ERROR: %s\n' "$*" >&2
    exit 1
}

require_ci_context() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] \
        || fail "permanent cleanup requires GitHub Actions"
    [[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]] \
        || fail "permanent cleanup requires a self-hosted runner"
    [[ "${RUNNER_OS:-}" == "macOS" && "${RUNNER_ARCH:-}" == "ARM64" ]] \
        || fail "permanent cleanup requires the macOS ARM64 runner"
    [[ "${GITHUB_REPOSITORY:-}" == "Agent54/xe-computer-launcher" ]] \
        || fail "permanent cleanup requires the launcher repository"
    if [[ "${GITHUB_WORKFLOW_REF:-}" == "Agent54/xe-computer-launcher/.github/workflows/main-release.yml@"* ]]; then
        [[ "${GITHUB_JOB:-}" == "release" && "${GITHUB_EVENT_NAME:-}" == "push" ]] \
            || fail "permanent cleanup requires the release job triggered by a push"
        [[ "${GITHUB_REF_NAME:-}" == "int" || "${GITHUB_REF_NAME:-}" == "main" ]] \
            || fail "permanent cleanup requires the int or main release branch"
    elif [[ "${GITHUB_WORKFLOW_REF:-}" == "Agent54/xe-computer-launcher/.github/workflows/pr-build.yml@"* ]]; then
        [[ "${GITHUB_JOB:-}" == "launcher-integration" && "${GITHUB_EVENT_NAME:-}" == "pull_request" \
            && "${GITHUB_BASE_REF:-}" == "main" ]] \
            || fail "permanent cleanup requires the integration job for a main-branch pull request"
    else
        fail "permanent cleanup requires the launcher release or integration workflow"
    fi
}

configure_cleanup_mode() {
    case "$#:${1:-}" in
        0:)
            PERMANENT_CLEANUP=0
            ;;
        1:--ci-permanent)
            require_ci_context
            PERMANENT_CLEANUP=1
            ;;
        1:--stop-only)
            STOP_ONLY=1
            ;;
        *)
            fail "usage: cleanup.sh [--ci-permanent|--stop-only]"
            ;;
    esac
}

refuse_mounted_cleanup_target() {
    local path="$1"
    local parent_device
    local path_device
    local descendant
    local descendant_device
    local mount_output
    local mount_record
    local mount_point

    [[ -d "$path" && ! -L "$path" ]] || return 0

    mount_output="$(mount)" || fail "could not inspect mounted filesystems"
    while IFS= read -r mount_record; do
        mount_point="${mount_record#* on }"
        [[ "$mount_point" != "$mount_record" ]] || continue
        mount_point="${mount_point% (*}"
        [[ "$mount_point" == "$path" || "$mount_point" == "$path/"* ]] \
            && fail "refusing to remove cleanup target containing a mount point: $mount_point"
    done <<<"$mount_output"

    path_device="$(stat -f '%d' "$path")" \
        || fail "could not inspect cleanup target filesystem: $path"
    parent_device="$(stat -f '%d' "$(dirname "$path")")" \
        || fail "could not inspect cleanup target parent filesystem: $path"
    [[ "$path_device" == "$parent_device" ]] \
        || fail "refusing to remove mounted cleanup target: $path"

    while IFS= read -r -d '' descendant; do
        descendant_device="$(stat -f '%d' "$descendant")" \
            || fail "could not inspect cleanup target descendant: $descendant"
        [[ "$descendant_device" == "$path_device" ]] \
            || fail "refusing to cross nested mount during cleanup: $descendant"
    done < <(find -x "$path" -type d -print0)
}

permanently_remove_owned_path() {
    local path="$1"

    case "$path" in
        "/Applications/Xe Launcher.app" | \
        "${HOME}/Library/Application Support/dev.xe.computer" | \
        "${HOME}/Applications/Chromium Apps.localized/Xe Computer.app" | \
        "${HOME}/Applications/Chrome Canary Apps.localized/Xe Computer.app" | \
        "${HOME}/Applications/Chromium Apps.localized/Xe Computer Dev.app" | \
        "${HOME}/Applications/Chrome Canary Apps.localized/Xe Computer Dev.app")
            ;;
        *)
            fail "refusing permanent removal of unowned path: $path"
            ;;
    esac

    refuse_mounted_cleanup_target "$path"
    rm -rf -- "$path"
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

    if [[ "$PERMANENT_CLEANUP" == "1" ]]; then
        log "permanently removing stale generated app shim at $shim_path"
        permanently_remove_owned_path "$shim_path"
    else
        trashed_shim="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-shim-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
        rmdir "$trashed_shim"
        log "moving stale generated app shim to $trashed_shim"
        mv "$shim_path" "$trashed_shim"
    fi
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
configure_cleanup_mode "$@"

log "stopping existing app processes"
bundle_id_pattern="${BUNDLE_ID//./[.]}"
launcher_pattern='/X[Ee] Launcher[.]app/Contents/MacOS/bin'
if [[ "$STOP_ONLY" == "1" ]]; then
    # Ask Cocoa to quit normally so the launcher can stop Workerd, Compose,
    # Helium, the shim, and its VM before we force any remaining process out.
    log "requesting graceful Xe Launcher shutdown"
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' 10 \
        osascript -l JavaScript -e 'ObjC.import("AppKit"); var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("dev.xe.computer"); for (var i = 0; i < apps.count; i++) apps.objectAtIndex(i).terminate();' \
        || log "Launch Services quit request failed; falling back to process signals"
    for _ in {1..140}; do
        pgrep -f "$launcher_pattern" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi
stop_matching_processes \
    "Xe Launcher instances" \
    "$launcher_pattern"
stop_matching_processes \
    "orphaned Xe Launcher workerd processes" \
    '/X[Ee] Launcher[.]app/Contents/Helpers/workerd( |$)'
stop_matching_processes \
    "orphaned Xe Launcher SmolVM processes" \
    '/X[Ee] Launcher[.]app/Contents/Helpers/SmolRuntime/smolvm-bin( |$)'
stop_matching_processes \
    "Xe Launcher worker-bridge processes" \
    '/X[Ee] Launcher[.]app/Contents/MacOS/port-helper --exec-workerd'
stop_matching_processes \
    "Xe Computer app shims" \
    "/Library/Application Support/${bundle_id_pattern}/shims/.*/Xe Computer[^/]*[.]app/Contents/MacOS/app_mode_loader"
stop_matching_processes \
    "Xe Computer app shims launched by Xe Launcher's Helium" \
    "app_mode_loader .*--launched-by-chrome-bundle-path=.*/Library/Application Support/${bundle_id_pattern}/Helium[.]app"
stop_matching_processes \
    "Xe Launcher's Helium and helper processes" \
    "/Library/Application Support/${bundle_id_pattern}/Helium[.]app/"

if [[ "$STOP_ONLY" == "1" ]]; then
    log "app processes stopped; preserving the installed app, shim files, data, port helper, and permissions"
    exit 0
fi

# Removing the app data would otherwise strand a trusted CA in the user's
# Keychain with no remaining certificate file for a later cleanup to identify.
root_certificate="$APP_DATA/workerd/ui-https/root.crt"
leaf_certificate="$APP_DATA/workerd/ui-https/ui.crt"
if [[ -f "$root_certificate" && -f "$leaf_certificate" ]] \
    && security verify-cert -q -L -p ssl -n compose-ui.localhost \
        -c "$leaf_certificate" -c "$root_certificate" >/dev/null 2>&1; then
    log "removing local HTTPS certificate trust"
    security remove-trusted-cert "$root_certificate" \
        || fail "could not remove local HTTPS certificate trust before deleting its source"
fi

if [[ -x "$INSTALLED_APP/Contents/MacOS/bin" ]] \
    && [[ "$(plutil -extract XePortHelperUnregisterCLI raw "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)" == "true" ]]; then
    log "unregistering Xe Launcher's port helper"
    "$INSTALLED_APP/Contents/MacOS/bin" --unregister-port-helper \
        || fail "could not unregister the port helper before removing the installed app"
fi

log "removing stale generated app shims"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chromium Apps.localized/Xe Computer.app"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chrome Canary Apps.localized/Xe Computer.app"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chromium Apps.localized/Xe Computer Dev.app"
trash_generated_shim_if_owned \
    "${HOME}/Applications/Chrome Canary Apps.localized/Xe Computer Dev.app"

log "detaching stale installer disk images"
while IFS= read -r stale_mount; do
    detach_disk_image "$stale_mount"
done < <(find /Volumes -maxdepth 1 -type d -iname 'xe launcher*' -print 2>/dev/null)

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
            normalized_path = tolower(image_path)
            matches_xe_dmg = normalized_path ~ /\/xe launcher\.dmg$/ || normalized_path ~ /\/xe\.launcher\.dmg$/
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
    if [[ "$PERMANENT_CLEANUP" == "1" ]]; then
        log "permanently removing existing installed app at $INSTALLED_APP"
        permanently_remove_owned_path "$INSTALLED_APP"
    else
        trashed_app="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-app-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
        rmdir "$trashed_app"
        log "moving existing installed app to $trashed_app"
        mv "$INSTALLED_APP" "$trashed_app"
    fi
fi

log "removing existing app data"
if [[ -e "$APP_DATA" ]]; then
    if [[ "$PERMANENT_CLEANUP" == "1" ]]; then
        log "permanently removing existing app data at $APP_DATA"
        permanently_remove_owned_path "$APP_DATA"
    else
        trashed_data="$(mktemp -d "${HOME}/.Trash/${BUNDLE_ID}-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
        rmdir "$trashed_data"
        log "moving existing app data to $trashed_data"
        mv "$APP_DATA" "$trashed_data"
    fi
fi

log "cleanup complete"
