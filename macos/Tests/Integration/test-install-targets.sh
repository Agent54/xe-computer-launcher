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

for test_case in \
    test_system_install \
    test_personal_install \
    test_development_personal_install \
    test_unapproved_personal_copy_is_not_success \
    test_approved_fallback_still_requires_a_bundle \
    test_exact_running_installation \
    test_cleanup_accepts_only_owned_installations \
    test_cleanup_refuses_symlinked_ancestors; do
    "$test_case"
    printf 'PASS: %s\n' "$test_case"
done
