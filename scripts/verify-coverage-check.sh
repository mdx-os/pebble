#!/bin/sh
# Fails unless `make verify` builds every Release build `make build-release`
# does. verify runs only build-release-simulator, because its macOS archive
# is the same Release build for the Mac; this check keeps that true. It
# reads `make -n verify` and requires a Release build for the iOS
# Simulator, Release archives for iOS and for macOS, and a Release build or
# archive in verify for every platform `make -n build-release` builds.
# Usage: scripts/verify-coverage-check.sh [dir]   (default: the repository)
# The dir holds the Makefile to read. `make -n` prints the recipes and runs
# none of them itself, but it still starts any `$(MAKE)` sub-make, any
# recipe line marked `+` and any `$(shell ...)`, so point it only at a
# Makefile you trust.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$root}"
status=0
fail() { echo "verify-coverage-check: $*"; status=1; }

# The xcodebuild lines a target would run, one per line as "kind
# configuration platform", where kind is build or archive and platform is
# the destination's, such as "iOS Simulator" or "macOS". A missing
# -configuration is the scheme's own: Debug for build, which uses its Run
# action, and Release for archive, which uses its Archive action. A shell
# comment line is no build, and xcodebuild counts only where a command
# starts, so an echo that names it is not one either.
xcodebuilds() {
  out="$(cd "$dir" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make --no-print-directory -n "$1" 2>&1)" || {
    echo "verify-coverage-check: make -n $1 failed: $out" >&2
    return 1
  }
  printf '%s\n' "$out" | perl -0pe 's/\\\n\s*/ /g' | perl -ne '
    next if /^\s*#/;
    next unless /(?:^|[;&|(])\s*(?:\w+=\S*\s+)*xcodebuild\s+(build|archive)\b/;
    my $kind = $1;
    my $config = /-configuration\s+(\S+)/ ? $1 : ($kind eq "archive" ? "Release" : "Debug");
    while (/-destination\s+(?:\x27([^\x27]*)\x27|"([^"]*)"|(\S+))/g) {
      my $dest = $1 // $2 // $3;
      my ($platform) = $dest =~ /(?:^|,|generic\/)platform=([^,]+)/;
      print "$kind $config ", ($platform // "unknown"), "\n";
    }'
}

# The targets verify and archive reach, through prerequisites and
# `$(MAKE)` sub-makes, with an xcodebuild recipe line marked `-`, so make
# would go on as if it had built. `make -n` drops that mark, so this reads
# the Makefile itself.
ignored="$(perl -ne '
  if (/^\t/) {
    $text .= $_;
    if ($text !~ /\\\n\z/) {
      push @{$lines{$_}}, $text for @current;
      $text = "";
    }
    next;
  }
  $text = "";
  next if /^\s*(#|$)/;
  if (/^([^\s:=#][^:=#]*?)\s*:(?![=:])\s*([^;#]*)/) {
    @current = split " ", $1;
    push @{$deps{$_}}, split(" ", $2) for @current;
  } else {
    @current = ();
  }
  END {
    my @todo = ("verify", "archive");
    my %seen;
    while (defined(my $t = shift @todo)) {
      next if $seen{$t}++;
      push @todo, @{$deps{$t} || []};
      for my $line (@{$lines{$t} || []}) {
        push @todo, $1 while $line =~ /\$[({]MAKE[)}](?:\s+-\S+)*\s+([\w.-]+)/g;
        print "$t\n" if $line =~ /^\t[@+\s]*-[@+\-\s]*(?:\w+=\S*\s+)*xcodebuild\b/;
      }
    }
  }' "$dir/Makefile" | sort -u)"
for target in $ignored; do
  fail "make $target runs xcodebuild with its errors ignored (a recipe line starting with -), so a failed build would not stop verify"
done

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
