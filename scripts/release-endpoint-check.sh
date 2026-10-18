#!/bin/sh
# Fails every build that could ship while it has a cloud address. Who runs
# the server, how long it keeps what it is sent, and what sign-in sends are
# not decided yet, and the turn on question can't say what isn't decided,
# so no build that could reach TestFlight or the App Store may reach a
# cloud model.
#
# Only one kind of build passes with an address: CONFIGURATION is Debug and
# the action is not install or archive. Everything else fails, whatever
# its configuration is called (Release, Beta, TestFlight, Profile) and
# whichever configuration an archive uses. The address itself is never
# printed: it is meant for one machine, and build logs are not.
#
# Two ways in:
# - The Run Script phase in project.yml runs it inside every build of the
#   app, with CONFIGURATION, ACTION and PEBBLE_CLOUD_ENDPOINT set by Xcode
#   from the real settings, Cloud.local.xcconfig among them. It knows it is
#   in a build by TARGET_BUILD_DIR and SCRIPT_INPUT_FILE_COUNT, which only
#   Xcode sets for a script phase, so a CONFIGURATION left in a shell never
#   passes for one.
# - `make build-release` and CI run it on its own first. Outside a build
#   it asks xcodebuild for the app target's settings in every
#   configuration but Debug, for the project in $1 (default
#   Pebble.xcodeproj), and fails if any value it reads is an address, or
#   if it can't read them.
set -eu

refuse() {
  echo "error: PEBBLE_CLOUD_ENDPOINT is set for a $1 build. The address is not shown here."
  echo "error: A build that could ship can't reach a cloud model until the server's operator, how long it keeps what it is sent, and what sign-in sends are decided and written into the turn on question."
  echo "error: Remove the address from Config/Cloud.local.xcconfig, or build Debug (not an archive) to try it."
  exit 1
}

# The value with blanks taken out, so a setting of only spaces is empty.
blank() {
  [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

if [ -n "${CONFIGURATION:-}" ] && [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${SCRIPT_INPUT_FILE_COUNT:-}" ]; then
  blank "${PEBBLE_CLOUD_ENDPOINT:-}" && exit 0
  action="${ACTION:-build}"
  if [ "$CONFIGURATION" = Debug ] && [ "$action" != install ] && [ "$action" != archive ]; then
    exit 0
  fi
  refuse "$CONFIGURATION ($action)"
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
  checked=$((checked + 1))
done <<EOF
$configurations
EOF
if [ "$checked" -eq 0 ]; then
  echo "release-endpoint-check: $project has only Debug, so there is nothing that ships to check."
  exit 1
fi
echo "release-endpoint-check: ok (no cloud address in any configuration but Debug)"
