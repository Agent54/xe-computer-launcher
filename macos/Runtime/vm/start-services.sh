#!/bin/sh
set -eu
# The image owns one router and one Docker daemon. Start them concurrently so
# routing adds no wait to Docker startup. Neither path starts the builder.
docker_pid=
router_pid=
stop() {
    trap '' TERM INT
    for pid in "$router_pid" "$docker_pid"; do
        [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || :
    done
    wait "$router_pid" 2>/dev/null || :
    wait "$docker_pid" 2>/dev/null || :
}
trap 'stop; exit 0' TERM INT
/opt/xe/guest-worker/start-router.sh &
router_pid=$!
/usr/local/bin/dockerd-entrypoint.sh "$@" &
docker_pid=$!
status=0
wait -n || status=$?
echo "Guest service exited (status $status); stopping the workload" >&2
stop
# An unexpected clean exit is also a service failure. The existing host runtime
# supervisor observes the workload exit and owns recovery of the whole VM.
[ "$status" -ne 0 ] || status=1
exit "$status"
