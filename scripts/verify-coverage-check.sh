#!/bin/sh
# Fails unless `make verify` builds every Release build `make build-release`
# does. verify runs only build-release-simulator, because its macOS archive
# is the same Release build for the Mac; this check keeps that true. It
# reads `make -n verify` and requires a Release build for the iOS
# Simulator, Release archives for iOS and for macOS, and a Release build or
# archive in verify for every platform `make -n build-release` builds.
# Usage: scripts/verify-coverage-check.sh [dir]   (default: the repository)
# The dir holds the Makefile to read; nothing in it is run.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$root}"
status=0
fail() { echo "verify-coverage-check: $*"; status=1; }

# The xcodebuild lines a target would run, one per line as "kind
# configuration platform", where kind is build or archive and platform is
# the destination's, such as "iOS Simulator" or "macOS". A missing
# -configuration is Debug, as xcodebuild takes it for this scheme.
xcodebuilds() {
  out="$(cd "$dir" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make --no-print-directory -n "$1" 2>&1)" || {
    echo "verify-coverage-check: make -n $1 failed: $out" >&2
    return 1
  }
  printf '%s\n' "$out" | perl -0pe 's/\\\n\s*/ /g' | perl -ne '
    next unless /\bxcodebuild\s+(build|archive)\b/;
    my $kind = $1;
    my $config = /-configuration\s+(\S+)/ ? $1 : "Debug";
    while (/-destination\s+(?:\x27([^\x27]*)\x27|"([^"]*)"|(\S+))/g) {
      my $dest = $1 // $2 // $3;
      my ($platform) = $dest =~ /(?:^|,|generic\/)platform=([^,]+)/;
      print "$kind $config ", ($platform // "unknown"), "\n";
    }'
}

verify="$(xcodebuilds verify)" || exit 1
release="$(xcodebuilds build-release)" || exit 1

has() { printf '%s\n' "$verify" | grep -qx "$1"; }
has "build Release iOS Simulator" || fail "make verify no longer builds Release for the iOS Simulator"
has "archive Release iOS" || fail "make verify no longer archives Release for iOS"
has "archive Release macOS" || fail "make verify no longer archives Release for macOS"

# Every platform build-release builds in Release, verify builds or archives.
platforms="$(printf '%s\n' "$release" | sed -n 's/^build Release //p' | sort -u)"
if [ -z "$platforms" ]; then
  fail "make build-release builds nothing in Release, so there is nothing to compare"
fi
while IFS= read -r platform; do
  [ -n "$platform" ] || continue
  if ! has "build Release $platform" && ! has "archive Release $platform"; then
    fail "make build-release builds Release for $platform, but make verify neither builds nor archives it"
  fi
done <<EOF
$platforms
EOF

if [ "$status" -eq 0 ]; then
  echo "verify-coverage-check: ok, verify covers Release for $(printf '%s\n' "$platforms" | paste -sd ',' - | sed 's/,/, /g')"
fi
exit "$status"
