#!/bin/bash
set -euo pipefail

report_runtime_tests() {
  local status=$?
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return "$status"
  local result="✅ Runtime tests passed"
  if (( status != 0 )); then
    result="❌ Runtime test command failed (exit $status). Results may be incomplete; see the logs."
    printf '::error title=Runtime tests failed::%s\n' "$result"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Runtime tests\n\n%s\n' "$result" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  return "$status"
}
trap report_runtime_tests EXIT

cd "$(dirname "$0")/.."

swift_compiler="$(/usr/bin/xcrun --find swiftc)"
/usr/bin/xcode-select --print-path
/usr/bin/xcrun swift --version
echo "Swift compiler: $swift_compiler"

# This suite uses Swift Testing exclusively. CLT has no XCTest runner.
test_args=(test --disable-xctest --enable-swift-testing)
frameworks_dir="$(dirname "$swift_compiler")/../../Library/Developer/Frameworks"
if [[ -d "$frameworks_dir/Testing.framework" ]]; then
  frameworks_dir="$(cd "$frameworks_dir" && pwd -P)"
  # SwiftPM 6.3 discovers CLT's Testing.framework but emits -I/-L for its
  # containing directory. Supply framework search paths and the runtime path.
  echo "Swift Testing frameworks: $frameworks_dir"
  test_args+=(
    -Xswiftc -F -Xswiftc "$frameworks_dir"
    -Xlinker -F -Xlinker "$frameworks_dir"
    -Xlinker -rpath -Xlinker "$frameworks_dir"
    -Xlinker -rpath -Xlinker "$frameworks_dir/../usr/lib"
  )
fi

/bin/bash Tests/Integration/test-install-targets.sh
/bin/bash Tests/Integration/settings-termination.sh

/usr/bin/xcrun swift "${test_args[@]}" "$@"
