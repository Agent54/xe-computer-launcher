#!/usr/bin/env bash

set -euo pipefail

runtime="${1:?usage: sign-smol-runtime.sh RUNTIME IDENTITY ENTITLEMENTS}"
identity="${2:?usage: sign-smol-runtime.sh RUNTIME IDENTITY ENTITLEMENTS}"
entitlements="${3:?usage: sign-smol-runtime.sh RUNTIME IDENTITY ENTITLEMENTS}"

[[ -x "$runtime/smolvm-bin" ]] || {
    echo "missing SmolVM executable: $runtime/smolvm-bin" >&2
    exit 1
}
[[ -f "$entitlements" ]] || {
    echo "missing SmolVM entitlements: $entitlements" >&2
    exit 1
}

codesign_args=(--force --options runtime)
if [[ "$identity" != "-" ]]; then
    codesign_args+=(--timestamp)
fi

while IFS= read -r -d '' library; do
    codesign "${codesign_args[@]}" \
        --sign "$identity" "$library"
done < <(find "$runtime/lib" -type f -name '*.dylib' -print0)

codesign "${codesign_args[@]}" \
    --entitlements "$entitlements" \
    --sign "$identity" \
    "$runtime/smolvm-bin"

echo "Signed embedded SmolVM runtime with: $identity"
