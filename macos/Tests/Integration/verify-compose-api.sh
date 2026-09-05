#!/bin/bash
set -euo pipefail

socket="${1:?usage: verify-compose-api.sh COMPOSE_SOCKET}"

# This only gates the Docker-backed assertion. Packaging, signatures, the
# installer, and host-only Compose lifecycle tests still run in VM CI.
if [[ "${XE_TEST_SUB_VM_AVAILABLE:-auto}" == "0" ]] \
    || [[ "$(/usr/sbin/sysctl -n kern.hv_support 2>/dev/null || true)" != "1" ]]; then
    message="sub-VM not available; skipping the Docker-backed Compose integration check. Launcher installation checks will continue."
    if [[ "${CI:-}" == "true" ]]; then
        printf '::warning::%s\n' "$message"
    else
        printf 'WARNING: %s\n' "$message" >&2
    fi
    exit 0
fi

echo "[compose-integration] waiting for the Compose API backed by SmolVM"
deadline=$((SECONDS + ${COMPOSE_READY_TIMEOUT_SECONDS:-120}))
while (( SECONDS < deadline )); do
    if /usr/bin/curl --disable --silent --fail --max-time 2 --noproxy '*' \
        --unix-socket "$socket" --output /dev/null 'http://localhost/ls?all=true'; then
        echo "[compose-integration] Compose API backed by SmolVM is ready"
        exit 0
    fi
    sleep 1
done
echo "[compose-integration] ERROR: Compose API did not become ready at $socket" >&2
exit 1
