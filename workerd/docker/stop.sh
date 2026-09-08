#!/bin/sh
set -eu
state=/run/xe-router
# Upgrade cleanup for the old launcher-owned Docker router, if it was installed.
if command -v docker >/dev/null 2>&1; then
    owner="$(docker --host unix:///var/run/docker.sock container inspect --format '{{index .Config.Labels "dev.xe.computer.owner"}}' xe-guest-router 2>/dev/null || true)"
    if [ "$owner" = dev.xe.computer.guest-router ]; then
        docker --host unix:///var/run/docker.sock container rm --force xe-guest-router >/dev/null
    fi
fi
[ -f "$state/pid" ] && [ -f "$state/runtime" ] || exit 0
pid="$(cat "$state/pid")"
runtime="$(cat "$state/runtime")"
case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
case "$runtime" in /opt/xe/guest-worker/releases/*) ;; *) exit 1 ;; esac
owned() {
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" = "$runtime/lib/ld-linux-aarch64.so.1" ]
}
# Check the executable before every signal; a stale PID must not kill another app.
if owned; then kill -TERM "$pid"; fi
attempt=0
while owned && [ "$attempt" -lt 10 ]; do
    sleep 0.5
    attempt=$((attempt + 1))
done
if owned; then kill -KILL "$pid"; fi
