#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ContainerTools.lock
stage="$PWD/.build/container-tools"
downloads="$stage/downloads"
mkdir -p "$downloads" "$stage/tools" "$stage/host" "$stage/guest/cli-plugins"

verify() {
    local actual
    actual="$(shasum -a 256 "$1" | awk '{print $1}')"
    [[ "$actual" == "$2" ]] || { echo "Checksum mismatch: $1" >&2; exit 1; }
}
fetch() {
    local name="$1" url="$2" checksum="$3"
    if [[ ! -f "$downloads/$name" ]]; then
        curl --fail --location --retry 3 "$url" --output "$downloads/$name.download"
        verify "$downloads/$name.download" "$checksum"
        mv "$downloads/$name.download" "$downloads/$name"
    fi
    verify "$downloads/$name" "$checksum"
}
fetch "docker-$DOCKER_VERSION.tgz" \
    "https://download.docker.com/linux/static/stable/aarch64/docker-$DOCKER_VERSION.tgz" "$DOCKER_LINUX_ARM64_SHA256"
fetch "buildx-v$BUILDX_VERSION.darwin-arm64" \
    "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.darwin-arm64" "$BUILDX_DARWIN_ARM64_SHA256"
fetch "buildx-v$BUILDX_VERSION.linux-arm64" \
    "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.linux-arm64" "$BUILDX_LINUX_ARM64_SHA256"
if [[ ! -f "$downloads/buildkit-v$BUILDKIT_VERSION.tar" ]]; then
    fetch go-containerregistry_Darwin_arm64.tar.gz \
        "https://github.com/google/go-containerregistry/releases/download/v$CRANE_VERSION/go-containerregistry_Darwin_arm64.tar.gz" "$CRANE_DARWIN_ARM64_SHA256"
    tar -xzf "$downloads/go-containerregistry_Darwin_arm64.tar.gz" -C "$stage/tools" crane
    "$stage/tools/crane" pull --platform linux/arm64 --format legacy "$BUILDKIT_IMAGE" "$downloads/buildkit-v$BUILDKIT_VERSION.tar.download"
    verify "$downloads/buildkit-v$BUILDKIT_VERSION.tar.download" "$BUILDKIT_ARCHIVE_SHA256"
    mv "$downloads/buildkit-v$BUILDKIT_VERSION.tar.download" "$downloads/buildkit-v$BUILDKIT_VERSION.tar"
fi
verify "$downloads/buildkit-v$BUILDKIT_VERSION.tar" "$BUILDKIT_ARCHIVE_SHA256"
tar -xzf "$downloads/docker-$DOCKER_VERSION.tgz" -C "$stage/guest"
cp "$downloads/buildx-v$BUILDX_VERSION.darwin-arm64" "$stage/host/docker-buildx"
cp "$downloads/buildx-v$BUILDX_VERSION.linux-arm64" "$stage/guest/cli-plugins/docker-buildx"
cp "$downloads/buildkit-v$BUILDKIT_VERSION.tar" "$stage/guest/buildkit.tar"
cp ContainerTools.lock "$stage/guest/ContainerTools.lock"
cp ContainerTools/start-builder.sh ContainerTools/buildkitd.toml "$stage/guest/"
chmod 755 "$stage/host/docker-buildx" "$stage/guest/cli-plugins/docker-buildx" "$stage/guest/docker/"*
file "$stage/host/docker-buildx" | grep -q 'Mach-O 64-bit executable arm64'
"$stage/host/docker-buildx" version | grep -F "v$BUILDX_VERSION"
cd "$stage/guest"
shasum -a 256 docker/* cli-plugins/* buildkit.tar ContainerTools.lock start-builder.sh buildkitd.toml > checksums.txt
echo "Staged Docker $DOCKER_VERSION, Buildx $BUILDX_VERSION, BuildKit $BUILDKIT_VERSION"
