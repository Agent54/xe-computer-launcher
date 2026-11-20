#!/bin/sh
# Host Buildx entrypoint. Metadata/version queries do not contact the VM.
set -eu
resources="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helpers="$(CDPATH= cd -- "$resources/../../Helpers" && pwd)"
buildx="$helpers/buildx"
case "${1:-}" in
    build|bake)
        prepare=1
        for argument in "$@"; do
            case "$argument" in --help|-h|--print|--list|--list=*) prepare=0 ;; esac
        done
        if [ "$prepare" = 1 ]; then
            : "${BUILDX_CONFIG:?Missing managed Buildx configuration}"
            mkdir -p "$BUILDX_CONFIG"
            /usr/bin/lockf -k -t 180 "$BUILDX_CONFIG/xe-prepare.lock" "$0" __xe_prepare </dev/null
        fi
        ;;
    __xe_prepare)
        . "$resources/ContainerTools.lock"
        : "${XE_SMOLVM_DATA_DIR:?Missing managed VM data directory}"
        : "${XE_SMOLVM_HOME:?Missing managed VM home}"
        : "${XE_SMOLVM_MACHINE:?Missing managed VM name}"
        image_id="$(HOME="$XE_SMOLVM_HOME" SMOLVM_DATA_DIR="$XE_SMOLVM_DATA_DIR" \
            SMOLVM_LIB_DIR="$helpers/SmolRuntime/lib" \
            DYLD_LIBRARY_PATH="$helpers/SmolRuntime/lib" \
            SMOLVM_AGENT_ROOTFS_TAR="$helpers/../Resources/SmolRuntime/agent-rootfs.tar" \
            "$helpers/SmolRuntime/smolvm-bin" machine exec --name "$XE_SMOLVM_MACHINE" --timeout 180s -- \
            /usr/local/share/xe-builder/prepare-builder.sh "$DOCKER_VERSION" "$BUILDKIT_IMAGE" </dev/null)"
        : "${image_id:?Guest Docker did not return a BuildKit image ID}"
        # Buildx owns locking and atomic writes of its node configuration.
        set --
        if [ -f "$BUILDX_CONFIG/instances/xe" ]; then set -- --append; fi
        "$buildx" create --name xe --node xe0 "$@" --driver docker-container \
            --driver-opt "image=$image_id" --driver-opt restart-policy=no \
            --driver-opt default-load=true --buildkitd-config "$resources/buildkitd.toml" "$DOCKER_HOST" </dev/null >&2
        exit 0
        ;;
esac
exec "$buildx" "$@"
