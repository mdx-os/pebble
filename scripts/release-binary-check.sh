#!/bin/sh
# Fails if a Release app holds the staging test sign-in. That code is
# compiled only in Debug (`#if DEBUG` in PebbleModel), so a Release build
# that holds its type name or its path could offer a sign-in no shipped
# build may have. `make build-release` runs it on the apps it just built.
#
# Usage: scripts/release-binary-check.sh products-folder...
# Each folder is searched for .app bundles, every file in each bundle is
# scanned, the executables and frameworks included, and the check fails
# if any holds one of the words below, or if a folder has no app at all,
# so a build that went somewhere else never reads as clean.
set -eu

if [ "$#" -eq 0 ]; then
  echo "release-binary-check: name the folders that hold the Release apps."
  exit 1
fi

# What only the staging test sign-in has: its type and where it asks.
words="StagingIdentityTokenSource
sign-in/dev-token"

for folder in "$@"; do
  apps="$(find "$folder" -maxdepth 1 -name '*.app' -type d 2>/dev/null || true)"
  if [ -z "$apps" ]; then
    echo "release-binary-check: no app in $folder, so there is nothing to check. Build Release first."
    exit 1
  fi
  while IFS= read -r app; do
    while IFS= read -r word; do
      if found="$(grep -r -l -a -F -e "$word" "$app" 2>/dev/null)"; then
        echo "error: $(basename "$app") in $folder holds \"$word\", from the staging test sign-in, which is for Debug builds only:"
        printf '%s\n' "$found" | sed 's/^/error:   /'
        exit 1
      fi
    done <<EOF
$words
EOF
  done <<EOF
$apps
EOF
done
echo "release-binary-check: ok (no Release app holds the staging test sign-in)"
