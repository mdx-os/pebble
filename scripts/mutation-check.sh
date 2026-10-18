#!/bin/sh
# Proves the behavior tests can fail. For each entry in the manifest it
# breaks the code the entry's tests claim to cover, on a copy of the repo in
# build/mutation, runs just those tests, and requires every one to FAIL.
# A test that still passes with its code broken protects nothing.
#
# The working tree is never touched: every change is made to the copy, and
# the copy's file is put back after each entry, and on any exit.
#
# Manifest entries (scripts/mutation-manifest.txt), separated by a blank line:
#   test: nameOfATest anotherTest      the test functions that must fail
#   file: Packages/PebbleKit/Sources/PebbleCore/CloudHelp.swift
#   perl: s/what the code says/what breaks it/
# The perl substitution runs over the whole file at once, so it can span
# lines with \n. It must change the file, so a stale entry fails too. An
# entry that needs several changes gives one perl: line for each, applied
# in order, and every one of them must change the file.
#
# Usage: scripts/mutation-check.sh [manifest [pattern]]
# With a pattern (or ONLY=), only entries whose test line matches it run.
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
manifest="${1:-$root/scripts/mutation-manifest.txt}"
only="${2:-${ONLY:-}}"
work="$root/build/mutation"
package="$work/Packages/PebbleKit"
results="$work/results.txt"
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

if [ ! -r "$manifest" ]; then
  echo "mutation-check: can't read $manifest"
  exit 1
fi

# A copy of everything the tests read, kept between runs so each build after
# the first only compiles what an entry changed.
mkdir -p "$package"
rsync -a --delete --exclude .build --exclude .swiftpm "$root/Packages/PebbleKit/" "$package/"
for part in scripts Config App AppUITests .github; do
  rsync -a --delete "$root/$part/" "$work/$part/"
done
for file in Makefile project.yml .gitignore; do
  cp "$root/$file" "$work/$file"
done
: > "$results"

build() {
  $swift build --package-path "$package" --build-tests --quiet </dev/null >"$work/build.log" 2>&1
}

# Runs one test on the copy. Prints passed, failed, timedout or missing. A
# test that hangs once its code is broken is stopped after $timeout
# seconds: it did not pass, but it did not plainly fail either.
run_test() {
  status=0
  out="$(bounded "$timeout" \
      $swift test --package-path "$package" --skip-build --filter "/$1\(" </dev/null 2>&1)" || status=$?
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
all_tests="$(sed -n 's/^test: //p' "$manifest" | tr ' ' '\n' | grep -v '^$' | sort -u)"
if [ -n "$only" ]; then all_tests="$(printf '%s\n' "$all_tests" | grep -E "$only" || true)"; fi
if ! build; then
  echo "mutation-check: the unbroken copy doesn't build. See $work/build.log"
  exit 1
fi
# One run for all of them; each must be found, so a misspelled name fails.
listed="$(printf '%s\n' "$all_tests" | grep -c . || true)"
if [ "$listed" -gt 0 ]; then
  alternatives="$(printf '%s\n' "$all_tests" | paste -sd '|' -)"
  status=0
  out="$(bounded "$baseline_timeout" \
      $swift test --package-path "$package" --skip-build --filter "/($alternatives)\(" </dev/null 2>&1)" || status=$?
  if [ "$status" -eq "$alarmed" ]; then
    say "mutation-check: the listed tests didn't finish in ${baseline_timeout}s before anything was broken"
    exit 1
  elif [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" | grep -E "✘" | head -20
    say "mutation-check: a listed test fails before anything is broken"
    exit 1
  fi
  for test in $all_tests; do
    if ! printf '%s\n' "$out" | grep -q "Test $test("; then
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
    say "PROBLEM: no file $file"
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
    say "PROBLEM: this change no longer applies to $file: $stale"
    problems=$((problems + 1))
    restore
    return 0
  fi
  case "$file" in
    Packages/PebbleKit/*)
      built="$(date +%s)"
      if ! build; then
        say "PROBLEM: $file doesn't build once broken by: $perl"
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
        say "killed    $test  ($file)"
        killed=$((killed + 1))
        ;;
      timedout)
        say "TIMED OUT $test after ${timeout}s with $file broken; it didn't pass, but it didn't fail either"
        timedout=$((timedout + 1))
        ;;
      passed)
        say "SURVIVED  $test still passes with $file broken by: $perl"
        problems=$((problems + 1))
        ;;
      *)
        say "PROBLEM: no test named $test"
        problems=$((problems + 1))
        ;;
    esac
  done
  restore
}

tests=""
file=""
perl=""
while IFS= read -r line || [ -n "$line" ]; do
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
      echo "mutation-check: can't read this manifest line: $line"
      exit 1
      ;;
  esac
done < "$manifest"
if [ -n "$file" ]; then run_entry; fi

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
