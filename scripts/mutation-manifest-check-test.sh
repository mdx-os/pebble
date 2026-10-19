#!/bin/sh
# Self-test for scripts/mutation-manifest-check.sh, in a scratch tree under
# build/mutation-manifest-check-test. Good entries pass, comments and all;
# then each way an entry can be shaped wrong, such as by a merge that kept
# both sides of a file's tail, must fail the check on its own.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/mutation-manifest-check.sh"
scratch="$root/build/mutation-manifest-check-test"
failures=0

rm -rf "$scratch"
mkdir -p "$scratch/Sources"
printf 'let here = 1\n' > "$scratch/Sources/Here.swift"

good='# A comment of its own is not an entry.

test: aTest anotherTest
file: Sources/Here.swift
perl: s~here~there~

# Two changes to one file.
test: aTest
file: Sources/Here.swift
perl: s~let~var~
perl: s~1~2~'

# Runs the check on one area file holding $2, and expects $1 (pass or fail).
expect() {
  printf '%s\n' "$2" > "$scratch/area.txt"
  status=0
  out="$(MUTATION_ROOT="$scratch" sh "$check" "$scratch/area.txt" 2>&1)" || status=$?
  if [ "$1" = pass ] && [ "$status" -ne 0 ]; then
    echo "FAIL: $3 should pass:"
    printf '%s\n' "$out"
    failures=$((failures + 1))
  elif [ "$1" = fail ] && [ "$status" -eq 0 ]; then
    echo "FAIL: $3 should fail, but the check passed"
    failures=$((failures + 1))
  else
    echo "ok: $3"
  fi
}

expect pass "$good" "good entries"
expect pass "$good
" "good entries with a blank line at the end"
expect fail "$good

file: Sources/Here.swift
perl: s~here~there~" "an entry with no test: line"
expect fail "$good

test: aTest
perl: s~here~there~" "an entry with a test: line but no file:"
expect fail "$good

test: aTest
file: Sources/Gone.swift
perl: s~here~there~" "a file: that does not exist"
expect fail "$good

test: aTest
file: Sources/Here.swift" "an entry with no perl: line"
expect fail "$good
test: aTest
file: Sources/Here.swift
perl: s~here~there~" "two entries run together with no blank line"
expect fail "$good

test:
file: Sources/Here.swift
perl: s~here~there~" "a test: line that names no test"
expect fail "$good

test: aTest
file: Sources/Here.swift
<<<<<<< ours
perl: s~here~there~" "a line left by a merge"

# The manifest and the area files are one list: a bad entry in either fails.
printf '%s\n' "$good" > "$scratch/manifest.txt"
printf 'test: aTest\nperl: s~here~there~\n' > "$scratch/bad.txt"
if MUTATION_ROOT="$scratch" sh "$check" "$scratch/manifest.txt" "$scratch/bad.txt" >/dev/null 2>&1; then
  echo "FAIL: a bad entry in the second file should fail"
  failures=$((failures + 1))
else
  echo "ok: a bad entry in the second file"
fi

rm -rf "$scratch"
if [ "$failures" -ne 0 ]; then
  echo "mutation-manifest-check-test: $failures failure(s)"
  exit 1
fi
echo "mutation-manifest-check-test: ok"
