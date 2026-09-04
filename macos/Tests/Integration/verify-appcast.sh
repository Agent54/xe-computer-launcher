#!/usr/bin/env bash

set -euo pipefail

source_path="${1:-}"
expected_build="${2:-}"
expected_asset_url="${3:-}"
expected_display_version="${4:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -n "$source_path" ]] \
    || fail "usage: verify-appcast.sh <path-or-https-url> <build-version> <asset-url> [display-version]"
[[ -n "$expected_build" ]] || fail "expected build version is required"
[[ "$expected_asset_url" == https://* ]] || fail "expected HTTPS asset URL is required"

temporary_appcast=""
if [[ "$source_path" == https://* ]]; then
    temporary_appcast="$(mktemp "${TMPDIR:-/tmp}/xe-launcher-appcast.XXXXXX")"
    trap 'rm -f "$temporary_appcast"' EXIT
    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --output "$temporary_appcast" \
        "$source_path"
    appcast="$temporary_appcast"
else
    appcast="$source_path"
fi

[[ -s "$appcast" ]] || fail "appcast is empty: $source_path"
xmllint --noout "$appcast"

xpath_value() {
    xmllint --xpath "string($1)" "$appcast"
}

item='/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]'
actual_build="$(xpath_value "$item/*[local-name()='version']")"
actual_display_version="$(xpath_value "$item/*[local-name()='shortVersionString']")"
actual_asset_url="$(xpath_value "$item/*[local-name()='enclosure']/@url")"
archive_signature="$(xpath_value "$item/*[local-name()='enclosure']/@*[local-name()='edSignature']")"

[[ "$actual_build" == "$expected_build" ]] \
    || fail "expected appcast build $expected_build, found $actual_build"
[[ "$actual_asset_url" == "$expected_asset_url" ]] \
    || fail "expected enclosure $expected_asset_url, found $actual_asset_url"
if [[ -n "$expected_display_version" && "$actual_display_version" != "$expected_display_version" ]]; then
    fail "expected appcast display version $expected_display_version, found $actual_display_version"
fi
[[ -n "$archive_signature" ]] || fail "update archive has no EdDSA signature"
grep -q '<!-- sparkle-signatures:' "$appcast" || fail "appcast feed has no signature block"

echo "Sparkle appcast verification passed: $source_path"
