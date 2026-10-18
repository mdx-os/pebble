#!/bin/sh
# Before `make ui-test`: on each simulator named, resets the app's privacy
# choices and removes the app, so the system has never been asked about
# notifications and the nudge test meets its question. Notifications are
# not one of `simctl privacy`'s services, so removing the app is what
# resets them. Touches only the app under test, on these simulators.
#   sh scripts/ui-test-reset.sh "iPad Pro 13-inch (M5)" "iPhone 17 Pro"
set -eu

bundle_id="com.mdxos.pebble"

for name in "$@"; do
  udid="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
wanted = sys.argv[1]
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime]
match = [d["udid"] for d in devices if d["name"] == wanted]
print(match[0] if match else "")
' "$name")"
  if [ -z "$udid" ]; then
    echo "ui-test-reset: no simulator named \"$name\""
    exit 1
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl privacy "$udid" reset all "$bundle_id" 2>/dev/null || true
  xcrun simctl uninstall "$udid" "$bundle_id"
  echo "ui-test-reset: $name is ready, with the app removed"
done
