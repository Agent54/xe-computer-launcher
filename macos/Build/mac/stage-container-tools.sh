#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ContainerTools.lock
stage="$PWD/.build/container-tools"
downloads="$stage/downloads"
mkdir -p "$downloads" "$stage/Helpers" "$stage/Resources/ContainerTools/cli-plugins"

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
fetch "buildx-v$BUILDX_VERSION.darwin-arm64" \
    "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.darwin-arm64" "$BUILDX_DARWIN_ARM64_SHA256"
cp "$downloads/buildx-v$BUILDX_VERSION.darwin-arm64" "$stage/Helpers/buildx"
cp Scripts/docker-buildx.sh "$stage/Resources/ContainerTools/cli-plugins/docker-buildx"
cp ContainerTools.lock ContainerTools/buildkitd.toml "$stage/Resources/ContainerTools/"
chmod 755 "$stage/Helpers/buildx" "$stage/Resources/ContainerTools/cli-plugins/docker-buildx"
file "$stage/Helpers/buildx" | grep -q 'Mach-O 64-bit executable arm64'
"$stage/Resources/ContainerTools/cli-plugins/docker-buildx" version | grep -F "v$BUILDX_VERSION"
echo "Staged host Buildx $BUILDX_VERSION; Docker and BuildKit are supplied by the SmolVM image"
