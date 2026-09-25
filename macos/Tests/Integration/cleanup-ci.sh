#!/bin/bash

set -euo pipefail

# CI runners are disposable. Never use cleanup.sh's recoverable Trash behavior
# here: permanently remove only the exact allowlisted Xe paths.
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
