#!/usr/bin/env bash
# App-hosted tvOS focus tests. Package logic tests do not have an application scene.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "plozz/focus-tests"
install_apple_build_lease_traps
source tools/lib/swift-package-storage.sh
configure_plozz_package_resolution "${PLOZZ_FOCUS_PACKAGES:-${PLOZZ_CLONED_SOURCE_PACKAGES:-$PWD/.build/package-workspaces/focus-tests}}"

if [[ ! -f Plozz.xcodeproj/project.pbxproj ]]; then
  tools/generate-project.sh
fi
if [[ -z "${PLOZZ_SIM_ID:-}" ]]; then
  PLOZZ_SIM_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    match = re.search(r"tvOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)
best = None
for runtime, items in devices.items():
    if "tvOS" not in runtime:
        continue
    # The app and the focus host build against tvOS 18. A stale booted runtime
    # (17.4 here) makes every destination ineligible, and xcodebuild then dumps
    # its whole ineligible list, which reads as if it picked iOS. Prefer the
    # newest supported runtime, then a booted device.
    release = version(runtime)
    if release[0] < 18:
        continue
    for device in items:
        if not device.get("isAvailable"):
            continue
        key = (release, device.get("state") == "Booted")
        if best is None or key > best[0]:
            best = (key, device["udid"])
if best is None:
    sys.exit("No available tvOS simulator with a tvOS 18+ runtime")
print(best[1])
')"
fi
python3 tools/run-bounded.py 300 "focus simulator startup" -- \
  xcrun simctl bootstatus "$PLOZZ_SIM_ID" -b

RESULTS="${PLOZZ_FOCUS_RESULTS:-$PWD/.build/focus-test-results}"
mkdir -p "$RESULTS"
RUN_DIR="$(mktemp -d "$RESULTS/Run-XXXXXXXX")"
BUILD_ARGS=(
  -project Plozz.xcodeproj -scheme PlozzFocusTests
  -destination "platform=tvOS Simulator,id=$PLOZZ_SIM_ID"
  -parallel-testing-enabled NO
  -derivedDataPath "${PLOZZ_FOCUS_DERIVED_DATA:-$PWD/.build/focus-shared-root-derived-data}"
  # Hosted timing assertions exercise optimized code while retaining DEBUG test seams.
  "${PACKAGE_RESOLUTION_ARGS[@]}" SWIFT_OPTIMIZATION_LEVEL=-O "$@" CODE_SIGNING_ALLOWED=NO
)
set +e
python3 tools/run-bounded.py "${PLOZZ_FOCUS_BUILD_TIMEOUT:-2400}" "hosted focus build" -- \
  xcodebuild build-for-testing "${BUILD_ARGS[@]}" \
  -resultBundlePath "$RUN_DIR/Build.xcresult" 2>&1 | tee "$RUN_DIR/build.log"
PIPE_STATUSES=("${PIPESTATUS[@]}")
if [[ "${PIPE_STATUSES[0]}" -ne 0 ]]; then exit "${PIPE_STATUSES[0]}"; fi
if [[ "${PIPE_STATUSES[1]}" -ne 0 ]]; then exit "${PIPE_STATUSES[1]}"; fi

python3 tools/run-bounded.py "${PLOZZ_FOCUS_TEST_TIMEOUT:-2400}" "hosted focus tests" -- \
  xcodebuild test-without-building "${BUILD_ARGS[@]}" -collect-test-diagnostics on-failure \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 600 \
  -maximum-test-execution-time-allowance 600 \
  -resultBundlePath "$RUN_DIR/Test.xcresult" \
  2>&1 | tee "$RUN_DIR/xcodebuild.log"
PIPE_STATUSES=("${PIPESTATUS[@]}")
STATUS=${PIPE_STATUSES[0]}
if [[ "$STATUS" -eq 0 && "${PIPE_STATUSES[1]}" -ne 0 ]]; then
  STATUS=${PIPE_STATUSES[1]}
fi
set -e
echo "Focus result bundle: $RUN_DIR/Test.xcresult"
if ! python3 tools/run-bounded.py 30 "focus result summary" -- \
  xcrun xcresulttool get test-results summary --path "$RUN_DIR/Test.xcresult" > "$RUN_DIR/summary.json"; then
  echo "No readable hosted-test result; preserving the original failure and raw log." >&2
  if [[ "$STATUS" -ne 0 ]]; then exit "$STATUS"; fi
  exit 1
fi
python3 tools/xcresult-summary.py verdict "$RUN_DIR/summary.json"
exit "$STATUS"
