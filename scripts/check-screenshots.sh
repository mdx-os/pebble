#!/bin/sh
# PERMANENT GUARD, run by `make screenshots` and so by `make verify`.
# The screenshot set must show the orange fill with white words on it, in
# dark mode, where it is hardest to read: the iPad sidebar with a row
# chosen, and a sheet with its Done button. Each file must exist, and
# scripts/fill-check.swift must find the fill in it, so a gray selection or
# a Done drawn as orange words on glass fails.
# Usage: scripts/check-screenshots.sh [dir]   (default: build/screenshots)
set -eu

dir="${1:-build/screenshots}"
for name in iphone ipad mac ipad-sidebar-dark iphone-sheet-dark mac-sheet mac-sheet-dark; do
  if [ ! -s "$dir/$name.png" ]; then
    echo "check-screenshots: $dir/$name.png is missing" >&2
    exit 1
  fi
done

# The sidebar's chosen row: the left third, near the top.
swift scripts/fill-check.swift "$dir/ipad-sidebar-dark.png" 0 0 0.34 0.2
# Done: the top right of the sheet.
swift scripts/fill-check.swift "$dir/iphone-sheet-dark.png" 0.5 0 1 0.2
echo "check-screenshots: the fill shows, with white words on it"
