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
[[ "${GITHUB_WORKFLOW_REF:-}" == "Agent54/xe-computer-launcher/.github/workflows/main-release.yml@"* ]] \
    || fail "cleanup-ci.sh requires the release workflow"
[[ "${GITHUB_JOB:-}" == "release" && "${GITHUB_EVENT_NAME:-}" == "push" ]] \
    || fail "cleanup-ci.sh requires the release job triggered by a push"
[[ "${GITHUB_REF_NAME:-}" == "int" || "${GITHUB_REF_NAME:-}" == "main" ]] \
    || fail "cleanup-ci.sh requires the int or main release branch"
[[ -n "$WORKSPACE" && "$SCRIPT_DIR" == "${WORKSPACE%/}/macos/Tests/Integration" ]] \
    || fail "cleanup-ci.sh must run from the checked-out launcher workspace"

exec bash "${SCRIPT_DIR}/cleanup.sh" --ci-permanent
