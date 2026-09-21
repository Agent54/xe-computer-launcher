#!/usr/bin/env bash

set -euo pipefail

source_path="${1:-}"
expected_build="${2:-}"
expected_asset_url="${3:-}"
expected_display_version="${4:-}"
expected_delta_count="${5:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -n "$source_path" ]] \
    || fail "usage: verify-appcast.sh <path-or-https-url> <build-version> <asset-url> [display-version] [delta-count]"
[[ -n "$expected_build" ]] || fail "expected build version is required"
[[ "$expected_asset_url" == https://* ]] || fail "expected HTTPS asset URL is required"
if [[ -n "$expected_delta_count" && ! "$expected_delta_count" =~ ^[0-9]+$ ]]; then
    fail "expected delta count must be a non-negative integer"
fi

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
delta_items="$item/*[local-name()='deltas']/*[local-name()='enclosure']"
actual_delta_count="$(xpath_value "count($delta_items)")"

[[ "$actual_build" == "$expected_build" ]] \
    || fail "expected appcast build $expected_build, found $actual_build"
[[ "$actual_asset_url" == "$expected_asset_url" ]] \
    || fail "expected enclosure $expected_asset_url, found $actual_asset_url"
if [[ -n "$expected_display_version" && "$actual_display_version" != "$expected_display_version" ]]; then
    fail "expected appcast display version $expected_display_version, found $actual_display_version"
fi
[[ -n "$archive_signature" ]] || fail "update archive has no EdDSA signature"
grep -q '<!-- sparkle-signatures:' "$appcast" || fail "appcast feed has no signature block"

if [[ -n "$expected_delta_count" && "$actual_delta_count" -ne "$expected_delta_count" ]]; then
    fail "expected $expected_delta_count delta updates, found $actual_delta_count"
fi

expected_release_prefix="${expected_asset_url%/*}/"
seen_delta_versions=$'\n'
for ((index = 1; index <= actual_delta_count; index++)); do
    delta="$delta_items[$index]"
    delta_url="$(xpath_value "$delta/@url")"
    delta_from="$(xpath_value "$delta/@*[local-name()='deltaFrom']")"
    delta_length="$(xpath_value "$delta/@length")"
    delta_signature="$(xpath_value "$delta/@*[local-name()='edSignature']")"

    [[ "$delta_url" == "$expected_release_prefix"*.delta ]] \
        || fail "delta $index is not hosted beside the full update: $delta_url"
    [[ -n "$delta_from" ]] || fail "delta $index has no source build"
    [[ "$delta_length" =~ ^[1-9][0-9]*$ ]] || fail "delta $index has invalid length: $delta_length"
    [[ -n "$delta_signature" ]] || fail "delta $index has no EdDSA signature"
    [[ "$seen_delta_versions" != *$'\n'"$delta_from"$'\n'* ]] \
        || fail "multiple deltas use source build $delta_from"
    seen_delta_versions+="$delta_from"$'\n'
done

echo "Sparkle appcast verification passed: $source_path ($actual_delta_count delta update(s))"
