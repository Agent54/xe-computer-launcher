#!/bin/sh
set -eu
tools="${XE_CONTAINER_TOOLS:?Bundled container tools path is missing}"
. "$tools/ContainerTools.lock"
export PATH="$tools/docker:$PATH"
export DOCKER_HOST=unix:///var/run/docker.sock
export DOCKER_CONFIG=/storage/xe-build-client
unset DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION BUILDX_BUILDER
umask 077
mkdir -p "$DOCKER_CONFIG"
printf '{"cliPluginsExtraDirs":["%s/cli-plugins"]}\n' "$tools" > "$DOCKER_CONFIG/config.json"
actual="$(docker version --format '{{.Server.Version}}')"
[ "$actual" = "$DOCKER_VERSION" ] || { echo "Expected Docker $DOCKER_VERSION, got $actual" >&2; exit 1; }
if ! docker image inspect "$BUILDKIT_IMAGE_ID" >/dev/null 2>&1; then
    docker load --input "$tools/buildkit.tar"
fi
docker image inspect "$BUILDKIT_IMAGE_ID" >/dev/null
# Buildx bootstrap does not replace an existing container when its image changes.
# Replace only our recorded container, retaining its named build-cache volume.
container=buildx_buildkit_xe0
owner="$DOCKER_CONFIG/xe-builder-owner"
revision="$(sha256sum "$tools/buildkitd.toml" | cut -d ' ' -f 1)"
expected="$(printf '%s\n%s' "$BUILDKIT_IMAGE_ID" "$revision")"
if existing="$(docker container inspect --format '{{.Image}}' "$container" 2>/dev/null)"; then
    [ -f "$owner" ] && [ "$existing" = "$(head -n 1 "$owner")" ] || {
        echo "Refusing to replace unrecognized builder container $container" >&2; exit 1;
    }
    if [ "$(cat "$owner")" != "$expected" ]; then
        docker stop "$container"
        docker rm "$container"
    fi
fi
# Record intent before bootstrap so an interrupted first startup can recover.
printf '%s\n' "$expected" > "$owner.new"
mv "$owner.new" "$owner"
set --
if [ -f "$DOCKER_CONFIG/buildx/instances/xe" ]; then set -- --append; fi
"$tools/cli-plugins/docker-buildx" create --name xe --node xe0 "$@" \
    --driver docker-container --driver-opt "image=$BUILDKIT_IMAGE_ID" \
    --driver-opt default-load=true --buildkitd-config "$tools/buildkitd.toml" "$DOCKER_HOST"
"$tools/cli-plugins/docker-buildx" inspect xe --bootstrap
version="$(docker exec buildx_buildkit_xe0 buildkitd --version)"
case "$version" in *"v$BUILDKIT_VERSION "*) ;; *) echo "Unexpected BuildKit version: $version" >&2; exit 1 ;; esac
