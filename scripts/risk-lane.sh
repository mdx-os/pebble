#!/bin/sh
# Decide the risk lane for a list of changed paths, one per line on stdin.
# Prints "fast" when every path is low risk, otherwise "gated" plus the
# first path that needs Mandeep's review. See AGENTS.md, "Risk lanes".
set -eu

lane=gated
while IFS= read -r path; do
  [ -z "$path" ] && continue
  [ "$lane" = gated ] && lane=fast
  lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')

  # One-way doors are always gated, even inside docs or tests.
  case "$lower" in
    agents.md|*/agents.md) lane=gated ;;
    *privacy*|*permission*|*brand*|*entitlements*|*info.plist) lane=gated ;;
    .github/*|package.swift|*/package.swift|package.resolved|*/package.resolved) lane=gated ;;
  esac
  if [ "$lane" = gated ]; then
    echo "gated: $path"
    exit 0
  fi

  case "$path" in
    docs/*) ;;
    Tests/*|Packages/*/Tests/*) ;;
    *.md) ;;
    *) echo "gated: $path"; exit 0 ;;
  esac
done

echo "$lane"
