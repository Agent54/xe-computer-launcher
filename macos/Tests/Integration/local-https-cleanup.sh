#!/bin/bash

ci_security_agent_is_running() {
    local process_info
    local process_user_id
    local process_state
    local process_command

    process_info="$(ps -p "$1" -o uid= -o stat= -o comm= 2>/dev/null)" || return 1
    read -r process_user_id process_state process_command <<<"$process_info"
    # A zombie cannot own a dialog. Recheck identity before every signal so a
    # reused PID cannot target another executable or another user's process.
    [[ "$process_user_id" == "$2" && "$process_state" != Z* \
        && "${process_command##*/}" == SecurityAgent ]]
}

# Called only by the guarded CI cleanup, after Xe's approval clients stop and
# before a new trust request starts. SecurityAgent can retain a password panel
# (or stop answering AX queries) after its security client has exited. Reset
# only this dedicated runner user's UI agent; never securityd, authd or TCC.
reset_ci_security_agent() {
    local runner_user_id
    local security_agent_pids
    local security_agent_pid
    local still_running
    local attempt
    local signal

    runner_user_id="$(id -u)" || return 1
    security_agent_pids="$(pgrep -u "$runner_user_id" -x SecurityAgent 2>/dev/null || true)"
    [[ -n "$security_agent_pids" ]] || return 0

    log "closing the runner's previous SecurityAgent authorization UI"
    for signal in TERM KILL; do
        if [[ "$signal" == KILL ]]; then
            log "previous SecurityAgent survived SIGTERM; forcing it to exit with SIGKILL"
        fi
        for security_agent_pid in $security_agent_pids; do
            if ci_security_agent_is_running "$security_agent_pid" "$runner_user_id"; then
                kill "-$signal" "$security_agent_pid" 2>/dev/null \
                    || log "could not send SIG$signal to SecurityAgent PID $security_agent_pid"
            fi
        done
        for ((attempt = 0; attempt < 20; attempt++)); do
            still_running=0
            for security_agent_pid in $security_agent_pids; do
                if ci_security_agent_is_running "$security_agent_pid" "$runner_user_id"; then
                    still_running=1
                fi
            done
            [[ "$still_running" == 1 ]] || return 0
            sleep 0.25
        done
    done
    # Wait only for the original PIDs: macOS may already have started a fresh
    # agent. A replacement must not be mistaken for the stale UI or stopped.
    log "previous SecurityAgent is still running after SIGTERM and SIGKILL"
    for security_agent_pid in $security_agent_pids; do
        if ci_security_agent_is_running "$security_agent_pid" "$runner_user_id"; then
            ps -p "$security_agent_pid" -o pid= -o uid= -o stat= -o comm= >&2 || true
        fi
    done
    return 1
}

# Shared by the manual and CI cleanup after removing the CA's user trust
# setting. add-trusted-cert also installs a certificate item; removing only
# its trust setting leaves that item in the user's default Keychain.
remove_local_https_certificate() {
    local root_certificate="$1"
    local fingerprint
    local keychain
    local certificates

    fingerprint="$(/usr/bin/openssl x509 -in "$root_certificate" -noout -fingerprint -sha256)" \
        || fail "could not identify the previous local HTTPS CA"
    fingerprint="${fingerprint#*=}"
    fingerprint="${fingerprint//:/}"
    [[ "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]] \
        || fail "invalid local HTTPS CA fingerprint"

    keychain="$(security default-keychain -d user)" \
        || fail "could not identify the current user's default Keychain"
    keychain="$(printf '%s\n' "$keychain" | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
    [[ "$keychain" == /* && -f "$keychain" ]] \
        || fail "current user's default Keychain is unavailable"
    certificates="$(security find-certificate -a -Z "$keychain")" \
        || fail "could not inspect certificates in the current user's default Keychain"
    if ! grep -Fqx "SHA-256 hash: $fingerprint" <<<"$certificates"; then
        log "previous local HTTPS CA certificate is already absent from the current user's default Keychain"
        return 0
    fi

    log "removing the previous local HTTPS CA certificate from the current user's default Keychain"
    security delete-certificate -Z "$fingerprint" "$keychain" \
        || fail "could not remove the previous local HTTPS CA certificate"
}
