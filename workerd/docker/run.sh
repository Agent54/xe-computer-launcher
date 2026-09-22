#!/bin/sh
set -eu
runtime="$(cd "$(dirname "$0")" && pwd)"
state=/run/xe-router
umask 077
mkdir -p "$state"
# Keep the lock across exec, so duplicate start requests cannot steal the socket.
exec 9>"$state/owner.lock"
flock -n 9 || exit 0
printf '%s\n' "$$" > "$state/pid"
printf '%s\n' "$runtime" > "$state/runtime"
rm -f "$state/workerd.sock"
exec "$runtime/lib/ld-linux-aarch64.so.1" --library-path "$runtime/lib" \
    "$runtime/workerd" serve --experimental --binary "$runtime/guest-worker.bin" >"$state/workerd.log" 2>&1
