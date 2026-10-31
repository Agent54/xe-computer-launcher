#!/bin/bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

assert_once() {
    local count
    count="$(printf '%s\n' "$plan" | grep -Fc -- "$1" || true)"
    [[ "$count" == 1 ]] || { printf 'Expected one build step for %s; got %s\n' "$1" "$count" >&2; exit 1; }
}

for configuration in release debug; do
    target=all
    [[ "$configuration" == release ]] || target=bundle
    # Dry-run the real graph, including recursive signing targets. Explicit
    # fixture identities avoid reading local signing configuration into output.
    plan="$(make -ns -C "$MACOS_DIR" BUILD_CONFIG="$configuration" DEVELOPMENT_ID=- DEVELOPER_ID=- SPARKLE_PUBLIC_ED_KEY=fixture "$target")"
    assert_once 'deno install --frozen'
    assert_once 'deno task build:guest'
    assert_once 'Scripts/prepare-compose-ui.sh'
    assert_once 'Scripts/prepare-compose-server.sh'
    assert_once 'Scripts/prepare-smol-runtime.sh'
    assert_once "BUILD_CONFIG=\"$configuration\" /bin/bash Scripts/test-runtime.sh"
    assert_once "cp \".build/$configuration/macos\""
    if printf '%s\n' "$plan" | grep -q 'swift build'; then
        printf 'Packaging must reuse the SwiftPM test build\n' >&2
        exit 1
    fi
done
printf 'PASS: default/release and debug bundle graphs prepare, test, and package once\n'
