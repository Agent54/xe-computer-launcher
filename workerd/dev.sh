#!/usr/bin/env bash
set -euo pipefail
worker_dir="$(cd "$(dirname "$0")" && pwd)"
: "${COMPOSE_UI_ASSETS:?Set COMPOSE_UI_ASSETS to the extracted pinned UI archive}"
: "${COMPOSE_SOCKET:?Set COMPOSE_SOCKET to the host Compose Unix socket}"
: "${ROUTER_SOCKET:?Set ROUTER_SOCKET to the exposed guest workerd Unix socket}"
worker_binary="${WORKERD_BIN:-$worker_dir/node_modules/.bin/workerd}"
child=""
cleanup() {
    if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
printf 'Compose UI: http://127.0.0.1:8094/\n'
"$worker_binary" serve --watch "$worker_dir/config.capnp" \
    --inspector-addr=0.0.0.0:9229 --verbose \
    --directory-path "assets=$COMPOSE_UI_ASSETS" \
    --external-addr "compose=unix:$COMPOSE_SOCKET" --external-addr "router=unix:$ROUTER_SOCKET" &
child=$!
wait "$child"
