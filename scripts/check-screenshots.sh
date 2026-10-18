#!/bin/sh
# PERMANENT GUARD, run by `make screenshots` and so by `make verify`.
# The screenshot set must show the orange fill with white words on it, in
# dark mode, where it is hardest to read: the iPad sidebar with a row
# chosen, the same row with its count of waiting questions, and a sheet
# with its Done button on iPhone and on the Mac. Each file must exist, and
# scripts/fill-check.swift must find the fill in it, so a gray selection, a
# count in the system's gray, or a Done drawn as orange words on glass fails.
# Usage: scripts/check-screenshots.sh [dir]   (default: build/screenshots)
set -eu

dir="${1:-build/screenshots}"
for name in iphone ipad mac ipad-sidebar-dark ipad-sidebar-badge-dark iphone-sheet-dark mac-sheet mac-sheet-dark; do
  if [ ! -s "$dir/$name.png" ]; then
    echo "check-screenshots: $dir/$name.png is missing" >&2
    exit 1
  fi
done

# The sidebar's chosen row: the left third, near the top.
swift scripts/fill-check.swift "$dir/ipad-sidebar-dark.png" 0 0 0.34 0.2
# The same row with a question waiting: its count sits at the row's right
# end, so the right half of the row must still have white on the fill.
swift scripts/fill-check.swift "$dir/ipad-sidebar-badge-dark.png" 0 0 0.34 0.2
swift scripts/fill-check.swift "$dir/ipad-sidebar-badge-dark.png" 0.17 0 0.34 0.2 --badge
# Done: the top right of the sheet.
swift scripts/fill-check.swift "$dir/iphone-sheet-dark.png" 0.5 0 1 0.2
# Done on the Mac: the bottom right of the sheet. The Mac sheet is drawn by
# SnapshotMode with cacheDisplay, which renders FillButtonStyle's plain
# capsule faithfully but cannot draw Liquid Glass or the window's own
# materials. This checks Done's fill and words, not the glass around it.
swift scripts/fill-check.swift "$dir/mac-sheet-dark.png" 0.6 0.8 1 1
echo "check-screenshots: the fill shows, with white words on it"
