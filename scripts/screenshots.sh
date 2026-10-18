#!/bin/sh
# Builds the app and captures its first screen on iPhone, iPad and Mac.
# Usage: scripts/screenshots.sh [output-dir]   (default: build/screenshots)
# Override simulators with PEBBLE_IPHONE / PEBBLE_IPAD (device names).
set -eu

out="${1:-build/screenshots}"
derived="build/DerivedData"
bundle_id="com.mdxos.pebble"
mkdir -p "$out" build

# Simulators are shared with other worktrees, so whatever happens, one
# switched to dark goes back to light.
darkened=""
restore_light() {
  for sim in $darkened; do xcrun simctl ui "$sim" appearance light 2>/dev/null || true; done
}
trap restore_light EXIT

swiftc -O scripts/same-shot.swift -o build/same-shot

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

# A screenshot of simulator $1 once the screen has stopped changing, written
# to $2. A fixed wait can catch a launch half drawn, or the home screen, on
# a busy machine; two shots in a row that match mean it has settled. A
# blinking caret never matches byte for byte, so build/same-shot lets a
# thousandth of the pixels differ.
settled_shot() {
  sleep 3
  xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1
  tries=0
  while [ "$tries" -lt 15 ]; do
    sleep 2
    xcrun simctl io "$1" screenshot "$2.next.png" >/dev/null 2>&1
    if build/same-shot "$2" "$2.next.png"; then break; fi
    mv "$2.next.png" "$2"
    tries=$((tries + 1))
  done
  rm -f "$2.next.png"
}

# The app itself, never a UI test runner that `make ui-test` left beside it.
built_app() {
  find "$derived/Build/Products/$1" -maxdepth 1 -name '*.app' ! -name '*-Runner.app' | head -n 1
}

echo "screenshots: building for iOS Simulator"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
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
  echo "screenshots: $file"
  # In dark mode, where white words on the orange fill are hardest to
  # read: the iPad sidebar with Today selected, then with a question
  # waiting so its count shows on the chosen row, and the memory sheet with
  # its Done button on iPhone. scripts/check-screenshots.sh checks each.
  if [ "$kind" = iPad ]; then
    shots="today:ipad-sidebar-dark todayNeedsYou:ipad-sidebar-badge-dark"
  else
    shots="homeMemory:iphone-sheet-dark"
  fi
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  # Switching to dark can take an app launched at the same moment down with
  # it, so let it finish, and launch again if the app isn't up once the
  # screen settles.
  darkened="$darkened $udid"
  xcrun simctl ui "$udid" appearance dark
  sleep 3
  for shot in $shots; do
    scene="${shot%%:*}"; file="$out/${shot#*:}.png"
    for attempt in 1 2 3; do
      xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" -pebbleScreen "$scene" >/dev/null
      settled_shot "$udid" "$file"
      if xcrun simctl spawn "$udid" launchctl list | grep -q "$bundle_id"; then break; fi
      echo "screenshots: the app wasn't up for $file, launching again"
    done
    echo "screenshots: $file"
  done
  xcrun simctl ui "$udid" appearance light
  xcrun simctl terminate "$udid" "$bundle_id" || true
  xcrun simctl shutdown "$udid" || true
done

echo "screenshots: building for macOS"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived"
mac_app="$(built_app Debug)"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$mac_app/Contents/Info.plist")"
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac.png"
echo "screenshots: $out/mac.png"
# The memory sheet with its Done button, presented in a real window off
# screen, in light and dark.
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac-sheet.png" -pebbleScreen homeMemory -snapshotSheet YES
echo "screenshots: $out/mac-sheet.png"
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac-sheet-dark.png" -pebbleScreen homeMemory \
  -snapshotSheet YES -snapshotDark YES
echo "screenshots: $out/mac-sheet-dark.png"
