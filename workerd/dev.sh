#!/usr/bin/env bash
set -euo pipefail
worker_dir="$(cd "$(dirname "$0")" && pwd)"
: "${COMPOSE_UI_ASSETS:?Set COMPOSE_UI_ASSETS to the extracted pinned UI archive}"
: "${COMPOSE_SOCKET:?Set COMPOSE_SOCKET to the host Compose Unix socket}"
: "${ROUTER_SOCKET:?Set ROUTER_SOCKET to the exposed guest workerd Unix socket}"
worker_binary="${WORKERD_BIN:-$worker_dir/node_modules/.bin/workerd}"
runtime_dir="$(mktemp -d)"
child=""
cleanup() {
    if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    rm -rf "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for source in "$worker_dir/config.capnp" "$worker_dir"/*.js; do
    ln -s "$source" "$runtime_dir/$(basename "$source")"
done
openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -keyout "$runtime_dir/ui.key" -out "$runtime_dir/ui.crt" \
    -subj '/CN=compose-ui.localhost' \
    -addext 'subjectAltName=DNS:compose-ui.localhost,DNS:*.app.localhost' >/dev/null 2>&1
chmod 600 "$runtime_dir/ui.key"
printf 'Compose UI: http://127.0.0.1:8094/\n'
"$worker_binary" serve --experimental --watch "$runtime_dir/config.capnp" \
    --inspector-addr=0.0.0.0:9229 --verbose \
    --directory-path "assets=$COMPOSE_UI_ASSETS" \
    --socket-addr "ingest=127.0.0.1:${HTTP_PORT:-5196}" \
    --socket-addr "tls=127.0.0.1:${HTTPS_PORT:-5194}" \
    --socket-addr "ui-https=unix:$runtime_dir/ui-https.sock" \
    --external-addr "ui-tls=unix:$runtime_dir/ui-https.sock" \
    --external-addr "compose=unix:$COMPOSE_SOCKET" --external-addr "router=unix:$ROUTER_SOCKET" &
child=$!
wait "$child"
