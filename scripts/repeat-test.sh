#!/bin/sh
# Runs the package tests again and again to catch a flaky test.
# Usage: scripts/repeat-test.sh <count> [filter]
# With no filter the whole suite runs each time, so the test under watch
# shares the machine with every other test, as it does in CI.
# A run counts as passed only when at least one test ran and all passed,
# so a filter that matches nothing fails rather than passing 30 times.
set -u
# The pass line starts with a glyph that is several bytes in UTF-8. The
# match below doesn't rely on it, and a fixed locale keeps grep the same
# under LANG=C or POSIX.
LC_ALL=C
export LC_ALL

count="${1:?how many runs}"
filter="${2:-}"
swift build --package-path Packages/PebbleKit --build-tests --quiet || exit 1

passed=0
failed=0
tests=""
run=1
while [ "$run" -le "$count" ]; do
  if [ -n "$filter" ]; then
    out="$(swift test --package-path Packages/PebbleKit --skip-build --filter "$filter" 2>&1)"
  else
    out="$(swift test --package-path Packages/PebbleKit --skip-build 2>&1)"
  fi
  status=$?
  ran="$(printf '%s\n' "$out" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} .*passed.*/\1/p' | tail -1)"
  if [ "$status" -eq 0 ] && [ -n "$ran" ] && [ "$ran" -gt 0 ]; then
    passed=$((passed + 1))
    tests="$ran"
  else
    failed=$((failed + 1))
    if [ -n "$ran" ] && [ "$ran" -eq 0 ]; then
      echo "run $run: no tests ran${filter:+ for filter '$filter'}"
    fi
    printf '%s\n' "$out" | grep -E "recorded an issue|failed" | head -20
  fi
  run=$((run + 1))
done
echo "repeat-test: $passed passed, $failed failed, out of $count${tests:+, tests in each run: $tests}"
[ "$failed" -eq 0 ]
