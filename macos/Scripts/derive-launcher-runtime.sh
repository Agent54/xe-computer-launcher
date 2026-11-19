#!/bin/bash
# Derive the app image from SmolVM's generic Compose artifact, entirely offline.
set -euo pipefail
macos_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
runtime="$(cd "${1:?usage: derive-launcher-runtime.sh STAGED_RUNTIME ROUTER}" && pwd -P)"
router="$(cd "${2:?Missing staged router}" && pwd -P)"
recipe="$macos_dir/VM"
base="$runtime/docker-compose.smolmachine"
deno run --no-config --allow-read "$macos_dir/Scripts/verify-runtime-metadata.ts" "$base" "$runtime/Builder.lock" "$macos_dir/ContainerTools.lock"
(cd "$router" && shasum -a 256 --check checksums.txt)
revision="$(
    {
        cat "$runtime/Builder.lock" "$router/checksums.txt"
        cd "$macos_dir"
        shasum -a 256 VM/*.sh VM/launcher.smolfile VM/daemon.json
    } | shasum -a 256 | awk '{print $1}'
)"
key="$(printf '%s\n' "$revision" "$(shasum -a 256 "$0" | awk '{print $1}')" | shasum -a 256 | awk '{print $1}')"
state="$macos_dir/.build/launcher-vm/$key"
artifact="$state/launcher.smolmachine"
metadata="$artifact.builder.lock"
mkdir -p "$state"
if [[ ! -f "$artifact" || ! -f "$metadata" ]]; then
    # Only a short alias lives in /tmp; VM disks, caches and logs stay in .build.
    short_parent="$(mktemp -d /tmp/xe-image.XXXXXX)"
    ln -s "$state" "$short_parent/s"
    export HOME="$state/home" SMOLVM_DATA_DIR="$short_parent/s/data"
    export SMOLVM_LIB_DIR="$runtime/lib" DYLD_LIBRARY_PATH="$runtime/lib" LIBKRUN_BUNDLE="$runtime/lib"
    export SMOLVM_AGENT_ROOTFS="$runtime/agent-rootfs"
    mkdir -p "$HOME/.smolvm"
    cp "$runtime/storage-template.ext4.zst" "$runtime/overlay-template.ext4.zst" "$HOME/.smolvm/"
    smolvm="$runtime/smolvm-bin"
    machine="launcher-image-$$"
    created=0
    cleanup() {
        if [[ "$created" = 1 ]]; then "$smolvm" machine stop --name "$machine"; fi
        unlink "$short_parent/s"
        rmdir "$short_parent"
    }
    trap cleanup EXIT
    "$smolvm" machine create --name "$machine" --from "$base" \
        --volume "$recipe:/opt/image-recipe:ro" --volume "$router:/opt/image-router:ro" \
        -- /bin/sh -c 'sleep 2147483647'
    created=1
    "$smolvm" machine start --name "$machine"
    "$smolvm" machine exec --name "$machine" --timeout 180s -- /bin/sh /opt/image-recipe/install.sh
    "$smolvm" machine stop --name "$machine"
    created=0
    "$smolvm" pack create --from-vm "$machine" --smolfile "$recipe/launcher.smolfile" \
        --output "$state/launcher" --staging-dir "$state/pack"
    {
        sed '/^SMOLVM_COMPOSE_SHA256=/d' "$runtime/Builder.lock"
        printf 'SMOLVM_COMPOSE_SHA256=%s\n' "$(shasum -a 256 "$artifact" | awk '{print $1}')"
        printf 'XE_RUNTIME_FORMAT=xe-launcher-1\nXE_RUNTIME_INPUT_SHA256=%s\n' "$revision"
    } > "$metadata"
    "$smolvm" machine delete --name "$machine" --force
fi
deno run --no-config --allow-read "$macos_dir/Scripts/verify-runtime-metadata.ts" "$artifact" "$metadata" "$macos_dir/ContainerTools.lock" xe-launcher-1
cp "$artifact" "$runtime/docker-compose.smolmachine"
cp "$metadata" "$runtime/Builder.lock"
echo "Staged launcher VM image $key (router and fixed Docker configuration embedded)"
