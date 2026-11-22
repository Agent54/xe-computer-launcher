#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
source_dir=.build/checkouts/Sparkle
stage=.build/sparkle-downloader
mkdir -p "$stage/src/Downloader"

# Build the Downloader XPC target's sources from the same SwiftPM checkout as
# the framework. The launcher can also be packaged with Command Line Tools.
cp -f "$source_dir/Downloader/"{main,SPUDownloader}.m "$stage/src/Downloader/"
chmod u+w "$stage/src/Downloader/"{main,SPUDownloader}.m
/usr/bin/patch --quiet -l -F 0 -p0 -d "$stage/src" < Build/mac/sparkle-resume.patch
/usr/bin/xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=26.0 \
    -DBUILDING_SPARKLE_SOURCES_EXTERNALLY=1 \
    '-DSPARKLE_BUNDLE_IDENTIFIER="org.sparkle-project.Sparkle"' \
    '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))' \
    '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))' \
    -ISources/ResumableDownloads/include -I"$source_dir/Downloader" -I"$source_dir/Autoupdate" -I"$source_dir/Sparkle" \
    Sources/ResumableDownloads/XEArchiveTransfer.m \
    "$stage/src/Downloader/"{main,SPUDownloader}.m \
    "$source_dir/Autoupdate/SUCodeSigningVerifier.m" \
    "$source_dir/Sparkle/"{SPUDownloadData,SPULocalCacheDirectory,SUConstants,SULog}.m \
    -framework Foundation -framework Security -o "$stage/Downloader"
