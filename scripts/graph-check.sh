#!/bin/sh
# Keeps swift-syntax out of the app's package graph. It lives only in
# Tools/GuardKit, the source guards' own package, which reads PebbleKit by
# path; nothing the app builds may reach back to it. Fails when:
#
# - PebbleKit's manifest or its resolved pins, project.yml, or the
#   generated project (when there is one) name swift-syntax, one of its
#   modules, or the guard package, outside a comment;
# - project.yml links a test helper PebbleKit offers only to GuardKit:
#   SourceScan, PromiseWords or TestScratch;
# - PebbleKit's dependency graph, as SwiftPM resolves it, holds
#   swift-syntax, so a dependency can't bring it in unnamed.
#
# Usage: scripts/graph-check.sh [root]
# GRAPH_CHECK_SWIFT names the swift command.
set -eu

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
swift="${GRAPH_CHECK_SWIFT:-swift}"
syntax='swift-syntax|SwiftSyntax|SwiftParser|SwiftOperators|GuardKit|GuardScan'
helpers='SourceScan|PromiseWords|TestScratch'
found=0

# Each line of $1 that matches $2, comment lines aside.
named() {
  grep -nE "$2" "$1" | grep -vE '^[0-9]+:[[:space:]]*(//|#)' || true
}

for file in Packages/PebbleKit/Package.swift Packages/PebbleKit/Package.resolved project.yml \
    Pebble.xcodeproj/project.pbxproj Pebble.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
  [ -f "$root/$file" ] || continue
  lines="$(named "$root/$file" "$syntax")"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
    echo "graph-check: $file names swift-syntax or the guard package; they belong only in Tools/GuardKit"
    found=1
  fi
done

for file in project.yml Pebble.xcodeproj/project.pbxproj; do
  [ -f "$root/$file" ] || continue
  lines="$(named "$root/$file" "$helpers")"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
    echo "graph-check: $file links a test helper; the app links only PebbleKit's layers"
    found=1
  fi
done

if [ "$found" -ne 0 ]; then exit 1; fi

# The graph itself: what SwiftPM resolves for PebbleKit, every dependency
# of every dependency.
if ! graph="$($swift package --package-path "$root/Packages/PebbleKit" show-dependencies --format json 2>&1)"; then
  printf '%s\n' "$graph"
  echo "graph-check: SwiftPM couldn't resolve PebbleKit's dependencies"
  exit 1
fi
if printf '%s\n' "$graph" | grep -qiE 'swift-syntax'; then
  printf '%s\n' "$graph"
  echo "graph-check: PebbleKit's dependency graph holds swift-syntax; it belongs only in Tools/GuardKit"
  exit 1
fi

echo "graph-check: ok (swift-syntax is only in Tools/GuardKit, and the app's package graph doesn't reach it)"
