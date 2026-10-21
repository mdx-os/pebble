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
# action, and Release for archive, which uses its Archive action (the
# scheme project.yml makes; nothing here reads the scheme to check it).
# A build with no -destination prints "unknown" as its platform.
#
# Each line is read in shell words, with quotes, so a quoted xcodebuild,
# as in an echo, is no build, and a shell comment is none either. An
# xcodebuild must be the line's one command: only NAME=value words may
# come before it, it may come once, and the line may hold no ;, &, |,
# parentheses, redirects, $ or backquotes outside single quotes, nor more
# than one -configuration. Anything else, such as `true || xcodebuild`,
# `xcodebuild ... || true` or two archives joined by &&, could skip the
# build, ignore its errors or take another's configuration, so it prints
# "unsupported" and the line, and the check fails on it.
xcodebuilds() {
  out="$(cd "$dir" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make --no-print-directory -n "$1" 2>&1)" || {
    echo "verify-coverage-check: make -n $1 failed: $out" >&2
    return 1
  }
  printf '%s\n' "$out" | perl -0pe 's/\\\n\s*/ /g' | perl -ne '
    chomp;
    my $line = $_;
    my (@words, $word, $inword, $odd);
    my $end = sub { push @words, $word if $inword; $word = ""; $inword = 0 };
    $word = "";
    my $i = 0;
    while ($i < length $line) {
      my $c = substr $line, $i, 1;
      if ($c eq "\x27") {
        my $j = index $line, "\x27", $i + 1;
        if ($j < 0) { $odd = 1; last }
        $word .= substr $line, $i + 1, $j - $i - 1;
        $inword = 1;
        $i = $j + 1;
      } elsif ($c eq "\"") {
        my $j = $i + 1;
        while ($j < length $line && substr($line, $j, 1) ne "\"") {
          my $d = substr $line, $j, 1;
          $odd = 1 if $d eq "\$" || $d eq "`";
          $j++ if $d eq "\\";
          $word .= substr $line, $j, 1;
          $j++;
        }
        if ($j >= length $line) { $odd = 1; last }
        $inword = 1;
        $i = $j + 1;
      } elsif ($c eq "\\") {
        $word .= substr $line, $i + 1, 1;
        $inword = 1;
        $i += 2;
      } elsif ($c =~ /\s/) {
        $end->();
        $i++;
      } elsif ($c eq "#" && !$inword) {
        last;
      } elsif ($c =~ /[;&|()<>`\$]/) {
        $end->();
        $odd = 1;
        $i++;
      } else {
        $word .= $c;
        $inword = 1;
        $i++;
      }
    }
    $end->();
    my $mentions = grep { m{(?:^|/)xcodebuild\z} } @words;
    next unless $mentions;
    shift @words while @words && $words[0] =~ /^\w+=/;
    my $configs = grep { $_ eq "-configuration" } @words;
    if ($odd || $mentions > 1 || $configs > 1 || $words[0] !~ m{(?:^|/)xcodebuild\z}) {
      print "unsupported $line\n";
      next;
    }
    my $kind = $words[1] // "";
    next unless $kind eq "build" || $kind eq "archive";
    my $config = $kind eq "archive" ? "Release" : "Debug";
    my @dests;
    for my $k (0 .. $#words) {
      $config = $words[$k + 1] // "" if $words[$k] eq "-configuration";
      push @dests, $words[$k + 1] // "" if $words[$k] eq "-destination";
    }
    print "$kind $config unknown\n" unless @dests;
    for my $dest (@dests) {
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

for target in verify build-release; do
  if [ "$target" = verify ]; then lines="$verify"; else lines="$release"; fi
  printf '%s\n' "$lines" | sed -n 's/^unsupported //p' | while IFS= read -r line; do
    echo "verify-coverage-check: make $target runs xcodebuild in a line this check can't read, so it can't tell whether the build runs or in which configuration: $line"
    echo "verify-coverage-check: write it as one xcodebuild command on a recipe line of its own, with no ;, &&, ||, pipes, redirects or \$ expansions"
  done
  if printf '%s\n' "$lines" | grep -q '^unsupported '; then status=1; fi
done

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
  if [ "$platform" = unknown ]; then
    fail "make build-release builds Release with no -destination naming a platform, so this check can't tell which platform verify must cover"
  elif ! has "build Release $platform" && ! has "archive Release $platform"; then
    fail "make build-release builds Release for $platform, but make verify neither builds nor archives it"
  fi
done <<EOF
$platforms
EOF

if [ "$status" -eq 0 ]; then
  echo "verify-coverage-check: ok, verify covers Release for $(printf '%s\n' "$platforms" | paste -sd ',' - | sed 's/,/, /g')"
fi
exit "$status"
