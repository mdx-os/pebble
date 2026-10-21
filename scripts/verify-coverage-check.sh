#!/bin/sh
# Fails unless `make verify` builds every Release build `make build-release`
# does. verify runs only build-release-simulator, because its macOS Release
# archive stands in for the Mac's Release build; this check keeps it there. It
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
# configuration platform", where kind is an action, such as build or
# archive, and platform is the destination's, such as "iOS Simulator" or
# "macOS". Actions may come anywhere after the options, as xcodebuild
# allows, and a line with none builds. A missing -configuration is the
# scheme's own: Release for archive, which uses its Archive action, and
# Debug for the rest (the scheme project.yml makes; nothing here reads the
# scheme to check it). A build with no -destination prints "unknown" as
# its platform. A line that only shows or exports something, such as
# -showBuildSettings, -list or -dry-run, builds nothing and prints
# nothing. A build of a scheme other than Pebble, or of a project other
# than Pebble.xcodeproj, prints "foreign" and the line, and fails.
#
# Options are read from known lists, so a value is never taken for an
# action: an option the lists don't name, a word that is neither an
# action nor NAME=value, or an action where a value should be, prints
# "unsupported", as -skipUnavailableActions would, which can skip an
# action that can't run. Add an option to its list when verify needs it.
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
    my %actions = map { $_ => 1 } qw(build build-for-testing analyze archive
      test test-without-building docbuild install installsrc clean);
    my %flags = map { $_ => 1 } qw(-quiet -verbose -json -alltargets
      -parallelizeTargets -hideShellScriptEnvironment -showBuildTimingSummary
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration
      -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
      -skipPackageUpdates -disablePackageRepositoryCache
      -skipPackagePluginValidation -skipMacroValidation
      -skipPackageSignatureValidation);
    my %valued = map { $_ => 1 } qw(-project -workspace -scheme -target
      -configuration -destination -destination-timeout -sdk -arch -xcconfig
      -toolchain -jobs -derivedDataPath -archivePath -resultBundlePath
      -resultBundleVersion -clonedSourcePackagesDirPath -packageCachePath
      -testPlan -enableCodeCoverage);
    my %modes = map { $_ => 1 } qw(-usage -help -license -version -list
      -showsdks -showdestinations -showTestPlans -showBuildSettings
      -showBuildSettingsForIndex -find-executable -find-library -exportArchive
      -exportNotarizedApp -exportLocalizations -importLocalizations
      -resolvePackageDependencies -create-xcframework -checkFirstLaunchStatus
      -runFirstLaunch -downloadAllPlatforms -downloadPlatform -importPlatform
      -downloadComponent -importComponent -deleteComponent -showComponent
      -prepareDeviceSupport -enumerate-tests -dry-run -n);
    my (@acts, @dests, %opt, $mode, $bad);
    my $config;
    for (my $k = 1; $k <= $#words; $k++) {
      my $w = $words[$k];
      if ($w =~ /^-/) {
        if ($modes{$w}) { $mode = 1 }
        elsif ($flags{$w} || $w =~ /=/) { }
        elsif ($valued{$w} && $k < $#words && !$actions{$words[$k + 1]}) {
          my $v = $words[++$k];
          if ($w eq "-configuration") { $config = $v }
          elsif ($w eq "-destination") { push @dests, $v }
          else { $opt{$w} //= $v }
        } else { $bad = 1 }
      } elsif ($w =~ /^\w+=/) {
      } elsif ($actions{$w}) {
        push @acts, $w;
      } else { $bad = 1 }
    }
    next if $mode;
    if ($bad) { print "unsupported $line\n"; next }
    @acts = ("build") unless @acts;
    @acts = grep { $_ ne "clean" && $_ ne "installsrc" } @acts;
    next unless @acts;
    if (($opt{"-scheme"} // "") ne "Pebble" || ($opt{"-project"} // "") ne "Pebble.xcodeproj"
        || exists $opt{"-workspace"} || exists $opt{"-target"}) {
      print "foreign $line\n";
      next;
    }
    for my $kind (@acts) {
      my $c = $config // ($kind eq "archive" ? "Release" : "Debug");
      print "$kind $c unknown\n" unless @dests;
      for my $dest (@dests) {
        my ($platform) = $dest =~ /(?:^|,|generic\/)platform=([^,]+)/;
        print "$kind $c ", ($platform // "unknown"), "\n";
      }
    }'
}

# Ways make could go on past a failed build, which `make -n` never shows,
# so this reads the Makefile itself. In the targets verify and archive
# reach, through prerequisites and `$(MAKE)` sub-makes: a recipe line
# marked `-`, whatever it runs, a target named in `.IGNORE` (or an
# `.IGNORE` naming none, which covers them all), and a `$(MAKE)` line that
# is more than `$(MAKE)`, a few plain flags, NAME=value words and targets,
# such as `$(MAKE) archive || true` or `$(MAKE) -i archive`, or that sets
# SHELL, MAKEFLAGS, MFLAGS or a name starting with a dot, such as
# .SHELLFLAGS. Make reads a line's -, @ and + after expanding it, so a
# recipe line there that starts with a variable other than `$(MAKE)`, as
# `$(IGN)xcodebuild` with IGN := -, fails too, and so does a prerequisite
# given through a variable, which this check can't follow. In the whole
# Makefile: MAKEFLAGS or MFLAGS given -i or --ignore-errors, or anything
# through a variable, `.ONESHELL` (one shell for a recipe, which goes on
# past a failed line), SHELL or .SHELLFLAGS set, SHELL, .SHELLFLAGS,
# MAKEFLAGS or MFLAGS set for one target, an `.IGNORE` or a rule's targets
# named through a variable, a variable named through another, an eval,
# and an include, whose file this never reads. Where it can't be sure
# what a variable holds, it fails. -k is fine: make still fails at the
# end.
problems="$(perl -e '
  local $/;
  my $all = <>;
  $all =~ s/\\\n[ \t]*/ /g;
  my (%deps, %lines, @current, %ignore, $ignoreall);
  my $ignores = sub { grep { /^--ig/ || /^-?[bBdehikLnpqrRsStvw]*i[bBdehikLnpqrRsStvw]*\z/ } @_ };
  for my $l (split /\n/, $all) {
    if ($l =~ /^\t/) {
      push @{$lines{$_}}, $l for @current;
      next;
    }
    next if $l =~ /^\s*(#|$)/;
    if ($l =~ /^\s*-?s?include\s/) {
      print "global the Makefile includes another file, which this check never reads: $l\n";
    }
    if ($l =~ /\b(?:MAKEFLAGS|MFLAGS)\b[^=]*=(.*)/ && ($ignores->(split " ", $1) || $1 =~ /\$/)) {
      print "global the Makefile sets MAKEFLAGS to ignore errors, or through a variable: $l\n";
    }
    if ($l =~ /^\s*(?:(?:export|unexport|override|private|define)\s+)*(?:SHELL|\.SHELLFLAGS)\b/) {
      print "global the Makefile sets SHELL or .SHELLFLAGS, so this check cannot tell how a failed line ends: $l\n";
    }
    if ($l =~ /^\s*(?:(?:export|unexport|override|private|define)\s+)*[^\s:=#]*\$[^\s:=#]*\s*(?:[:+?!]?=|\z)/) {
      print "global the Makefile names a variable through another variable, so this check cannot tell what it sets: $l\n";
    }
    if ($l =~ /\$[({]eval\s/) {
      print "global the Makefile uses eval, whose lines this check never reads: $l\n";
    }
    if ($l =~ /^\.ONESHELL\s*:/) {
      print "global the Makefile sets .ONESHELL, so a failed line in a recipe would not stop it\n";
    }
    if ($l =~ /^([^\s:=#][^:=#]*?)\s*:(?![=:])\s*([^;#]*)(?:;(.*))?/) {
      my ($names, $prereqs, $inline) = ($1, $2, $3);
      @current = split " ", $names;
      if ($names =~ /\$/) {
        print "global the Makefile names a rule\x27s targets through a variable, so this check cannot tell whose recipe is whose: $l\n";
      }
      if ($prereqs =~ /^(?:(?:export|unexport|override|private)\s+)*([^\s:=#]+)\s*[:+?!]?=/) {
        my $name = $1;
        if ($name =~ /^(?:SHELL|\.SHELLFLAGS|MAKEFLAGS|MFLAGS)\z/ || $name =~ /\$/) {
          print "global the Makefile sets $name for one target, so this check cannot tell how a failed line there ends: $l\n";
        }
        next;
      }
      if (grep { $_ eq ".IGNORE" } @current) {
        if ($prereqs =~ /\$/) {
          print "global the Makefile\x27s .IGNORE names its targets through a variable, so this check cannot tell which errors it ignores: $l\n";
        }
        $ignore{$_} = 1 for split " ", $prereqs;
        $ignoreall = 1 unless $prereqs =~ /\S/;
      }
      push @{$deps{$_}}, split(" ", $prereqs) for @current;
      if (defined $inline && $inline =~ /\S/) {
        push @{$lines{$_}}, "\t$inline" for @current;
      }
    } else {
      @current = ();
    }
  }
  my @todo = ("verify", "archive");
  my %seen;
  while (defined(my $t = shift @todo)) {
    next if $seen{$t}++;
    push @todo, @{$deps{$t} || []};
    print "varprereq $t\n" if grep { /\$/ } @{$deps{$t} || []};
    print "ignored $t\n" if $ignoreall || $ignore{$t};
    for my $line (@{$lines{$t} || []}) {
      my ($mark, $body) = $line =~ /^\t([\s@+-]*)(.*)/;
      print "ignored $t\n" if $mark =~ /-/;
      if ($body =~ /^\$(?!\$)/ && $body !~ /^\$[({]MAKE[)}](?:\s|\z)/) {
        print "varstart $t $body\n";
      }
      next unless $body =~ /\$[({]MAKE[)}]/;
      my ($rest) = $body =~ /^\$[({]MAKE[)}](\s.*|)\z/;
      my @words = split " ", $rest // "";
      my $plain = defined $rest && $rest !~ /[;&|()<>`#"\x27\\\$]/
        && !(grep { /^-/ && !/^-(?:s|j\d*|-silent|-no-print-directory)\z/ } @words)
        && !(grep { /^(?:SHELL|MAKEFLAGS|MFLAGS|\.[^=]*)=/ } @words)
        && !$ignores->(@words);
      print "submake $t $body\n" unless $plain;
      push @todo, grep { !/^-/ && !/=/ } @words;
    }
  }' "$dir/Makefile")"
printf '%s\n' "$problems" | sed -n 's/^global //p' | sort -u | while IFS= read -r line; do
  echo "verify-coverage-check: $line"
done
for target in $(printf '%s\n' "$problems" | sed -n 's/^ignored //p' | sort -u); do
  echo "verify-coverage-check: make $target runs a recipe line with its errors ignored (a line marked -, or a target in .IGNORE), so a failed build would not stop verify"
done
printf '%s\n' "$problems" | sed -n 's/^submake //p' | while IFS= read -r line; do
  echo "verify-coverage-check: make ${line%% *} runs a sub-make this check can't read, which could hide a failed build: ${line#* }"
  echo "verify-coverage-check: write it as \$(MAKE) and its targets alone"
done
for target in $(printf '%s\n' "$problems" | sed -n 's/^varprereq //p' | sort -u); do
  echo "verify-coverage-check: make $target names a prerequisite through a variable, so this check cannot follow it to its recipe"
done
printf '%s\n' "$problems" | sed -n 's/^varstart //p' | while IFS= read -r line; do
  echo "verify-coverage-check: make ${line%% *} runs a recipe line that starts with a variable, which could mark it - and ignore its errors: ${line#* }"
done
if printf '%s\n' "$problems" | grep -qE '^(global|ignored|submake|varprereq|varstart) '; then status=1; fi

verify="$(xcodebuilds verify)" || exit 1
release="$(xcodebuilds build-release)" || exit 1

for target in verify build-release; do
  if [ "$target" = verify ]; then lines="$verify"; else lines="$release"; fi
  printf '%s\n' "$lines" | sed -n 's/^unsupported //p' | while IFS= read -r line; do
    echo "verify-coverage-check: make $target runs xcodebuild in a line this check can't read, so it can't tell whether the build runs or in which configuration: $line"
    echo "verify-coverage-check: write it as one xcodebuild command on a recipe line of its own, with no ;, &&, ||, pipes, redirects or \$ expansions"
  done
  printf '%s\n' "$lines" | sed -n 's/^foreign //p' | while IFS= read -r line; do
    echo "verify-coverage-check: make $target runs xcodebuild on another scheme or project, so it isn't the app's build: $line"
    echo "verify-coverage-check: name -project Pebble.xcodeproj -scheme Pebble on it"
  done
  if printf '%s\n' "$lines" | grep -qE '^(unsupported|foreign) '; then status=1; fi
done

has() { printf '%s\n' "$verify" | grep -qx "$1"; }
has "build Release iOS Simulator" || fail "make verify no longer builds Release for the iOS Simulator"
has "archive Release iOS" || fail "make verify no longer archives Release for iOS"
has "archive Release macOS" || fail "make verify no longer archives Release for macOS"

# Every platform build-release builds in Release, by any action that
# builds, verify builds or archives.
platforms="$(printf '%s\n' "$release" | sed -nE 's/^(build|build-for-testing|analyze|archive|test|test-without-building|docbuild|install) Release //p' | sort -u)"
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
