#!/bin/sh
# Fails every build that could ship with a cloud address, unless it names
# the cloud policy the app shows and the address is plain https. The turn
# on question, the cloud setting and the preview say who runs the server,
# what it keeps and what sign-in sends, from CloudPolicy in PebbleCore, so
# a build that could reach TestFlight or the App Store may reach a cloud
# model only when its settings say it was checked against those words.
#
# A Debug build that is not an archive passes with any address, as before.
# Every other build with an address passes only when all of these hold:
# - PEBBLE_CLOUD_POLICY (Config/Cloud.xcconfig) equals the
#   CloudPolicy.currentVersion line in
#   Packages/PebbleKit/Sources/PebbleCore/CloudPolicy.swift;
# - the address starts with https:// and has a host, and no space, user
#   name, password, query or fragment.
# An empty address always passes: the cloud can't be turned on. Anything
# else fails, with a line saying what to fix. The address itself is never
# printed: it is meant for one machine, and build logs are not.
#
# Every build that could ship, with an address or without, must also sign
# in with Apple only: PEBBLE_SIGN_IN equal to `apple`, and no staging test
# sign-in pass reaching the app (PEBBLE_STAGING_SIGN_IN_PASS_FOR_APP
# empty). The staging test sign-in is for Debug builds that aren't
# archives. The pass is never printed either.
#
# Two ways in:
# - The Run Script phase in project.yml runs it inside every build of the
#   app, with CONFIGURATION, ACTION, PEBBLE_CLOUD_ENDPOINT and
#   PEBBLE_CLOUD_POLICY set by Xcode from the real settings,
#   Cloud.local.xcconfig among them. It knows it is in a build by
#   TARGET_BUILD_DIR and SCRIPT_INPUT_FILE_COUNT, which only Xcode sets for
#   a script phase, so a CONFIGURATION left in a shell never passes for one.
# - `make build-release` and CI run it on its own first. Outside a build
#   it asks xcodebuild for the app target's settings in every
#   configuration but Debug, for the project in $1 (default
#   Pebble.xcodeproj), and checks each the same way, or fails if it can't
#   read them.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
policy_source="$root/Packages/PebbleKit/Sources/PebbleCore/CloudPolicy.swift"

# $1 the build, $2 what is wrong, $3 how to fix it.
refuse() {
  echo "error: PEBBLE_CLOUD_ENDPOINT is set for a $1 build. The address is not shown here."
  echo "error: $2"
  echo "error: $3 Or remove the address from Config/Cloud.local.xcconfig, or build Debug (not an archive) to try it."
  exit 1
}

# The value with blanks taken out, so a setting of only spaces is empty.
blank() {
  [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

# The one policy version the app's words describe.
expected_policy() {
  if [ ! -r "$policy_source" ]; then
    echo "release-endpoint-check: can't read $policy_source, so it can't tell which policy the app shows." >&2
    exit 1
  fi
  found="$(sed -n 's/^[[:space:]]*public static let currentVersion = "\([A-Za-z0-9._-]*\)"[[:space:]]*$/\1/p' "$policy_source")"
  if [ -z "$found" ] || [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" != 1 ]; then
    echo "release-endpoint-check: CloudPolicy.swift has no single currentVersion line, so it can't tell which policy the app shows." >&2
    exit 1
  fi
  printf '%s' "$found"
}

# Passes a build that could ship with address $2 and policy $3, or fails
# it. $1 names the build.
check_shipping() {
  expected="$(expected_policy)"
  policy="$(printf '%s' "$3" | tr -d '[:space:]')"
  if [ -z "$policy" ]; then
    refuse "$1" "PEBBLE_CLOUD_POLICY is not set, so nothing says this build shows the words of the service it reaches." \
      "Set PEBBLE_CLOUD_POLICY = $expected in Config/Cloud.xcconfig, the policy the app shows (CloudPolicy.currentVersion)."
  fi
  if [ "$policy" != "$expected" ]; then
    refuse "$1" "The cloud policy changed: PEBBLE_CLOUD_POLICY is $policy, but the app shows the $expected policy." \
      "Set PEBBLE_CLOUD_POLICY = $expected, or change CloudPolicy and docs/CLOUD.md to the new policy first."
  fi
  address="$(printf '%s' "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  plain="Write it as https:// and a host, with no space, user name, password, query (?) or fragment (#)."
  case "$address" in
    https://*) ;;
    *) refuse "$1" "The address isn't https." "$plain" ;;
  esac
  case "$address" in
    *[[:space:]?#@]*) refuse "$1" "The address isn't a plain https address." "$plain" ;;
  esac
  rest="${address#https://}"
  if [ -z "${rest%%/*}" ]; then
    refuse "$1" "The address has no host." "$plain"
  fi
}

# Passes a build that could ship only when it signs in with Apple, with
# PEBBLE_SIGN_IN $2, and no staging pass $3 reaches the app. $1 names the
# build. Neither value is printed.
check_sign_in() {
  if [ "$(printf '%s' "$2" | tr -d '[:space:]')" != apple ]; then
    echo "error: PEBBLE_SIGN_IN isn't apple for a $1 build, which could ship. A build that could ship signs in with Apple only."
    echo "error: Set PEBBLE_SIGN_IN = apple in Config/Cloud.xcconfig. The staging test sign-in is for Debug builds only: set PEBBLE_SIGN_IN[config=Debug] = staging in Config/Cloud.local.xcconfig, and build Debug (not an archive) to try it."
    exit 1
  fi
  if ! blank "$3"; then
    echo "error: The staging test sign-in's pass reaches a $1 build, which could ship. The pass is not shown here."
    echo "error: Set it only as PEBBLE_STAGING_SIGN_IN_PASS in Config/Cloud.local.xcconfig, which passes it to Debug builds only."
    exit 1
  fi
}

if [ -n "${CONFIGURATION:-}" ] && [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${SCRIPT_INPUT_FILE_COUNT:-}" ]; then
  action="${ACTION:-build}"
  if [ "$CONFIGURATION" = Debug ] && [ "$action" != install ] && [ "$action" != archive ]; then
    exit 0
  fi
  check_sign_in "$CONFIGURATION ($action)" "${PEBBLE_SIGN_IN:-}" "${PEBBLE_STAGING_SIGN_IN_PASS_FOR_APP:-}"
  blank "${PEBBLE_CLOUD_ENDPOINT:-}" && exit 0
  check_shipping "$CONFIGURATION ($action)" "$PEBBLE_CLOUD_ENDPOINT" "${PEBBLE_CLOUD_POLICY:-}"
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
  # Sign in with Apple only, read the same way: settings that disagree
  # fail, and so does a pass that would reach the app.
  sign_ins="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*PEBBLE_SIGN_IN = //p' | sort -u)"
  if [ "$(printf '%s\n' "$sign_ins" | wc -l | tr -d ' ')" != 1 ]; then
    echo "error: The $configuration build settings disagree about PEBBLE_SIGN_IN. Set it in Config/Cloud.xcconfig only."
    exit 1
  fi
  passes="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*PEBBLE_STAGING_SIGN_IN_PASS_FOR_APP = //p')"
  check_sign_in "$configuration" "$sign_ins" "$passes"
  # Every value it finds counts, so an empty one, from another target or
  # printed first, can never hide one that is set.
  values="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*PEBBLE_CLOUD_ENDPOINT = //p')"
  if ! blank "$values"; then
    # Settings that disagree, as two targets with their own would, fail
    # rather than trusting either one.
    if [ "$(printf '%s\n' "$values" | sort -u | wc -l | tr -d ' ')" != 1 ]; then
      refuse "$configuration" "The build settings disagree about the address." "Set it in one place only."
    fi
    policies="$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*PEBBLE_CLOUD_POLICY = //p' | sort -u)"
    if [ "$(printf '%s\n' "$policies" | wc -l | tr -d ' ')" != 1 ]; then
      refuse "$configuration" "The build settings disagree about PEBBLE_CLOUD_POLICY." "Set it in Config/Cloud.xcconfig only."
    fi
    check_shipping "$configuration" "$values" "$policies"
  fi
  checked=$((checked + 1))
done <<EOF
$configurations
EOF
if [ "$checked" -eq 0 ]; then
  echo "release-endpoint-check: $project has only Debug, so there is nothing that ships to check."
  exit 1
fi
echo "release-endpoint-check: ok (every configuration but Debug signs in with Apple only, and has no cloud address, or the current cloud policy and a plain https one)"
