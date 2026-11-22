#!/bin/bash

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD_DIR="$(cd "$TEST_SCRIPT_DIR/../.." && pwd)/.build"
mkdir -p "$TEST_BUILD_DIR"
TEST_ROOT="$(mktemp -d "$TEST_BUILD_DIR/install-target-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

assert_equal() {
    [[ "$1" == "$2" ]] || {
        printf 'Expected <%s>, got <%s>\n' "$1" "$2" >&2
        return 1
    }
}

load_installer() {
    source "$TEST_SCRIPT_DIR/install-from-dmg.sh"
    FIXTURE="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
    SYSTEM_INSTALLED_APP="$FIXTURE/system/Xe Launcher.app"
    USER_INSTALLED_APP="$FIXTURE/personal/Xe Launcher.app"
    INSTALLED_APP="$SYSTEM_INSTALLED_APP"
}

test_system_install() (
    load_installer
    mkdir -p "$SYSTEM_INSTALLED_APP"
    press_ui_button() { touch "$FIXTURE/unexpected-prompt"; return 1; }
    wait_for_installed_bundle 2
    assert_equal "$SYSTEM_INSTALLED_APP" "$INSTALLED_APP"
    [[ ! -e "$FIXTURE/unexpected-prompt" ]]
)

test_personal_install() (
    load_installer
    press_ui_button() {
        assert_equal "$BUNDLE_ID" "$1" || return 1
        assert_equal "Install for This User" "$2" || return 1
        assert_equal "Applications Folder Requires Permission" "$3" || return 1
        mkdir -p "$USER_INSTALLED_APP"
    }
    wait_for_installed_bundle 2
    assert_equal "$USER_INSTALLED_APP" "$INSTALLED_APP"
)

test_development_personal_install() (
    load_installer
    DEV_MODE=true
    press_ui_button() { return 1; }
    press_process_button() {
        assert_equal "bin" "$1" || return 1
        assert_equal "Install for This User" "$2" || return 1
        assert_equal "Applications Folder Requires Permission" "$3" || return 1
        mkdir -p "$USER_INSTALLED_APP"
    }
    wait_for_installed_bundle 2
    assert_equal "$USER_INSTALLED_APP" "$INSTALLED_APP"
)

test_unapproved_personal_copy_is_not_success() (
    load_installer
    mkdir -p "$USER_INSTALLED_APP"
    press_ui_button() { return 1; }
    if (wait_for_installed_bundle 1) >"$FIXTURE/result" 2>&1; then
        printf 'Accepted a personal copy without observing fallback consent\n' >&2
        exit 1
    fi
    assert_equal "$SYSTEM_INSTALLED_APP" "$INSTALLED_APP"
    grep -Fq "installed app was not created at $SYSTEM_INSTALLED_APP" "$FIXTURE/result"
)

test_approved_fallback_still_requires_a_bundle() (
    load_installer
    press_ui_button() { return 0; }
    if (wait_for_installed_bundle 1) >"$FIXTURE/result" 2>&1; then
        printf 'Accepted fallback consent without an installed bundle\n' >&2
        exit 1
    fi
    grep -Fq "installed app was not created at $USER_INSTALLED_APP" "$FIXTURE/result"
)

test_exact_running_installation() (
    load_installer
    INSTALLED_APP="$FIXTURE/system.[1]/Xe Launcher.app"
    /bin/bash -c 'exec -a "$1/Contents/MacOS/bin" /bin/sleep 20' \
        install-target-fixture "$INSTALLED_APP" &
    fixture_pid=$!
    trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT

    for ((attempt = 0; attempt < 40; attempt++)); do
        installed_app_is_running && break
        sleep 0.05
    done
    installed_app_is_running
    INSTALLED_APP="$FIXTURE/system.x1/Xe Launcher.app"
    if installed_app_is_running; then
        printf 'Matched a different installation through regex metacharacters\n' >&2
        exit 1
    fi
    INSTALLED_APP="$USER_INSTALLED_APP"
    if installed_app_is_running; then
        printf 'Matched the system copy while expecting a personal copy\n' >&2
        exit 1
    fi
)

test_cleanup_accepts_only_owned_installations() (
    source "$TEST_SCRIPT_DIR/cleanup.sh"
    # Isolate the allowlist here; symlink refusal is exercised separately.
    refuse_ancestor_symlinks() { :; }
    require_owned_cleanup_path "/Applications/Xe Launcher.app"
    require_owned_cleanup_path "$HOME/Applications/Xe Launcher.app"
    for unrelated_path in \
        "$HOME/Applications/Another.app" \
        "$HOME/../another-user/Applications/Xe Launcher.app" \
        "/Applications"; do
        if (require_owned_cleanup_path "$unrelated_path") >/dev/null 2>&1; then
            printf 'Cleanup accepted an unrelated path: %s\n' "$unrelated_path" >&2
            exit 1
        fi
    done
)

test_cleanup_refuses_symlinked_ancestors() (
    source "$TEST_SCRIPT_DIR/cleanup.sh"
    fixture="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
    mkdir -p "$fixture/destination"
    ln -s "$fixture/destination" "$fixture/link"
    if (refuse_ancestor_symlinks "$fixture/link/Xe Launcher.app") >/dev/null 2>&1; then
        printf 'Cleanup accepted a symlinked parent directory\n' >&2
        exit 1
    fi
)

test_retained_personal_install() (
    load_installer
    EXISTING_INSTALLED_APP="$USER_INSTALLED_APP"
    mkdir -p "$USER_INSTALLED_APP"
    press_ui_button() {
        assert_equal "$BUNDLE_ID" "$1" || return 1
        case "$2" in
            "Install for This User")
                assert_equal "Applications Folder Requires Permission" "$3" || return 1
                touch "$FIXTURE/fallback"
                ;;
            "Open Installed App")
                [[ -e "$FIXTURE/fallback" ]] || return 1
                assert_equal "Xe Launcher Is Already Installed" "$3" || return 1
                touch "$FIXTURE/opened"
                ;;
            *) return 1 ;;
        esac
    }
    wait_for_installed_bundle 2
    assert_equal "$USER_INSTALLED_APP" "$INSTALLED_APP"
    [[ -e "$FIXTURE/opened" ]]
)

test_retained_bundle_requires_open_confirmation() (
    load_installer
    EXISTING_INSTALLED_APP="$SYSTEM_INSTALLED_APP"
    mkdir -p "$SYSTEM_INSTALLED_APP"
    press_ui_button() { return 1; }
    if (wait_for_installed_bundle 1) >"$FIXTURE/result" 2>&1; then
        printf 'Accepted a retained bundle without opening it through the installer\n' >&2
        exit 1
    fi
    grep -Fq 'installer did not offer the retained installation' "$FIXTURE/result"
)

test_retained_installation_boundaries() (
    load_installer
    STANDARD_USER_MODE=true
    mkdir -p "$USER_INSTALLED_APP"
    find_existing_installation
    assert_equal "$USER_INSTALLED_APP" "$EXISTING_INSTALLED_APP"
    EXISTING_INSTALLED_APP=""
    mkdir -p "$SYSTEM_INSTALLED_APP"
    if (find_existing_installation) >/dev/null 2>&1; then
        printf 'Accepted two retained installations\n' >&2
        exit 1
    fi
    rmdir "$SYSTEM_INSTALLED_APP"
    ln -s "$USER_INSTALLED_APP" "$SYSTEM_INSTALLED_APP"
    if (find_existing_installation) >/dev/null 2>&1; then
        printf 'Accepted a symlink as a retained installation\n' >&2
        exit 1
    fi
)

test_signed_refresh_preserves_bundle_and_replaces_contents() (
    load_installer
    EXISTING_INSTALLED_APP="$USER_INSTALLED_APP"
    SOURCE_APP="$FIXTURE/source/Xe Launcher.app"
    mkdir -p "$EXISTING_INSTALLED_APP/Contents" "$SOURCE_APP/Contents"
    printf 'old build\n' > "$EXISTING_INSTALLED_APP/Contents/bin"
    touch "$EXISTING_INSTALLED_APP/Contents/obsolete"
    printf 'new build\n' > "$SOURCE_APP/Contents/bin"
    old_inode="$(stat -f '%i' "$EXISTING_INSTALLED_APP")"
    installed_app_is_running() { return 1; }
    codesign() {
        if [[ "$1" == -d ]]; then
            printf 'designated => identifier "dev.xe.computer" and anchor apple generic\n'
        elif [[ "$3" == -R ]]; then
            assert_equal '=identifier "dev.xe.computer" and anchor apple generic' "$4"
        fi
    }
    refresh_existing_installation
    assert_equal "$old_inode" "$(stat -f '%i' "$EXISTING_INSTALLED_APP")"
    cmp "$SOURCE_APP/Contents/bin" "$EXISTING_INSTALLED_APP/Contents/bin"
    [[ ! -e "$EXISTING_INSTALLED_APP/Contents/obsolete" ]]
)

test_changed_signing_identity_cannot_replace_retained_app() (
    load_installer
    EXISTING_INSTALLED_APP="$USER_INSTALLED_APP"
    SOURCE_APP="$FIXTURE/source/Xe Launcher.app"
    mkdir -p "$EXISTING_INSTALLED_APP"
    touch "$EXISTING_INSTALLED_APP/old-build"
    installed_app_is_running() { return 1; }
    codesign() {
        if [[ "$1" == -d ]]; then
            printf 'designated => identifier "dev.xe.computer" and anchor apple generic\n'
        else
            return 1
        fi
    }
    if (refresh_existing_installation) >"$FIXTURE/result" 2>&1; then
        printf 'Replaced retained installation despite signing identity mismatch\n' >&2
        exit 1
    fi
    [[ -f "$EXISTING_INSTALLED_APP/old-build" ]]
    grep -Fq "does not match the retained app's signing identity" "$FIXTURE/result"
)

test_ci_cleanup_keeps_installation_and_permissions() (
    source "$TEST_SCRIPT_DIR/cleanup.sh"
    GITHUB_ACTIONS=true
    RUNNER_ENVIRONMENT=self-hosted
    RUNNER_OS=macOS
    RUNNER_ARCH=ARM64
    GITHUB_REPOSITORY=Agent54/xe-computer-launcher
    GITHUB_WORKFLOW_REF=Agent54/xe-computer-launcher/.github/workflows/main-release.yml@refs/heads/int
    GITHUB_JOB=release
    GITHUB_EVENT_NAME=push
    GITHUB_REF_NAME=int
    configure_cleanup_mode --ci-permanent
    fixture="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
    INSTALLED_APPS=("$fixture/Xe Launcher.app")
    mkdir -p "${INSTALLED_APPS[0]}"
    tccutil() { touch "$fixture/unexpected-reset"; }
    permanently_remove_owned_path() { touch "$fixture/unexpected-removal"; }
    reset_app_permissions
    remove_installed_apps
    [[ -d "${INSTALLED_APPS[0]}" && ! -e "$fixture/unexpected-reset" && ! -e "$fixture/unexpected-removal" ]]
    # The separate manual fresh-onboarding profile still clears TCC.
    PRESERVE_PERMISSIONS=0
    reset_app_permissions
    [[ -e "$fixture/unexpected-reset" ]]
)

test_persistent_accessibility_never_changes_switches() (
    load_installer
    STANDARD_USER_MODE=true
    APP_DATA="$FIXTURE/data"
    grant_accessibility_permission() { touch "$FIXTURE/unexpected-toggle"; }
    drain_accessibility_permission_prompts() { touch "$FIXTURE/unexpected-toggle"; }
    start_runner_auth_helper() { touch "$FIXTURE/unexpected-toggle"; }
    if (approve_app_accessibility 0) >"$FIXTURE/result" 2>&1; then
        printf 'Accepted missing persistent Accessibility permission\n' >&2
        exit 1
    fi
    grep -Fq 'Approve the signed installed app once' "$FIXTURE/result"
    mkdir -p "$APP_DATA/workerd/ui-https"
    touch "$APP_DATA/workerd/ui-https/root.crt"
    approve_app_accessibility 1
    [[ ! -e "$FIXTURE/unexpected-toggle" ]]
)

test_full_flow_still_requests_accessibility_approval() (
    load_installer
    assert_equal false "$STANDARD_USER_MODE"
    assert_equal 80 "$HTTP_PORT"
    assert_equal 443 "$HTTPS_PORT"
    start_runner_auth_helper() { printf 'start\n' >> "$FIXTURE/approval"; }
    drain_accessibility_permission_prompts() {
        assert_equal "$APP_NAME" "$1"
        printf 'native prompt\n' >> "$FIXTURE/approval"
    }
    grant_accessibility_permission() {
        assert_equal "$APP_NAME" "$1"
        printf 'grant\n' >> "$FIXTURE/approval"
    }
    stop_runner_auth_helper() { printf 'stop\n' >> "$FIXTURE/approval"; }
    approve_app_accessibility
    assert_equal $'start\nnative prompt\ngrant\nstop' "$(cat "$FIXTURE/approval")"
)

test_saved_ports_require_expected_pair_and_confirmation() (
    load_installer
    APP_DATA="$FIXTURE/data"
    mkdir -p "$APP_DATA"
    HTTP_PORT=5196
    HTTPS_PORT=5194
    printf '{"app_http_port":5196,"app_https_port":5194,"app_port_choice_confirmed":true}\n' > "$APP_DATA/settings.json"
    verify_saved_ports
    HTTP_PORT=80
    HTTPS_PORT=443
    if verify_saved_ports; then
        printf 'Accepted saved ports from the wrong test profile\n' >&2
        exit 1
    fi
    printf '{"app_http_port":80,"app_https_port":443,"app_port_choice_confirmed":false}\n' > "$APP_DATA/settings.json"
    if verify_saved_ports; then
        printf 'Accepted unconfirmed ports\n' >&2
        exit 1
    fi
    printf '{"app_http_port":80,"app_https_port":443,"app_port_choice_confirmed":true}\n' > "$APP_DATA/settings.json"
    verify_saved_ports
)

for test_case in \
    test_system_install \
    test_personal_install \
    test_development_personal_install \
    test_unapproved_personal_copy_is_not_success \
    test_approved_fallback_still_requires_a_bundle \
    test_exact_running_installation \
    test_cleanup_accepts_only_owned_installations \
    test_cleanup_refuses_symlinked_ancestors \
    test_retained_personal_install \
    test_retained_bundle_requires_open_confirmation \
    test_retained_installation_boundaries \
    test_signed_refresh_preserves_bundle_and_replaces_contents \
    test_changed_signing_identity_cannot_replace_retained_app \
    test_ci_cleanup_keeps_installation_and_permissions \
    test_persistent_accessibility_never_changes_switches \
    test_full_flow_still_requests_accessibility_approval \
    test_saved_ports_require_expected_pair_and_confirmation; do
    "$test_case"
    printf 'PASS: %s\n' "$test_case"
done
