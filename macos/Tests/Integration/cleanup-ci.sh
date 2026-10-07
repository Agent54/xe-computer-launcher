#!/bin/bash

set -euo pipefail

# Run destructive cleanup only at CI start. Preserve each finished run for
# manual debugging until the next job starts, removing only allowlisted Xe paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${GITHUB_WORKSPACE:-}"

fail() {
    printf '[installer-cleanup] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "${GITHUB_ACTIONS:-}" == "true" ]] \
    || fail "cleanup-ci.sh may only run in GitHub Actions"
[[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]] \
    || fail "cleanup-ci.sh requires a self-hosted runner"
[[ "${RUNNER_OS:-}" == "macOS" && "${RUNNER_ARCH:-}" == "ARM64" ]] \
    || fail "cleanup-ci.sh requires the macOS ARM64 runner"
[[ "${GITHUB_REPOSITORY:-}" == "Agent54/xe-computer-launcher" ]] \
    || fail "cleanup-ci.sh requires the launcher repository"
if [[ "${GITHUB_WORKFLOW_REF:-}" == "Agent54/xe-computer-launcher/.github/workflows/main-release.yml@"* ]]; then
    [[ "${GITHUB_JOB:-}" == "release" && "${GITHUB_EVENT_NAME:-}" == "push" ]] \
        || fail "cleanup-ci.sh requires the release job triggered by a push"
    [[ "${GITHUB_REF_NAME:-}" == "int" || "${GITHUB_REF_NAME:-}" == "main" ]] \
        || fail "cleanup-ci.sh requires the int or main release branch"
elif [[ "${GITHUB_WORKFLOW_REF:-}" == "Agent54/xe-computer-launcher/.github/workflows/pr-build.yml@"* ]]; then
    [[ "${GITHUB_JOB:-}" == "launcher-integration" && "${GITHUB_EVENT_NAME:-}" == "pull_request" \
        && "${GITHUB_BASE_REF:-}" == "main" ]] \
        || fail "cleanup-ci.sh requires the integration job for a main-branch pull request"
else
    fail "cleanup-ci.sh requires the launcher release or integration workflow"
fi
[[ -n "$WORKSPACE" && "$SCRIPT_DIR" == "${WORKSPACE%/}/macos/Tests/Integration" ]] \
    || fail "cleanup-ci.sh must run from the checked-out launcher workspace"

# A surviving launcher or add-trusted-cert process can still own an approval
# dialog or recreate its trust setting while removal is running. Stop it first,
# preserving the certificates and app data until removal has been verified.
bash "${SCRIPT_DIR}/cleanup.sh" --stop-only

root_certificate="$HOME/Library/Application Support/dev.xe.computer/workerd/ui-https/root.crt"
leaf_certificate="$HOME/Library/Application Support/dev.xe.computer/workerd/ui-https/ui.crt"
auth_pid=""
stop_auth_helper() {
    [[ -n "$auth_pid" ]] || return 0
    kill "$auth_pid" 2>/dev/null || true
    wait "$auth_pid" 2>/dev/null || true
    auth_pid=""
}
trap stop_auth_helper EXIT

# The CI account persists between jobs. Remove trust for the previous run's
# unique CA before cleanup deletes the only copy of its certificate.
# Evaluate the leaf alone so macOS must discover a trusted root in its stores.
# Supplying root.crt in the chain can accept it even without Keychain trust.
if [[ -f "$root_certificate" && -f "$leaf_certificate" ]] \
    && security verify-cert -q -L -p ssl -n compose-ui.localhost \
        -c "$leaf_certificate" >/dev/null 2>&1; then
    printf '[installer-cleanup] removing previous local HTTPS certificate trust\n'
    if [[ -n "${XE_CI_MAC_PASSWORD:-}" ]]; then
        XE_CI_AUTH_KIND=certificate \
            XE_CI_CERT_PATH="$root_certificate" \
            osascript -l JavaScript "$SCRIPT_DIR/authorize-macos-dialog.jxa" 2>/dev/null &
        auth_pid=$!
    fi
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' 90 \
        security remove-trusted-cert "$root_certificate" \
        || fail "could not remove the previous local HTTPS certificate trust"
    stop_auth_helper
    # Security.framework can briefly retain the prior evaluation after a trust
    # change. Wait for it to become visible, then fail if trust remains.
    trust_removal_deadline=$((SECONDS + 10))
    while security verify-cert -q -L -p ssl -n compose-ui.localhost \
        -c "$leaf_certificate" >/dev/null 2>&1; do
        (( SECONDS < trust_removal_deadline )) \
            || fail "the previous local HTTPS certificate is still trusted"
        sleep 0.25
    done
fi
unset XE_CI_MAC_PASSWORD

bash "${SCRIPT_DIR}/cleanup.sh" --ci-permanent

# System Settings restores its last pane across launches. A previous CI run
# may leave Login Items or Accessibility open, so start each installer test
# with a fresh Settings window and let the native permission action navigate.
printf '[installer-cleanup] closing System Settings before the next test\n'
pkill -x "System Settings" 2>/dev/null || true
for _ in {1..20}; do
    pgrep -x "System Settings" >/dev/null 2>&1 || exit 0
    sleep 0.25
done
fail "System Settings did not close before the next test"
