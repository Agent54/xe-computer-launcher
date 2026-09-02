#!/usr/bin/env bash

set -euo pipefail

source_runtime="${1:?usage: install-smol-runtime.sh SOURCE HELPERS_DESTINATION RESOURCES_DESTINATION}"
helpers_destination="${2:?usage: install-smol-runtime.sh SOURCE HELPERS_DESTINATION RESOURCES_DESTINATION}"
resources_destination="${3:?usage: install-smol-runtime.sh SOURCE HELPERS_DESTINATION RESOURCES_DESTINATION}"

helpers_suffix="/Contents/Helpers/SmolRuntime"
resources_suffix="/Contents/Resources/SmolRuntime"
helpers_app="${helpers_destination%"$helpers_suffix"}"
resources_app="${resources_destination%"$resources_suffix"}"
if [[ "$helpers_destination" != *"$helpers_suffix" ]] \
    || [[ "$resources_destination" != *"$resources_suffix" ]] \
    || [[ "$helpers_app" != "$resources_app" ]] \
    || [[ "$helpers_app" != *.app ]]; then
    echo "refusing to install SmolVM into unexpected destinations" >&2
    exit 1
fi

# macOS treats executable files below Contents/Helpers as nested host code.
# Keep only signed Darwin host code there. Everything else belongs in Resources:
# code signing treats every ordinary file below Contents/Helpers as nested code,
# while the Linux guest rootfs and packed VM images are intentionally opaque data.
mkdir -p "$helpers_destination" "$resources_destination"
rsync -a --delete --delete-excluded \
    --include '/smolvm-bin' \
    --include '/lib/' \
    --include '/lib/***' \
    --exclude '*' \
    "$source_runtime/" "$helpers_destination/"
rsync -a \
    --delete \
    --delete-excluded \
    --exclude smolvm-bin \
    --exclude lib \
    --exclude agent-rootfs \
    "$source_runtime/" "$resources_destination/"
COPYFILE_DISABLE=1 /usr/bin/tar -cf "$resources_destination/agent-rootfs.tar" \
    -C "$source_runtime" agent-rootfs

echo "Installed SmolVM host code and guest resources into the app bundle"
