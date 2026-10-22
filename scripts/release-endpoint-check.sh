#!/bin/sh
# Fails every build that could ship while it has a cloud address. For now
# no build that could reach TestFlight or the App Store may reach a cloud
# model; a cloud address is only for Debug builds on one machine.
#
# Only one kind of build passes with an address: CONFIGURATION is Debug and
# the action is not install or archive. Everything else fails, whatever
# its configuration is called (Release, Beta, TestFlight, Profile) and
# whichever configuration an archive uses. The address itself is never
# printed: it is meant for one machine, and build logs are not.
#
# An address can come two ways: the PEBBLE_CLOUD_ENDPOINT setting, or
# written straight into the app's Info.plist under PebbleCloudEndpoint.
# The key may only be empty or pass the setting through,
# `$(PEBBLE_CLOUD_ENDPOINT)`, in any build that could ship.
#
# Two ways in:
# - The Run Script phase in project.yml runs it inside every build of the
#   app, with CONFIGURATION, ACTION, PEBBLE_CLOUD_ENDPOINT, SRCROOT and
#   INFOPLIST_FILE set by Xcode from the real settings, Cloud.local.xcconfig
#   among them. It knows it is in a build by TARGET_BUILD_DIR and
#   SCRIPT_INPUT_FILE_COUNT, which only Xcode sets for a script phase, so a
#   CONFIGURATION left in a shell never passes for one.
# - `make build-release` and CI run it on its own first. Outside a build
#   it asks xcodebuild for the app target's settings in every
#   configuration but Debug, for the project in $1 (default
#   Pebble.xcodeproj), and fails if any value it reads is an address, if
#   the Info.plist those settings name holds one, or if it can't read them.
set -eu

refuse() {
  echo "error: PEBBLE_CLOUD_ENDPOINT is set for a $1 build. The address is not shown here."
  echo "error: For now a build that could ship may not reach a cloud model."
  echo "error: Remove the address from Config/Cloud.local.xcconfig, or build Debug (not an archive) to try it."
  exit 1
}

refuse_plist() {
  echo "error: $1 gives PebbleCloudEndpoint a value of its own for a $2 build. The value is not shown here."
  echo "error: The key may only be empty or \$(PEBBLE_CLOUD_ENDPOINT); a real address goes only in Config/Cloud.local.xcconfig."
  exit 1
}

# The value with blanks taken out, so a setting of only spaces is empty.
blank() {
  [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# True when the plist at $1 gives PebbleCloudEndpoint anything but empty
# or the pass through. A key that is absent passes; a file it can't read
# fails the check, so a broken plist never reads as clean.
plist_sets_address() {
  if [ ! -r "$1" ] || ! plutil -lint -s "$1" >/dev/null 2>&1; then
    echo "release-endpoint-check: can't read $1, so it can't check it."
    exit 1
  fi
  # PlistBuddy prints a string as it is and anything else, such as a
  # dictionary, in a form that is never one of the two that pass.
  if ! key="$(/usr/libexec/PlistBuddy -c 'Print :PebbleCloudEndpoint' "$1" 2>/dev/null)"; then
    return 1
  fi
  [ -n "$key" ] && [ "$key" != '$(PEBBLE_CLOUD_ENDPOINT)' ]
}

# $1 relative to $2, unless it is already a full path.
under() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$2" "$1" ;;
  esac
}

if [ -n "${CONFIGURATION:-}" ] && [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${SCRIPT_INPUT_FILE_COUNT:-}" ]; then
  action="${ACTION:-build}"
  if [ "$CONFIGURATION" = Debug ] && [ "$action" != install ] && [ "$action" != archive ]; then
    exit 0
  fi
  blank "${PEBBLE_CLOUD_ENDPOINT:-}" || refuse "$CONFIGURATION ($action)"
  if [ -n "${INFOPLIST_FILE:-}" ]; then
    plist="$(under "$INFOPLIST_FILE" "${SRCROOT:-.}")"
    if plist_sets_address "$plist"; then refuse_plist "$INFOPLIST_FILE" "$CONFIGURATION ($action)"; fi
  fi
  exit 0
fi

project="${1:-Pebble.xcodeproj}"
target="${PEBBLE_TARGET:-Pebble}"
if ! list="$(xcodebuild -list -project "$project" 2>/dev/null)"; then
  echo "release-endpoint-check: can't read the configurations of $project, so it can't check them."
  exit 1
fi
# The names under "Build Configurations:", up to the next blank line.
configurations="$(printf '%s\n' "$list" | sed -n '/Build Configurations:/,/^[[:space:]]*$/p' | sed '1d;/^[[:space:]]*$/d;s/^[[:space:]]*//')"
if [ -z "$configurations" ]; then
  echo "release-endpoint-check: $project lists no build configurations, so it can't check them."
  exit 1
fi
checked=0
while IFS= read -r configuration; do
  [ "$configuration" = Debug ] && continue
  if ! settings="$(xcodebuild -showBuildSettings -project "$project" -target "$target" -configuration "$configuration" 2>/dev/null)"; then
    echo "release-endpoint-check: can't read the $configuration build settings of $project, so it can't check them."
    exit 1
  fi
  # Every value it finds counts, so an empty one, from another target or
  # printed first, can never hide one that is set.
  values="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*PEBBLE_CLOUD_ENDPOINT = //p')"
  blank "$values" || refuse "$configuration"
  # Every Info.plist the settings name, under the project's folder unless
  # they name it in full.
  root="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*SRCROOT = //p' | head -n 1)"
  [ -n "$root" ] || root="$(dirname "$project")"
  plists="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*INFOPLIST_FILE = //p')"
  while IFS= read -r info; do
    [ -n "$info" ] || continue
    if plist_sets_address "$(under "$info" "$root")"; then refuse_plist "$info" "$configuration"; fi
  done <<PLISTS
$plists
PLISTS
  checked=$((checked + 1))
done <<EOF
$configurations
EOF
if [ "$checked" -eq 0 ]; then
  echo "release-endpoint-check: $project has only Debug, so there is nothing that ships to check."
  exit 1
fi
echo "release-endpoint-check: ok (no cloud address in any configuration but Debug)"
