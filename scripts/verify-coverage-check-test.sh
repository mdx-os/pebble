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
# a shell variable, and a new Release build with no -destination. Errors
# ignored any other way fail too: .IGNORE naming archive or naming none,
# -$(MAKE) archive, $(MAKE) archive || true, $(MAKE) -i archive,
# MAKEFLAGS += -i, -/usr/bin/xcodebuild, -$(XB) with XB := xcodebuild,
# .ONESHELL, SHELL set, and an include this check can't read, and so do
# SHELL, .SHELLFLAGS, MAKEFLAGS or MFLAGS set for archive alone or on a
# $(MAKE) archive line, $(IGN)xcodebuild and @${IGN}xcodebuild with
# IGN := -, .IGNORE naming archive through a variable, and a prerequisite
# of verify given through a variable whose recipe ignores errors, an
# .IGNORE or an archive rule written after spaces, a double-colon rule
# with its errors ignored, and a .RECIPEPREFIX. So do a new
# Release build with its action after the options or with none, the macOS
# archive turned into -showBuildSettings, given an option the check
# doesn't know, or of another scheme. An archive with no -configuration
# still passes, as it archives in Release, and so do the macOS archive
# with its action last and an echo that names an archive beside the real
# ones.
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
expect fail "the macOS archive with its errors ignored" "make archive runs a recipe line with its errors ignored"

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

ignored_errors="with its errors ignored"
drop_archive="s~$verify_line archive\b~\$1~"

fresh
change "s~(\n\.PHONY:)~\n.IGNORE: archive\$1~"
expect fail "archive named in .IGNORE" "$ignored_errors"

fresh
change "s~(\n\.PHONY:)~\n.IGNORE:\$1~"
expect fail "an .IGNORE that names no target, so it covers them all" "$ignored_errors"

fresh
change "$drop_archive"
change "s~(\n\t\\\$\(MAKE\) graph-check\n)~\$1\t-\\\$(MAKE) archive\n~"
expect fail "archive run as -\$(MAKE) archive" "make verify runs a recipe line with its errors ignored"

fresh
change "$drop_archive"
change "s~(\n\t\\\$\(MAKE\) graph-check\n)~\$1\t\\\$(MAKE) archive || true\n~"
expect fail "archive run as \$(MAKE) archive || true" "make verify runs a sub-make this check can't read"

fresh
change "$drop_archive"
change "s~(\n\t\\\$\(MAKE\) graph-check\n)~\$1\t\\\$(MAKE) -i archive\n~"
expect fail "archive run as \$(MAKE) -i archive" "make verify runs a sub-make this check can't read"

fresh
change "s~(\n\.PHONY:)~\nMAKEFLAGS += -i\$1~"
expect fail "MAKEFLAGS += -i" "the Makefile sets MAKEFLAGS to ignore errors"

fresh
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t-/usr/bin/xcodebuild archive \$1~"
expect fail "the macOS archive run as -/usr/bin/xcodebuild" "make archive runs a recipe line with its errors ignored"

fresh
change "s~(\n\.PHONY:)~\nXB := xcodebuild\$1~"
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t-\\\$(XB) archive \$1~"
expect fail "the macOS archive run as -\$(XB) with XB := xcodebuild" "make archive runs a recipe line with its errors ignored"

fresh
change "s~(\n\.PHONY:)~\n.ONESHELL:\$1~"
expect fail ".ONESHELL, which lets a failed line go on" "the Makefile sets .ONESHELL"

fresh
change "s~(\n\.PHONY:)~\nSHELL := /usr/bin/true\$1~"
expect fail "SHELL set to a command that runs nothing" "the Makefile sets SHELL"

fresh
change "s~(\n\.PHONY:)~\n-include local.mk\$1~"
expect fail "an included Makefile this check never reads" "the Makefile includes another file"

fresh
change "s~(\nbuild-release:[^\n]*\n)~\$1\txcodebuild -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -destination 'generic/platform=visionOS Simulator' build\n~"
expect fail "a new Release build with its action after the options" "make build-release builds Release for visionOS Simulator, but make verify neither builds nor archives it"

fresh
change "s~(\nbuild-release:[^\n]*\n)~\$1\txcodebuild -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -destination 'generic/platform=visionOS Simulator'\n~"
expect fail "a new Release build with no action, which builds" "make build-release builds Release for visionOS Simulator, but make verify neither builds nor archives it"

fresh
change "s~\txcodebuild archive (-quiet [^\n]*\\\\\n[^\n]*'generic/platform=macOS'[^\n]*\\\\\n[^\n]*CODE_SIGNING_ALLOWED=NO)\n~\txcodebuild \$1 archive\n~"
expect pass "the macOS archive with its action last"

fresh
change "s~\txcodebuild archive (-quiet [^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\txcodebuild -showBuildSettings \$1~"
expect fail "the macOS archive turned into -showBuildSettings, which builds nothing" "make verify no longer archives Release for macOS"

fresh
change "s~\txcodebuild archive (-quiet [^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\txcodebuild archive -skipUnavailableActions \$1~"
expect fail "the macOS archive with an option this check doesn't know" "$cant_read"

fresh
change "s~(xcodebuild archive [^\n]*-scheme )Pebble([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\$1Other\$2~"
expect fail "the macOS archive of another scheme" "make verify runs xcodebuild on another scheme or project"

for name in SHELL .SHELLFLAGS MAKEFLAGS MFLAGS; do
  case "$name" in
    SHELL) value=/usr/bin/true ;;
    .SHELLFLAGS) value=-c ;;
    *) value=-i ;;
  esac

  fresh
  change "s~(\n\.PHONY:)~\narchive: $name := $value\$1~"
  expect fail "$name set for archive alone" "for one target"

  fresh
  change "$drop_archive"
  change "s~(\n\t\\\$\(MAKE\) graph-check\n)~\$1\t\\\$(MAKE) archive $name=$value\n~"
  expect fail "archive run as \$(MAKE) archive $name=$value" "make verify runs a sub-make this check can't read"
done

fresh
change "s~(\n\.PHONY:)~\nIGN := -\$1~"
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t\\\$(IGN)xcodebuild archive \$1~"
expect fail "the macOS archive run as \$(IGN)xcodebuild with IGN := -" "make archive runs a recipe line that starts with a variable"

fresh
change "s~(\n\.PHONY:)~\nIGN := -\$1~"
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t@\\\${IGN}xcodebuild archive \$1~"
expect fail "the macOS archive run as @\${IGN}xcodebuild with IGN := -" "make archive runs a recipe line that starts with a variable"

fresh
change "s~(\n\.PHONY:)~\nIGNORED_TARGETS := archive\n.IGNORE: \\\$(IGNORED_TARGETS)\$1~"
expect fail ".IGNORE naming archive through \$(IGNORED_TARGETS)" "names its targets through a variable"

fresh
change "s~(\n\.PHONY:)~\nIGNORED_TARGETS := archive\n.IGNORE: \\\${IGNORED_TARGETS}\$1~"
expect fail ".IGNORE naming archive through \${IGNORED_TARGETS}" "names its targets through a variable"

fresh
change "s~$verify_line build-release-simulator\b~\$1~"
change "s~(\n\.PHONY:)~\nSIMULATOR := build-release-simulator\$1~"
change "s~($verify_line)\n~\$1 \\\$(SIMULATOR)\n~"
change "s~(\nbuild-release-simulator:[^\n]*\n\t)xcodebuild~\$1-xcodebuild~"
expect fail "build-release-simulator reached only through \$(SIMULATOR), with its errors ignored" "make verify names a prerequisite through a variable"

fresh
change "s~(\n\.PHONY:)~\n  .IGNORE: archive\$1~"
expect fail "archive named in an .IGNORE written after spaces" "$ignored_errors"

fresh
change "s~\narchive:~\n  archive:~"
change "s~\txcodebuild archive ([^\n]*\\\\\n[^\n]*'generic/platform=macOS')~\t-xcodebuild archive \$1~"
expect fail "an archive rule written after spaces, with its errors ignored" "make archive runs a recipe line with its errors ignored"

fresh
change "s~\nbuild-release-simulator:~\nbuild-release-simulator::~"
change "s~(\nbuild-release-simulator::[^\n]*\n\t)xcodebuild~\$1-xcodebuild~"
expect fail "build-release-simulator as a double-colon rule with its errors ignored" "make build-release-simulator runs a recipe line with its errors ignored"

fresh
change "s~(\n\.PHONY:)~\n.RECIPEPREFIX := >\$1~"
expect fail ".RECIPEPREFIX set, which make 3.82 and later read as a new recipe prefix" "the Makefile sets .RECIPEPREFIX"

if [ "$failures" -ne 0 ]; then
  echo "verify-coverage-check-test: $failures case(s) went the wrong way"
  exit 1
fi
echo "verify-coverage-check-test: ok"
