#!/bin/sh
# Builds the app and captures its first screen on iPhone, iPad and Mac.
# Usage: scripts/screenshots.sh [output-dir]   (default: build/screenshots)
# Override simulators with PEBBLE_IPHONE / PEBBLE_IPAD (device names).
set -eu

out="${1:-build/screenshots}"
derived="build/DerivedData"
bundle_id="com.mdxos.pebble"
mkdir -p "$out"

# First available simulator whose name starts with $1, unless $2 names one.
pick_sim() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
prefix, wanted = sys.argv[1], sys.argv[2]
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime]
match = [d for d in devices if (d["name"] == wanted if wanted else d["name"].startswith(prefix))]
if not match:
    sys.exit("no available simulator for " + (wanted or prefix))
print(match[0]["udid"])
' "$1" "${2:-}"
}

built_app() {
  find "$derived/Build/Products/$1" -maxdepth 1 -name '*.app' | head -n 1
}

echo "screenshots: building for iOS Simulator"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO
ios_app="$(built_app Debug-iphonesimulator)"

for kind in iPhone iPad; do
  if [ "$kind" = iPhone ]; then wanted="${PEBBLE_IPHONE:-}"; else wanted="${PEBBLE_IPAD:-}"; fi
  udid="$(pick_sim "$kind" "$wanted")"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
  xcrun simctl install "$udid" "$ios_app"
  xcrun simctl launch "$udid" "$bundle_id" >/dev/null
  sleep 4
  file="$out/$(echo "$kind" | tr '[:upper:]' '[:lower:]').png"
  xcrun simctl io "$udid" screenshot "$file" >/dev/null
  xcrun simctl terminate "$udid" "$bundle_id" || true
  xcrun simctl shutdown "$udid" || true
  echo "screenshots: $file"
done

echo "screenshots: building for macOS"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -onlyUsePackageVersionsFromResolvedFile
mac_app="$(built_app Debug)"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$mac_app/Contents/Info.plist")"
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac.png"
echo "screenshots: $out/mac.png"
