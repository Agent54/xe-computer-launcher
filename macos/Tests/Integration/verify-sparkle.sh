#!/usr/bin/env bash

set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

app_path="${1:-macos/dist/Xe Launcher.app}"
shift $(( $# > 0 ? 1 : 0 ))
require_configured=false
expected_channel=""

while (( $# > 0 )); do
    case "$1" in
        --release)
            require_configured=true
            ;;
        --channel)
            shift
            (( $# > 0 )) || fail "--channel requires stable or int"
            expected_channel="$1"
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
    shift
done

[[ -d "$app_path" ]] || fail "app bundle does not exist: $app_path"

info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/bin"
framework="$app_path/Contents/Frameworks/Sparkle.framework"

[[ -f "$info_plist" ]] || fail "Info.plist is missing"
[[ -x "$executable" ]] || fail "app executable is missing"
[[ -d "$framework" ]] || fail "Sparkle.framework is missing"

for relative_path in \
    "Versions/B/Sparkle" \
    "Versions/B/Autoupdate" \
    "Versions/B/Updater.app/Contents/MacOS/Updater" \
    "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
    [[ -e "$framework/$relative_path" ]] \
        || fail "Sparkle component is missing: $relative_path"
done

otool -L "$executable" \
    | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || fail "app executable is not linked to Sparkle.framework"

otool -l "$executable" \
    | grep -q '@executable_path/../Frameworks' \
    || fail "app executable has no Contents/Frameworks runtime search path"

feed_url="$(plutil -extract SUFeedURL raw "$info_plist")"
update_channel="$(plutil -extract XeUpdateChannel raw "$info_plist")"
public_key="$(plutil -extract SUPublicEDKey raw "$info_plist")"
automatic_checks="$(plutil -extract SUEnableAutomaticChecks raw "$info_plist")"
allows_automatic_updates="$(plutil -extract SUAllowsAutomaticUpdates raw "$info_plist")"
automatic_install="$(plutil -extract SUAutomaticallyUpdate raw "$info_plist")"
verify_before_extraction="$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$info_plist")"
require_signed_feed="$(plutil -extract SURequireSignedFeed raw "$info_plist")"

[[ "$feed_url" == https://* ]] || fail "SUFeedURL must use HTTPS"
[[ "$update_channel" == "stable" || "$update_channel" == "int" ]] \
    || fail "XeUpdateChannel must be stable or int"
expected_feed_url="https://raw.githubusercontent.com/Agent54/xe-computer-launcher/updates/$update_channel/appcast.xml"
[[ "$feed_url" == "$expected_feed_url" ]] \
    || fail "SUFeedURL does not match XeUpdateChannel $update_channel: $feed_url"
if [[ -n "$expected_channel" && "$update_channel" != "$expected_channel" ]]; then
    fail "expected update channel $expected_channel, found $update_channel"
fi
[[ "$automatic_checks" == "true" ]] \
    || fail "automatic update checks must be enabled without a permission prompt"
[[ "$allows_automatic_updates" == "false" ]] \
    || fail "users must not be offered automatic update installation"
[[ "$automatic_install" == "false" ]] \
    || fail "silent automatic installation must be disabled"
[[ "$verify_before_extraction" == "true" ]] \
    || fail "updates are not verified before extraction"
[[ "$require_signed_feed" == "true" ]] || fail "signed appcast feeds are not required"

if $require_configured; then
    [[ -n "$public_key" && "$public_key" != "SPARKLE_PUBLIC_ED_KEY" ]] \
        || fail "release bundle contains the placeholder Sparkle public key"
    [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
        || fail "release bundle contains a malformed Sparkle public key"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Sparkle bundle verification passed: $app_path"
