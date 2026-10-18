#!/bin/bash

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
