#!/bin/sh
# Runs the package tests again and again to catch a flaky test.
# Usage: scripts/repeat-test.sh <count> [filter]
# With no filter the whole suite runs each time, so the test under watch
# shares the machine with every other test, as it does in CI.
set -u

count="${1:?how many runs}"
filter="${2:-}"
swift build --package-path Packages/PebbleKit --build-tests --quiet || exit 1

passed=0
failed=0
run=1
while [ "$run" -le "$count" ]; do
  if [ -n "$filter" ]; then
    out="$(swift test --package-path Packages/PebbleKit --skip-build --filter "$filter" 2>&1)"
  else
    out="$(swift test --package-path Packages/PebbleKit --skip-build 2>&1)"
  fi
  if printf '%s\n' "$out" | grep -q "^. Test run with .* passed"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf '%s\n' "$out" | grep -E "recorded an issue|failed" | head -20
  fi
  run=$((run + 1))
done
echo "repeat-test: $passed passed, $failed failed, out of $count"
[ "$failed" -eq 0 ]
