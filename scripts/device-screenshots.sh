#!/bin/sh
# Captures showcase screens on several simulators, in portrait and landscape.
# Usage: scripts/device-screenshots.sh [output-dir]   (default: build/screenshots/devices)
# Writes <output-dir>/<device>/<screen>-<orientation>.png.
# Override with PEBBLE_DEVICES (device names, one per line) and PEBBLE_SCREENS.
# The simulator can only be turned from a UI test, so the shots are taken by
# the ShowcaseShots test in AppUITests.
set -eu

out="${1:-build/screenshots/devices}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
derived="build/DerivedData"
devices="${PEBBLE_DEVICES:-iPad Pro 13-inch (M5)
iPad mini (A17 Pro)
iPhone 17 Pro}"

# Only shots written by this run get turned, so older ones aren't turned again.
stamp="$(mktemp)"
trap 'rm -f "$stamp"' EXIT

echo "$devices" | while IFS= read -r device; do
  [ -n "$device" ] || continue
  echo "device-screenshots: $device"
  # TEST_RUNNER_ variables reach the test as PEBBLE_SHOTS and PEBBLE_SCREENS.
  TEST_RUNNER_PEBBLE_SHOTS="$out" TEST_RUNNER_PEBBLE_SCREENS="${PEBBLE_SCREENS:-}" \
    xcodebuild test -quiet -project Pebble.xcodeproj -scheme Pebble \
    -destination "platform=iOS Simulator,name=$device" -derivedDataPath "$derived" \
    -only-testing:PebbleAppUITests/ShowcaseShots
done
# Screenshots come out in the panel's own portrait frame; stand the
# landscape ones upright.
find "$out" -name '*-landscape.png' -newer "$stamp" -exec sips -r 270 {} \; >/dev/null
find "$out" -name '*.png' | sort
