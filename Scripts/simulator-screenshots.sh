#!/usr/bin/env bash
# Builds Demo.xcodeproj for the iOS Simulator, checks that the installed app is
# the build this script made, then launches each screen and saves real
# screenshots to Demo/Screenshots/.
#
# It follows its own advice: a simulator of its own (created here and deleted
# on exit unless KEEP_SIM=1 or you pass SIM_UDID), DerivedData in ./build
# (deleted on exit unless KEEP_BUILD=1), a temp root it deletes, and a
# per-build stamp it reads back before it trusts anything it launches.
set -euo pipefail

BUNDLE_ID="com.rajatlakhina.AgentEnvelopeDemo"
OUT="Demo/Screenshots"
STAMP="${BUILD_STAMP:-$(date +%s)}"
TMP_ROOT="$(mktemp -d)"
mkdir -p "$OUT"

UDID="${SIM_UDID:-}"
CREATED=0
cleanup() {
  rm -rf "$TMP_ROOT"
  if [ "${KEEP_BUILD:-0}" != 1 ]; then
    rm -rf build
  fi
  if [ "$CREATED" = 1 ] && [ "${KEEP_SIM:-0}" != 1 ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -z "$UDID" ]; then
  PICK=$(xcrun simctl list -j runtimes | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and ".iOS-" in r["identifier"]]
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
if not runtimes:
    sys.exit("no available iOS runtime")
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

xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CURRENT_PROJECT_VERSION="$STAMP" CODE_SIGNING_ALLOWED=NO build

APP="build/Build/Products/Debug-iphonesimulator/Demo.app"
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
