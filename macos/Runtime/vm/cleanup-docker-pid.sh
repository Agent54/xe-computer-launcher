#!/bin/sh
set -eu
# Never traverse /run's mounts or remove symlinks/directories. The fixed daemon
# configuration uses this one PID file; an unclean stop can leave it behind.
if [ ! -L /run/docker.pid ] && [ -f /run/docker.pid ]; then
    rm -f -- /run/docker.pid
fi
