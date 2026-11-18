#!/bin/bash
set -euo pipefail
contents="${1:?usage: verify-container-tools.sh CONTENTS [--release]}"
plugin="$contents/Helpers/buildx"
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
"$contents/Resources/ContainerTools/cli-plugins/docker-buildx" version | grep -F "v$BUILDX_VERSION"
[[ ! -e "$resources/docker" && ! -e "$resources/buildkit.tar" && ! -e "$resources/start-builder.sh" ]] || {
    echo 'Guest engines must be embedded in the SmolVM image, not launcher resources' >&2; exit 1;
}
echo "Verified host Buildx $BUILDX_VERSION for SmolVM Docker $DOCKER_VERSION / BuildKit $BUILDKIT_VERSION"
