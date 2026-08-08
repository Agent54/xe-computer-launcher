#!/usr/bin/env bash

set -euo pipefail

app_path="${1:-macos/dist/XE Launcher.app}"
require_configured=false
if [[ "${2:-}" == "--release" ]]; then
    require_configured=true
fi

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

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
public_key="$(plutil -extract SUPublicEDKey raw "$info_plist")"
automatic_install="$(plutil -extract SUAutomaticallyUpdate raw "$info_plist")"
verify_before_extraction="$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$info_plist")"
require_signed_feed="$(plutil -extract SURequireSignedFeed raw "$info_plist")"

[[ "$feed_url" == https://* ]] || fail "SUFeedURL must use HTTPS"
[[ "$automatic_install" == "false" ]] || fail "silent automatic installation must default to off"
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
