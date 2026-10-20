#!/bin/sh
# Self-test for scripts/verify-coverage-check.sh, on copies of the real
# Makefile in build/verify-coverage-check-test. The Makefile as it is
# passes; then each way verify could stop covering a Release build must
# fail the check, for that reason: archive dropped from verify, the
# simulator build dropped, either archive gone or no longer Release, and a
# new Release build in build-release that verify never makes.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/verify-coverage-check.sh"
scratch="$root/build/verify-coverage-check-test"
failures=0

fresh() {
  rm -rf "$scratch"
  mkdir -p "$scratch"
  cp "$root/Makefile" "$scratch/Makefile"
}

# Changes the scratch Makefile with the perl substitution $1, which must
# change it, so a stale case fails rather than passing unchanged.
change() {
  cp "$scratch/Makefile" "$scratch/before"
  perl -0pi -e "$1" "$scratch/Makefile"
  if cmp -s "$scratch/before" "$scratch/Makefile"; then
    echo "verify-coverage-check-test: FAILED, this change no longer applies to the Makefile: $1"
    failures=$((failures + 1))
  fi
}

# Runs the check on the scratch Makefile. $1 is pass or fail, $2 what the
# Makefile shows, and $3, for a failure, words the check must give.
expect() {
  want="$1"
  what="$2"
  reason="${3:-}"
  status=0
  out="$(sh "$check" "$scratch" 2>&1)" || status=$?
  if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
    echo "verify-coverage-check-test: FAILED, $what should pass:"
    printf '%s\n' "$out"
    failures=$((failures + 1))
  elif [ "$want" = fail ] && [ "$status" -eq 0 ]; then
    echo "verify-coverage-check-test: FAILED, $what should fail, but the check said: $out"
    failures=$((failures + 1))
  elif [ "$want" = fail ] && ! printf '%s\n' "$out" | grep -qF "$reason"; then
    echo "verify-coverage-check-test: FAILED, $what failed, but not because the check saw it:"
    printf '%s\n' "$out"
    failures=$((failures + 1))
  else
    echo "verify-coverage-check-test: ok, $what: $want"
  fi
}

verify_line='(\nverify:[^\n]*?)'

fresh
expect pass "the Makefile as it is"

fresh
change "s~$verify_line archive\b~\$1~"
expect fail "archive dropped from verify" "make verify no longer archives Release for macOS"

fresh
change "s~$verify_line build-release-simulator\b~\$1~"
expect fail "build-release-simulator dropped from verify" "make verify no longer builds Release for the iOS Simulator"

fresh
change "s~\t+xcodebuild archive [^\n]*\\\\\n[^\n]*'generic/platform=macOS'[^\n]*\\\\\n[^\n]*\n~~"
expect fail "the macOS archive gone" "make build-release builds Release for macOS, but make verify neither builds nor archives it"

fresh
change "s~(xcodebuild archive [^\n]*)-configuration Release([^\n]*\\\\\n[^\n]*'generic/platform=iOS')~\$1-configuration Debug\$2~"
expect fail "the iOS archive in Debug" "make verify no longer archives Release for iOS"

fresh
change "s~(\nbuild-release:[^\n]*\n)~\$1\txcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -destination 'generic/platform=visionOS Simulator'\n~"
expect fail "a new Release build verify never makes" "make build-release builds Release for visionOS Simulator, but make verify neither builds nor archives it"

rm -rf "$scratch"
if [ "$failures" -ne 0 ]; then
  echo "verify-coverage-check-test: $failures case(s) went the wrong way"
  exit 1
fi
echo "verify-coverage-check-test: ok"
