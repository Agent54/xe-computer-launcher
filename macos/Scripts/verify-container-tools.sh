#!/bin/bash
set -euo pipefail
contents="${1:?usage: verify-container-tools.sh CONTENTS [--release]}"
plugin="$contents/Helpers/cli-plugins/docker-buildx"
resources="$contents/Resources/ContainerTools"
source "$resources/ContainerTools.lock"
file "$plugin" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --strict "$plugin"
signature="$(codesign -dvv "$plugin" 2>&1)"
[[ "$signature" == *"runtime)"* ]] || { echo 'Buildx is not signed with hardened runtime' >&2; exit 1; }
if [[ "${2:-}" == --release && "$signature" == *"Signature=adhoc"* ]]; then
    echo 'Release Buildx is ad-hoc signed' >&2; exit 1
fi
"$plugin" version | grep -F "v$BUILDX_VERSION"
(cd "$resources" && shasum -a 256 --check checksums.txt)
file "$resources/docker/dockerd" "$resources/cli-plugins/docker-buildx" | grep -q 'ARM aarch64'
echo "Verified bundled Docker $DOCKER_VERSION / BuildKit $BUILDKIT_VERSION / Buildx $BUILDX_VERSION"
