#!/bin/bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$MACOS_DIR/.build"
TEST_ROOT="$(mktemp -d "$MACOS_DIR/.build/guest-worker-package-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/macos" "$TEST_ROOT/workerd/dist" "$TEST_ROOT/workerd/docker" \
    "$TEST_ROOT/assets/lib" "$TEST_ROOT/assets/licenses" "$TEST_ROOT/assets/host-worker/devtools" \
    "$TEST_ROOT/build/guest-worker/host-worker"
printf 'linux runtime\n' > "$TEST_ROOT/assets/workerd"
printf 'loader\n' > "$TEST_ROOT/assets/lib/ld-linux-aarch64.so.1"
printf 'library\n' > "$TEST_ROOT/assets/lib/libc.so.6"
printf 'license\n' > "$TEST_ROOT/assets/licenses/workerd-README.md"
printf 'old guest config\n' > "$TEST_ROOT/assets/guest-worker.bin"
printf 'old script\n' > "$TEST_ROOT/assets/run.sh"
printf 'old script\n' > "$TEST_ROOT/assets/stop.sh"
printf 'host source\n' > "$TEST_ROOT/assets/host-worker/config.capnp"
printf 'host devtools\n' > "$TEST_ROOT/assets/host-worker/devtools/inspector.html"
printf 'unrelated build output\n' > "$TEST_ROOT/assets/guest-runtime.ldd"
printf 'stale host source\n' > "$TEST_ROOT/build/guest-worker/host-worker/config.capnp"
printf 'fresh guest config\n' > "$TEST_ROOT/workerd/dist/guest-worker.bin"
printf 'fresh run script\n' > "$TEST_ROOT/workerd/docker/run.sh"
printf 'fresh stop script\n' > "$TEST_ROOT/workerd/docker/stop.sh"
(
    cd "$TEST_ROOT/assets"
    shasum -a 256 workerd guest-worker.bin lib/* licenses/* run.sh stop.sh > checksums.txt
)

# Run the actual staging recipe with a mixed artifact/build directory and a
# stale destination, without building workerd or downloading dependencies.
make --no-print-directory -s -C "$TEST_ROOT/macos" -f "$MACOS_DIR/Makefile" \
    -o workerd guest-worker DEVELOPMENT_ID=- \
    BUILD_DIR="$TEST_ROOT/build" GUEST_ROUTER_ASSET_DIR="$TEST_ROOT/assets"

stage="$TEST_ROOT/build/guest-worker"
[[ ! -e "$stage/host-worker" && ! -e "$stage/guest-runtime.ldd" ]]
cmp "$TEST_ROOT/assets/workerd" "$stage/workerd"
cmp "$TEST_ROOT/assets/lib/libc.so.6" "$stage/lib/libc.so.6"
cmp "$TEST_ROOT/assets/licenses/workerd-README.md" "$stage/licenses/workerd-README.md"
cmp "$TEST_ROOT/workerd/dist/guest-worker.bin" "$stage/guest-worker.bin"
cmp "$TEST_ROOT/workerd/docker/run.sh" "$stage/run.sh"
cmp "$TEST_ROOT/workerd/docker/stop.sh" "$stage/stop.sh"
[[ -x "$stage/workerd" && -x "$stage/lib/ld-linux-aarch64.so.1" ]]
(
    cd "$stage"
    shasum -a 256 --check checksums.txt
)
printf 'PASS: guest runtime staging excludes host resources and refreshes guest config\n'
