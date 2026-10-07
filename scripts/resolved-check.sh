#!/bin/sh
# Fails when the package pin and the app pin are not the same file.
set -eu

package="Packages/PebbleKit/Package.resolved"
app="Config/Package.resolved"

if [ ! -f "$package" ] || [ ! -f "$app" ]; then
  echo "resolved-check: missing $package or $app"
  exit 1
fi

if ! cmp -s "$package" "$app"; then
  echo "resolved-check: $package and $app disagree"
  diff -u "$package" "$app" || true
  exit 1
fi
echo "resolved-check: ok"
