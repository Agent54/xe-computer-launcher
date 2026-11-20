#!/bin/sh
set -eu
runtime="$(cd "$(dirname "$0")" && pwd)"
state=/run/xe-router
umask 077
mkdir -p "$state"
# The VM entrypoint owns this process. /run is private to the workload, and
# stdout/stderr go to its console for the host's existing log collector.
rm -f "$state/workerd.sock"
exec "$runtime/lib/ld-linux-aarch64.so.1" --library-path "$runtime/lib" \
    "$runtime/workerd" serve --experimental --binary "$runtime/guest-worker.bin"
