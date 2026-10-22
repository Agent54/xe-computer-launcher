#!/bin/bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-https-cleanup.sh"

# Model process state without signaling any real macOS authorization process.
fixture() {
    record_41='501 S /System/Library/CoreServices/SecurityAgent.app/Contents/MacOS/SecurityAgent'
    record_42=''
    fixture_pids=41
    exit_on=TERM
    signals=''
    sleeps=0
}
log() { :; }
id() { [[ "$*" == -u ]]; printf '501\n'; }
pgrep() {
    [[ "$*" == '-u 501 -x SecurityAgent' ]] || exit 90
    [[ -n "$fixture_pids" ]] || return 1
    printf '%s\n' "$fixture_pids"
}
ps() {
    case "$*" in
        '-p 41 -o uid= -o stat= -o comm='|'-p 41 -o pid= -o uid= -o stat= -o comm=')
            [[ -n "$record_41" ]] || return 1
            printf '%s\n' "$record_41"
            ;;
        '-p 42 -o uid= -o stat= -o comm=')
            [[ -n "$record_42" ]] || return 1
            printf '%s\n' "$record_42"
            ;;
        *) exit 91 ;;
    esac
}
kill() {
    [[ "$1" == -TERM || "$1" == -KILL ]] || exit 92
    signals="$signals|$*"
    case "$2" in
        41) [[ "$1" != "-$exit_on" ]] || record_41='' ;;
        42) [[ "$1" != "-$exit_on" ]] || record_42='' ;;
        *) exit 93 ;;
    esac
    return 0
}
sleep() {
    [[ "$*" == 0.25 ]] || exit 94
    sleeps=$((sleeps + 1))
}

(
    fixture
    fixture_pids=''
    reset_ci_security_agent
    [[ -z "$signals" && "$sleeps" == 0 ]]
    printf 'PASS: no agent needs no signal or delay\n'
)
(
    fixture
    reset_ci_security_agent
    [[ "$signals" == '|-TERM 41' && "$sleeps" == 0 ]]
    printf 'PASS: normal termination does not escalate\n'
)
(
    fixture
    exit_on=KILL
    reset_ci_security_agent
    [[ "$signals" == '|-TERM 41|-KILL 41' && "$sleeps" == 20 ]]
    printf 'PASS: agent that ignores SIGTERM is killed after five seconds\n'
)
(
    fixture
    fixture_pids=$'41\n42'
    record_42="$record_41"
    exit_on=KILL
    reset_ci_security_agent
    [[ "$signals" == '|-TERM 41|-TERM 42|-KILL 41|-KILL 42' ]]
    printf 'PASS: all original runner agents are stopped\n'
)
(
    fixture
    record_41='501 Z SecurityAgent'
    reset_ci_security_agent
    [[ -z "$signals" && "$sleeps" == 0 ]]
    printf 'PASS: zombies count as exited\n'
)
(
    fixture
    record_41='502 S SecurityAgent'
    reset_ci_security_agent
    [[ -z "$signals" && "$sleeps" == 0 ]]
    record_41='501 S /usr/bin/other-process'
    reset_ci_security_agent
    [[ -z "$signals" && "$sleeps" == 0 ]]
    printf 'PASS: changed owner or executable prevents signaling\n'
)
(
    fixture
    exit_on=never
    sleep() {
        sleeps=$((sleeps + 1))
        if [[ "$sleeps" == 20 ]]; then
            record_41='501 S /usr/bin/reused-pid'
            record_42='501 S SecurityAgent'
        fi
    }
    reset_ci_security_agent
    [[ "$signals" == '|-TERM 41' && "$sleeps" == 20 ]]
    printf 'PASS: reused PIDs and replacement agents are left alone\n'
)
(
    fixture
    exit_on=never
    if reset_ci_security_agent 2>/dev/null; then
        printf 'FAIL: accepted an agent that survived both signals\n' >&2
        exit 1
    fi
    [[ "$signals" == '|-TERM 41|-KILL 41' && "$sleeps" == 40 ]]
    printf 'PASS: failed termination remains a bounded failure\n'
)
(
    fixture
    messages=''
    log() { messages="$messages|$*"; }
    kill() { signals="$signals|$*"; return 1; }
    if reset_ci_security_agent 2>/dev/null; then
        printf 'FAIL: ignored a denied termination signal\n' >&2
        exit 1
    fi
    [[ "$signals" == '|-TERM 41|-KILL 41' && "$sleeps" == 40 ]]
    [[ "$messages" == *'could not send SIGTERM'* && "$messages" == *'could not send SIGKILL'* ]]
    printf 'PASS: denied signals are reported and remain fatal\n'
)
