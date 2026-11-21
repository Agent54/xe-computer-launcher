#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$(mktemp -d "$PWD/.build/sparkle-resume-test.XXXXXX")
bundle_id="dev.xe.sparkle-test.$(uuidgen)"
trap 'rm -rf -- "$root" "$HOME/Library/Caches/$bundle_id"' EXIT
contents="$root/Resume.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks"
framework="${1:?Pass the path to the staged Sparkle framework}"
cp -R "$framework" "$contents/Frameworks/Sparkle.framework"
cp "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string Resume "$contents/Info.plist"
/usr/bin/plutil -replace CFBundlePackageType -string APPL "$contents/Info.plist"
/usr/bin/plutil -remove XPCService "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string 1 "$contents/Info.plist"
/usr/bin/plutil -insert SUEnableAutomaticChecks -bool false "$contents/Info.plist"
/usr/bin/plutil -insert SUEnableDownloaderService -bool true "$contents/Info.plist"
/usr/bin/plutil -insert SUPublicEDKey -string 'eRFPLZuNM6m8bltmtpPX4fzKbufI1z6rKJHtgIIsllk=' "$contents/Info.plist"
/usr/bin/xcrun clang -fobjc-arc -I.build/checkouts/Sparkle/Downloader -framework Foundation \
    -F"$contents/Frameworks" -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks \
    Tests/Fixtures/SparkleResume/main.m -o "$contents/MacOS/Resume"
/usr/bin/codesign --force --deep --sign - "$root/Resume.app"
cache="$HOME/Library/Caches/$bundle_id/org.sparkle-project.Sparkle/ResumableDownloads"
deno run --no-config --no-lock --allow-net=127.0.0.1 --allow-run="$contents/MacOS/Resume" \
    --allow-read="$root,$cache" --allow-write="$cache" Tests/Integration/test-sparkle-resume.ts \
    "$contents/MacOS/Resume" "$bundle_id" "$root/archive" "$cache"
