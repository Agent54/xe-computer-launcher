#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
mkdir -p "$repo_root/macos/.build"
fixture_root="$(mktemp -d "$repo_root/macos/.build/darc-pin-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export XE_LAUNCHER_ROOT="$fixture_root"
export TMPDIR="$fixture_root"
export GITHUB_OUTPUT="$fixture_root/output"
manifest="$fixture_root/macos/Sources/macos/Resources/sources.json"
mkdir -p "$(dirname "$manifest")"
printf '%s\n' '{"darc":{"version":{"major":0,"minor":0,"patch":1},"sha256":"old"}}' > "$manifest"

# Exercise the real updater using only published release metadata.
export UNEXPECTED_CALLS="$fixture_root/unexpected-calls"
gh() {
    if [[ "$1 $2" == 'api repos/Agent54/xe-darc/releases?per_page=100' ]]; then
        printf '%s\n' '[{"id":2,"tag_name":"v0.0.2","draft":false,"prerelease":true,"published_at":"2026-11-22T00:00:00Z"},{"id":1,"tag_name":"v0.0.1","published_at":"2026-11-21T00:00:00Z"}]'
    elif [[ "$1 $2" == 'api --paginate' ]]; then
        jq -cn --arg digest "$PUBLISHED_DIGEST" '
            [[{name:"darc.swbn"} + (if $digest == "missing" then {} else {digest:$digest} end)]]
        '
    else
        echo "Unexpected gh call: $*" | tee -a "$UNEXPECTED_CALLS" >&2
        return 1
    fi
}
export -f gh

shasum() {
    echo 'Pin update must not hash the Darc bundle' | tee -a "$UNEXPECTED_CALLS" >&2
    return 1
}
export -f shasum

export PUBLISHED_DIGEST
for PUBLISHED_DIGEST in missing '' sha256:abc "sha512:$(printf '%064d' 0)"; do
    if bash "$repo_root/macos/Build/mac/update-component-lock.sh" xe-computer v0.0.2; then
        echo 'Pin update unexpectedly accepted a missing or invalid published digest' >&2
        exit 1
    fi
    jq -e '.darc.version.patch == 1 and .darc.sha256 == "old"' "$manifest" >/dev/null
done

expected=fd7e794644b99668b0e3bd4b092fa84ce837e083c565dacce4e52de6ef991327
PUBLISHED_DIGEST="sha256:$expected"
bash "$repo_root/macos/Build/mac/update-component-lock.sh" xe-computer v0.0.2
jq -e --arg checksum "$expected" '.darc.version == {major:0,minor:0,patch:2} and .darc.sha256 == $checksum' "$manifest" >/dev/null
[[ ! -e "$UNEXPECTED_CALLS" ]]
echo 'PASS: Darc pin uses the published digest without downloading or hashing; invalid metadata leaves the pin unchanged'
