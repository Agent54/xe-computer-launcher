#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Exercise the actual workflow calculation, before its outputs or plist writes.
calculation="$(awk '
    /- name: Calculate next release version/ { step = 1; next }
    step && /run: \|/ { script = 1; next }
    script && /echo "version=/ { exit }
    script { sub(/^          /, ""); print }
' "$REPO_ROOT/.github/workflows/main-release.yml")"
[[ -n "$calculation" ]]

git() {
    if [[ "$*" == 'tag --sort=-version:refname' ]]; then
        printf '%s\n' "$fixture_tags"
    elif [[ "$1 $2" == 'tag --list' ]]; then
        while IFS= read -r tag; do
            [[ "$tag" != $3 ]] || printf '%s\n' "$tag"
        done <<< "$fixture_tags"
    else
        printf 'Unexpected git arguments: %s\n' "$*" >&2
        exit 1
    fi
}
# The calculation reads only the base version; never touch the source plist.
plutil() { printf '%s\n' "$fixture_version"; }

check_version() (
    local label="$1" expected_tag="$2" expected_channel="$3"
    eval "$calculation"
    [[ "$release_tag" == "$expected_tag" ]] || {
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected_tag" "$release_tag" >&2
        exit 1
    }
    [[ "$update_channel" == "$expected_channel" ]]
    [[ "$version" == "${expected_tag%%-int.*}" ]]
    if [[ "$expected_channel" == int ]]; then
        [[ "$prerelease" == true ]]
    else
        [[ "$prerelease" == false ]]
    fi
    printf 'PASS: %s (%s)\n' "$label" "$release_tag"
)

GITHUB_REF_NAME=int
GITHUB_RUN_NUMBER=999
GITHUB_RUN_ATTEMPT=1
fixture_version=0.4.1
fixture_tags=$'0.4.0-int.202.1\n0.0.8-int.201.2\n0.0.7'
check_version 'patch bump resets both suffix components' 0.4.1-int.0.0 int

fixture_tags=$'0.4.1-int.0.0\n0.4.0-int.202.1\n0.0.7'
check_version 'next integration release increments within the base version' 0.4.1-int.1.0 int

fixture_tags=$'0.4.10-int.99.0\n0.4.1-int.9.2\n0.4.1-int.2.0\n0.4.1-int.10.0\n0.4.1-int.invalid\n0.4.0-int.202.1\n0.0.7'
check_version 'only matching base tags advance the numeric counter' 0.4.1-int.11.0 int

fixture_version=0.5.0
check_version 'minor bump resets the counter' 0.5.0-int.0.0 int

fixture_version=1.0.0
check_version 'major bump resets the counter' 1.0.0-int.0.0 int

fixture_version=0.4.1
fixture_tags=$'0.4.0-int.202.1\n0.0.7'
GITHUB_RUN_ATTEMPT=2
check_version 'failed build retry has a zero-based attempt' 0.4.1-int.0.1 int

GITHUB_RUN_ATTEMPT=1
fixture_tags=''
check_version 'first integration release starts at zero' 0.4.1-int.0.0 int

fixture_version=0.4.0
fixture_tags=$'0.4.1\n0.4.0'
check_version 'automatic patch increment starts a fresh counter' 0.4.2-int.0.0 int

GITHUB_REF_NAME=main
check_version 'stable release increments past existing stable tags' 0.4.2 stable
fixture_version=0.5.0
check_version 'stable release respects the configured minimum' 0.5.0 stable
