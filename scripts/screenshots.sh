#!/bin/sh
# Builds the app and captures its first screen on iPhone, iPad and Mac.
# Usage: scripts/screenshots.sh [output-dir]   (default: build/screenshots)
# Override simulators with PEBBLE_IPHONE / PEBBLE_IPAD (device names).
set -eu

out="${1:-build/screenshots}"
derived="build/DerivedData"
bundle_id="com.mdxos.pebble"
mkdir -p "$out" build
# The tree these screenshots show, taken before the build. Written to
# $out/STAMP once they are all made, and checked by `make verify`.
rm -f "$out/STAMP"
tree="$(sh scripts/screenshot-stamp.sh tree)"

# Simulators are shared with other worktrees, so whatever happens, one
# switched to dark goes back to the appearance it had when we found it.
# Each entry is udid:appearance.
darkened=""
restore_appearance() {
  for entry in $darkened; do
    xcrun simctl ui "${entry%%:*}" appearance "${entry#*:}" 2>/dev/null || true
  done
  darkened=""
}
# Not every sh runs the EXIT trap on a signal, so Ctrl-C and a kill restore
# too, then stop the script.
trap restore_appearance EXIT
trap 'restore_appearance; exit 130' INT
trap 'restore_appearance; exit 143' TERM

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

# settled_shot and launch_and_shoot, each of which exits 1 when it gives up.
. scripts/shot-lib.sh

# The app itself, picked by bundle id. Products also holds the UI test
# runner once `make ui-test` has run, so the first .app is not always it.
built_app() {
  for app in "$derived/Build/Products/$1"/*.app; do
    plist="$app/Info.plist"
    [ -f "$plist" ] || plist="$app/Contents/Info.plist"
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" = "$bundle_id" ]; then
      echo "$app"
      return
    fi
  done
  echo "screenshots: no app with bundle id $bundle_id in $derived/Build/Products/$1" >&2
  exit 1
}

echo "screenshots: building for iOS Simulator"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO
# `exit` inside built_app only leaves the $(...) subshell, so stop here too.
ios_app="$(built_app Debug-iphonesimulator)" || exit 1
[ -n "$ios_app" ] || { echo "screenshots: found no iOS Simulator app to install."; exit 1; }

for kind in iPhone iPad; do
  if [ "$kind" = iPhone ]; then wanted="${PEBBLE_IPHONE:-}"; else wanted="${PEBBLE_IPAD:-}"; fi
  udid="$(pick_sim "$kind" "$wanted")"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
  xcrun simctl install "$udid" "$ios_app"
  file="$out/$(echo "$kind" | tr '[:upper:]' '[:lower:]').png"
  launch_and_shoot "$udid" "$bundle_id" "$file" -showcaseStill YES
  echo "screenshots: $file"
  # Today as the Talk shortcut opens it, listening, on a sample listener
  # that never touches the microphone.
  if [ "$kind" = iPhone ]; then
    file="$out/iphone-listening.png"
    launch_and_shoot "$udid" "$bundle_id" "$file" -showcaseScreen todayListening -showcaseStill YES
    echo "screenshots: $file"
  fi
  # In dark mode, where white words on the blue fill are hardest to
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
  # What it was before, light or dark. Anything else, as from a runtime
  # that can't say, goes back to light.
  was="$(xcrun simctl ui "$udid" appearance 2>/dev/null || true)"
  case "$was" in light|dark) ;; *) was=light ;; esac
  darkened="$darkened $udid:$was"
  xcrun simctl ui "$udid" appearance dark
  sleep 3
  for shot in $shots; do
    scene="${shot%%:*}"; file="$out/${shot#*:}.png"
    launch_and_shoot "$udid" "$bundle_id" "$file" -showcaseScreen "$scene" -showcaseStill YES
    echo "screenshots: $file"
  done
  xcrun simctl ui "$udid" appearance "$was"
  darkened="${darkened% $udid:$was}"
  xcrun simctl terminate "$udid" "$bundle_id" || true
  xcrun simctl shutdown "$udid" || true
done

echo "screenshots: building for macOS"
xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived"
mac_app="$(built_app Debug)" || exit 1
[ -n "$mac_app" ] || { echo "screenshots: found no Mac app to open."; exit 1; }
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$mac_app/Contents/Info.plist")"
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac.png"
echo "screenshots: $out/mac.png"
# The memory sheet with its Done button, presented in a real window off
# screen, in light and dark.
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac-sheet.png" -showcaseScreen homeMemory -snapshotSheet YES
echo "screenshots: $out/mac-sheet.png"
"$mac_app/Contents/MacOS/$exe" -snapshotPath "$PWD/$out/mac-sheet-dark.png" -showcaseScreen homeMemory \
  -snapshotSheet YES -snapshotDark YES
echo "screenshots: $out/mac-sheet-dark.png"
sh scripts/screenshot-stamp.sh write "$out" "$tree"
