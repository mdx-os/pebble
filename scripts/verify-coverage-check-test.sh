#!/bin/sh
# Self-test for scripts/verify-coverage-check.sh, on copies of the real
# Makefile in build/verify-coverage-check-test. The Makefile as it is
# passes; then each way verify could stop covering a Release build must
# fail the check, for that reason: archive dropped from verify, the
# simulator build dropped, either archive gone or no longer Release, a
# new Release build in build-release that verify never makes, the macOS
# archive commented out, an xcodebuild line with its errors ignored, the
# macOS archive only echoed, skipped by `true ||`, followed by `|| true`,
# joined in Debug to the iOS one by &&, given a second -configuration or
# a shell variable, and a new Release build with no -destination. An
# archive with no -configuration still passes, as it archives in
# Release, and so does an echo that names an archive beside the real ones.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/verify-coverage-check.sh"
scratch="$root/build/verify-coverage-check-test"
trap 'rm -rf "$scratch"' EXIT
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

fresh
change "s~(\t+)(xcodebuild archive [^\n]*\\\\\n)(\t+)([^\n]*'generic/platform=macOS'[^\n]*\\\\\n)(\t+)~\$1# \$2\$3# \$4\$5# ~"
expect fail "the macOS archive commented out" "make verify no longer archives Release for macOS"

fresh
change "s~(xcodebuild archive [^\n]*) -configuration Release([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\$1\$2~"
expect pass "the macOS archive with no -configuration, which archives in Release"

fresh
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t-xcodebuild archive \$1~"
expect fail "the macOS archive with its errors ignored" "make archive runs xcodebuild with its errors ignored"

macos_archive="\t+xcodebuild archive [^\n]*\\\\\n[^\n]*'generic/platform=macOS'[^\n]*\\\\\n[^\n]*"
cant_read="make verify runs xcodebuild in a line this check can't read"

fresh
change "s~$macos_archive\n~\techo \"Skipping (xcodebuild archive -configuration Release -destination 'generic/platform=macOS')\"\n~"
expect fail "the macOS archive only echoed" "make verify no longer archives Release for macOS"

fresh
change "s~(\narchive:[^\n]*\n)~\$1\techo \"xcodebuild archive -configuration Debug -destination 'generic/platform=macOS'\"\n~"
expect pass "an echo that names an archive beside the real ones"

fresh
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\ttrue || xcodebuild archive \$1~"
expect fail "the macOS archive skipped by true ||" "$cant_read"

fresh
change "s~($macos_archive)\n~\$1 || true\n~"
expect fail "the macOS archive with || true after it" "$cant_read"

fresh
change "s~(CODE_SIGNING_ALLOWED=NO)\n\txcodebuild archive ([^\n]*)-configuration Release([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\$1 && xcodebuild archive \$2-configuration Debug\$3~"
expect fail "a Debug macOS archive joined to the iOS one by &&" "$cant_read"

fresh
change "s~(xcodebuild archive [^\n]*-configuration Release)([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\$1 -configuration Debug\$2~"
expect fail "the macOS archive with a second -configuration" "$cant_read"

fresh
change "s~(xcodebuild archive [^\n]*-configuration Release)([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\$1 \\\$\\\$EXTRA\$2~"
expect fail "the macOS archive with a shell variable in its arguments" "$cant_read"

fresh
change "s~(\nbuild-release:[^\n]*\n)~\$1\txcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -sdk macosx\n~"
expect fail "a new Release build with no -destination" "make build-release builds Release with no -destination"
if [ "$failures" -ne 0 ]; then
  echo "verify-coverage-check-test: $failures case(s) went the wrong way"
  exit 1
fi
echo "verify-coverage-check-test: ok"
