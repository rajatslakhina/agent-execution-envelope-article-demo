#!/usr/bin/env bash
# Builds Demo.xcodeproj for the iOS Simulator, checks that the installed app is
# the build this script made, then launches each screen and saves real
# screenshots to Demo/Screenshots/.
#
# It follows its own advice: a simulator of its own (created here and deleted
# on exit unless KEEP_SIM=1 or you pass SIM_UDID), DerivedData in ./build
# (deleted on exit unless KEEP_BUILD=1), TMPDIR pointed at a temp root it
# deletes, and a per-build stamp it reads back before it trusts any launch.
set -euo pipefail

# Work from the repo root whatever directory this was started from, so the
# build folder it creates (and deletes) is always this repo's.
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
BUILD_DIR="$REPO_ROOT/build"
OUT="$REPO_ROOT/Demo/Screenshots"

BUNDLE_ID="com.rajatlakhina.AgentEnvelopeDemo"
STAMP="${BUILD_STAMP:-$(date +%s)}"
TMP_ROOT="$(mktemp -d)"
export TMPDIR="$TMP_ROOT/"
mkdir -p "$OUT"

UDID="${SIM_UDID:-}"
CREATED=0
cleanup() {
  rm -rf "$TMP_ROOT"
  if [ "${KEEP_BUILD:-0}" != 1 ]; then
    rm -rf "$BUILD_DIR"
  fi
  if [ "$CREATED" = 1 ] && [ "${KEEP_SIM:-0}" != 1 ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -z "$UDID" ]; then
  # The newest installed iOS runtime this Xcode's simulator SDK can target.
  SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  PICK=$(xcrun simctl list -j runtimes | SDK_VERSION="$SDK_VERSION" python3 -c '
import json, os, sys
def version(text):
    return [int(part) for part in text.split(".") if part.isdigit()]
sdk = version(os.environ["SDK_VERSION"])
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and ".iOS-" in r["identifier"]
            and version(r["version"])[:2] <= sdk[:2]]
runtimes.sort(key=lambda r: version(r["version"]))
if not runtimes:
    sys.exit("no available iOS runtime at or below the iOS Simulator SDK " + os.environ["SDK_VERSION"])
rt = runtimes[-1]
types = [t for t in rt.get("supportedDeviceTypes", []) if t["name"].startswith("iPhone") and t["name"].endswith("Pro")]
if not types:
    sys.exit("no iPhone Pro device type for " + rt["name"])
types.sort(key=lambda t: t["name"])
print(rt["identifier"], types[-1]["identifier"])')
  RUNTIME="${PICK%% *}"
  DEVICE_TYPE="${PICK##* }"
  UDID=$(xcrun simctl create "AgentEnvelope Demo" "$DEVICE_TYPE" "$RUNTIME")
  CREATED=1
fi
echo "Using simulator $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true

# Build for the generic simulator platform, then install on this run's own device.
xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$BUILD_DIR" \
  CURRENT_PROJECT_VERSION="$STAMP" CODE_SIGNING_ALLOWED=NO build

APP="$BUILD_DIR/Build/Products/Debug-iphonesimulator/Demo.app"
xcrun simctl install "$UDID" "$APP"

# Verify against the artifact we built, not against whatever is installed.
APP_DIR=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Info.plist")
if [ "$INSTALLED" != "$STAMP" ]; then
  echo "Installed build is $INSTALLED, expected $STAMP: this is not the app this script built." >&2
  exit 1
fi
echo "Installed build $INSTALLED matches the stamp this script built."

xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true

shoot () {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
  sleep 8
  # Fails if the app crashed after launch: a running app has a numeric PID in column one.
  xcrun simctl spawn "$UDID" launchctl list > "$TMP_ROOT/processes.txt"
  awk -v id="$BUNDLE_ID" 'index($0, id) && $1 ~ /^[0-9]+$/ { found = 1 } END { exit !found }' "$TMP_ROOT/processes.txt"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
}

shoot audit-worktrees-only -tab audit -setup worktreesOnly
shoot audit-envelope -tab audit -setup envelope
shoot runway -tab runway
shoot verify-shared-simulator -tab verify -replay sharedSimulator
shoot contract -tab contract
ls -la "$OUT"
