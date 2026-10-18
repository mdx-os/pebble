#!/bin/sh
# Captures each showcase screen on iPhone in light and dark.
# Usage: scripts/ui-screenshots.sh [output-dir]   (default: build/screenshots/ui)
# Expects the iOS Simulator app already built by scripts/screenshots.sh.
# PEBBLE_IPHONE picks the simulator by name (an iPad works too), and
# PEBBLE_SCREENS picks the showcase screens, separated by spaces.
set -eu

out="${1:-build/screenshots/ui}"
derived="build/DerivedData"
bundle_id="com.mdxos.pebble"
mkdir -p "$out"

# The app itself, picked by bundle id: Products also holds the UI test
# runner once `make ui-test` has run.
app=""
for candidate in "$derived/Build/Products/Debug-iphonesimulator"/*.app; do
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Info.plist" 2>/dev/null)" = "$bundle_id" ]; then
    app="$candidate"
  fi
done
if [ -z "$app" ]; then
  echo "ui-screenshots: no app with bundle id $bundle_id in $derived/Build/Products/Debug-iphonesimulator" >&2
  exit 1
fi
udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
devices = [d for r in json.load(sys.stdin)["devices"].values() for d in r]
print([d for d in devices if d["name"].startswith(wanted)][0]["udid"])
' "${PEBBLE_IPHONE:-iPhone 17 Pro}")"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$udid" "$app"

for mode in light dark; do
  xcrun simctl ui "$udid" appearance "$mode"
  for screen in ${PEBBLE_SCREENS:-today todayNeedsYou todayEmpty hello name look ideas memory confirm confirmTimedOut firstChat}; do
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" -showcaseScreen "$screen" >/dev/null
    sleep 3
    xcrun simctl io "$udid" screenshot "$out/$screen-$mode.png" >/dev/null
    echo "ui-screenshots: $out/$screen-$mode.png"
  done
done
xcrun simctl terminate "$udid" "$bundle_id" || true
xcrun simctl ui "$udid" appearance light
