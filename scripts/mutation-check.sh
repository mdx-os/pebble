#!/bin/sh
# Proves the behavior tests can fail. For each entry in the manifest it
# breaks the code the entry's tests claim to cover, on a copy of the repo in
# build/mutation, runs just those tests, and requires every one to FAIL.
# A test that still passes with its code broken protects nothing.
#
# The working tree is never touched: every change is made to the copy, and
# the copy's file is put back after each entry, and on any exit.
#
# The entries are read from scripts/mutation-manifest.txt and then every
# scripts/mutation/*.txt, one file per area, by name, as one list. New
# entries go in an area's file; the manifest only keeps the older ones.
# Entries, separated by a blank line:
#   test: nameOfATest anotherTest      the test functions that must fail
#   file: Packages/PebbleKit/Sources/PebbleCore/CloudHelp.swift
#   perl: s/what the code says/what breaks it/
# The perl substitution runs over the whole file at once, so it can span
# lines with \n. It must change the file, so a stale entry fails too. An
# entry that needs several changes gives one perl: line for each, applied
# in order, and every one of them must change the file.
#
# The tests live in two packages: PebbleKit, and Tools/GuardKit, the source
# guards' own package, which reads PebbleKit by path. Each test is found
# in the package that has it, and an entry builds and runs only the
# packages its tests are in. A broken PebbleKit file reaches GuardKit's
# tests too, since GuardKit builds the copy's PebbleKit.
#
# Usage: scripts/mutation-check.sh [manifest [pattern]]
# A manifest given (not empty) is read alone, in place of those files.
# With a pattern (or ONLY=), only entries whose test line matches it run.
# Before anything is built, scripts/mutation-manifest-check.sh fails on an
# entry shaped wrong, such as two run together by a merge.
#
# Each result line ends with the file and line of the entry it came from.
#
# A test that hangs once its code is broken is stopped and reported as
# timed out, apart from the tests that really failed. A timeout fails the
# run, since a test that would survive can't be told from one that is only
# slow, unless MUTATION_ALLOW_TIMEOUTS=1. A hang on the unbroken copy
# always fails the run. MUTATION_TIMEOUT (seconds, default 180) bounds
# each test run, and MUTATION_BASELINE_TIMEOUT (default 900) the first run
# of them all. Each run is its own process group, and a timeout stops the
# whole group, so nothing it started is left holding the build.
# MUTATION_SWIFT names the swift command, so the check itself can be
# tested with a stand-in.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="${1:-}"
only="${2:-${ONLY:-}}"
work="$root/build/mutation"
packages="${MUTATION_PACKAGES:-Packages/PebbleKit Tools/GuardKit}"
results="$work/results.txt"
# Which package each listed test is in: one "test package" line each.
where="$work/where.txt"
swift="${MUTATION_SWIFT:-swift}"
timeout="${MUTATION_TIMEOUT:-180}"
baseline_timeout="${MUTATION_BASELINE_TIMEOUT:-900}"
allow_timeouts="${MUTATION_ALLOW_TIMEOUTS:-0}"
# The exit status `bounded` gives a command it had to stop.
alarmed=142

# Runs a command, after $1 seconds, in a process group of its own. Past
# that time the whole group is stopped, the command and everything it
# started, and the status is $alarmed. Otherwise it is the command's own.
bounded() {
  perl -e '
    my $limit = shift;
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0); exit 142 };
    alarm $limit;
    waitpid($pid, 0);
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}

current=""
restore() {
  if [ -n "$current" ]; then
    cp "$root/$current" "$work/$current"
    current=""
  fi
}
trap 'restore' EXIT
trap 'restore; exit 1' INT TERM

# The files the entries are read from, one per line.
if [ -n "$manifest" ]; then
  sources="$manifest"
else
  sources="$root/scripts/mutation-manifest.txt"
  for area in "$root"/scripts/mutation/*.txt; do
    if [ -f "$area" ]; then sources="$sources
$area"; fi
  done
fi
while IFS= read -r source; do
  if [ ! -r "$source" ]; then
    echo "mutation-check: can't read $source"
    exit 1
  fi
done <<EOF
$sources
EOF
# Every entry whole, before anything is built.
printf '%s\n' "$sources" | tr '\n' '\0' | xargs -0 sh "$root/scripts/mutation-manifest-check.sh"

# A copy of everything the tests read, kept between runs so each build after
# the first only compiles what an entry changed.
for package in $packages; do
  mkdir -p "$work/$package"
  rsync -a --delete --exclude .build --exclude .swiftpm "$root/$package/" "$work/$package/"
done
for part in scripts Config App AppUITests .github docs; do
  rsync -a --delete "$root/$part/" "$work/$part/"
done
for file in Makefile project.yml .gitignore README.md AGENTS.md; do
  cp "$root/$file" "$work/$file"
done
: > "$results"

# Builds one package of the copy, or with no argument every one.
build() {
  for package in ${1:-$packages}; do
    $swift build --package-path "$work/$package" --build-tests --quiet </dev/null >"$work/build.log" 2>&1 || return 1
  done
}

# The package a listed test is in, from the first run.
package_of() {
  sed -n "s|^$1 ||p" "$where" | head -1
}

# The packages the tests in $tests are in, each once.
packages_of() {
  for test in $tests; do package_of "$test"; done | sort -u
}

# Runs one test on the copy. Prints passed, failed, timedout or missing. A
# test that hangs once its code is broken is stopped after $timeout
# seconds: it did not pass, but it did not plainly fail either.
run_test() {
  package="$(package_of "$1")"
  if [ -z "$package" ]; then
    echo missing
    return 0
  fi
  status=0
  out="$(bounded "$timeout" \
      $swift test --package-path "$work/$package" --skip-build --filter "/$1\(" </dev/null 2>&1)" || status=$?
  if printf '%s\n' "$out" | grep -q "Test run with 0 tests"; then
    echo missing
  elif [ "$status" -eq 0 ]; then
    echo passed
  elif [ "$status" -eq "$alarmed" ]; then
    echo timedout
  else
    echo failed
  fi
}

say() {
  echo "$1"
  echo "$1" >> "$results"
}

# Every listed test passes on the unbroken copy first, so a failure later
# is the change's doing.
all_tests="$(printf '%s\n' "$sources" | tr '\n' '\0' | xargs -0 sed -n 's/^test: //p' | tr ' ' '\n' | grep -v '^$' | sort -u)"
if [ -n "$only" ]; then all_tests="$(printf '%s\n' "$all_tests" | grep -E "$only" || true)"; fi
if ! build; then
  echo "mutation-check: the unbroken copy doesn't build. See $work/build.log"
  exit 1
fi
# One run for all of them in each package; each must be found, so a
# misspelled name fails, and the package it is found in is kept.
: > "$where"
listed="$(printf '%s\n' "$all_tests" | grep -c . || true)"
if [ "$listed" -gt 0 ]; then
  alternatives="$(printf '%s\n' "$all_tests" | paste -sd '|' -)"
  for package in $packages; do
    status=0
    out="$(bounded "$baseline_timeout" \
        $swift test --package-path "$work/$package" --skip-build --filter "/($alternatives)\(" </dev/null 2>&1)" \
        || status=$?
    if printf '%s\n' "$out" | grep -q "Test run with 0 tests"; then continue; fi
    if [ "$status" -eq "$alarmed" ]; then
      say "mutation-check: the listed tests in $package didn't finish in ${baseline_timeout}s before anything was broken"
      exit 1
    elif [ "$status" -ne 0 ]; then
      printf '%s\n' "$out" | grep -E "✘" | head -20
      say "mutation-check: a listed test in $package fails before anything is broken"
      exit 1
    fi
    for test in $all_tests; do
      if printf '%s\n' "$out" | grep -q "Test $test("; then echo "$test $package" >> "$where"; fi
    done
  done
  for test in $all_tests; do
    if [ -z "$(package_of "$test")" ]; then
      say "mutation-check: no test named $test"
      exit 1
    fi
  done
fi

entries=0
killed=0
timedout=0
problems=0
start="$(date +%s)"

run_entry() {
  if [ -n "$only" ] && ! printf '%s\n' "$tests" | grep -Eq "$only"; then return 0; fi
  entries=$((entries + 1))
  if [ ! -f "$work/$file" ]; then
    say "PROBLEM: no file $file  [$from]"
    problems=$((problems + 1))
    return 0
  fi
  current="$file"
  # Each change on its own, so one that no longer applies is caught even
  # when another in the same entry still does.
  stale=""
  while IFS= read -r change; do
    cp "$work/$file" "$work/before.tmp"
    perl -0pi -e "$change" "$work/$file"
    if cmp -s "$work/before.tmp" "$work/$file"; then stale="$change"; break; fi
  done <<EOF
$perl
EOF
  rm -f "$work/before.tmp"
  if [ -n "$stale" ]; then
    say "PROBLEM: this change no longer applies to $file: $stale  [$from]"
    problems=$((problems + 1))
    restore
    return 0
  fi
  case "$file" in
    Packages/*|Tools/*)
      built="$(date +%s)"
      if ! build "$(packages_of)"; then
        say "PROBLEM: $file doesn't build once broken by: $perl  [$from]"
        problems=$((problems + 1))
        restore
        return 0
      fi
      echo "  built in $(( $(date +%s) - built ))s"
      ;;
  esac
  for test in $tests; do
    outcome="$(run_test "$test")"
    case "$outcome" in
      failed)
        say "killed    $test  ($file)  [$from]"
        killed=$((killed + 1))
        ;;
      timedout)
        say "TIMED OUT $test after ${timeout}s with $file broken; it didn't pass, but it didn't fail either  [$from]"
        timedout=$((timedout + 1))
        ;;
      passed)
        say "SURVIVED  $test still passes with $file broken by: $perl  [$from]"
        problems=$((problems + 1))
        ;;
      *)
        say "PROBLEM: no test named $test  [$from]"
        problems=$((problems + 1))
        ;;
    esac
  done
  restore
}

# Runs the entries of one file in order. $from is where the entry being
# read began, as the file in the repository and its line.
from=""
read_entries() {
  name="$1"
  case "$name" in "$root"/*) name="${name#"$root"/}" ;; esac
  tests=""
  file=""
  perl=""
  number=0
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if [ -z "$tests$file$perl" ]; then first="$number"; fi
    from="$name:$first"
    case "$line" in
      "#"*) ;;
      "test: "*) tests="${line#test: }" ;;
      "file: "*) file="${line#file: }" ;;
      "perl: "*)
        if [ -n "$perl" ]; then
          perl="$perl
${line#perl: }"
        else
          perl="${line#perl: }"
        fi
        ;;
      "")
        if [ -n "$file" ]; then run_entry; fi
        tests=""
        file=""
        perl=""
        ;;
      *)
        echo "mutation-check: can't read this line in $name:$number: $line"
        exit 1
        ;;
    esac
  done < "$1"
  if [ -n "$file" ]; then run_entry; fi
}

while IFS= read -r source; do
  read_entries "$source"
done <<EOF
$sources
EOF

# The copy is back as it was, so the next run builds from where it left off.
build || true

seconds=$(( $(date +%s) - start ))
hung=""
if [ "$timedout" -ne 0 ]; then hung=", $timedout timed out instead"; fi
if [ "$problems" -ne 0 ]; then
  say "mutation-check: $problems problem(s) in $entries entries, $killed tests failed as they should$hung, ${seconds}s"
  exit 1
fi
if [ "$timedout" -ne 0 ] && [ "$allow_timeouts" != 1 ]; then
  say "mutation-check: $timedout test(s) timed out in $entries entries, $killed tests failed$hung, ${seconds}s. Run it again on a quiet machine, or with MUTATION_ALLOW_TIMEOUTS=1 to let them by"
  exit 1
fi
say "mutation-check: ok, $entries entries broke their code, $killed tests failed$hung, ${seconds}s"
