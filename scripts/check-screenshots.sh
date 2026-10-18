#!/bin/sh
# PERMANENT GUARD, run by `make screenshots` and so by `make verify`.
# The screenshot set must show the orange fill with white words on it, in
# dark mode, where it is hardest to read: the iPad sidebar with a row
# chosen, the same row with its count of waiting questions, and a sheet
# with its Done button on iPhone and on the Mac (on the Mac in light mode
# as well). Each scene asked for must exist, each file must exist, and
# scripts/fill-check.swift must find the fill in it, so a gray selection, a
# count in the system's gray, or a Done drawn as orange words on glass fails.
# Usage: scripts/check-screenshots.sh [dir]   (default: build/screenshots)
set -eu

dir="${1:-build/screenshots}"
shots_script="${PEBBLE_SHOTS_SCRIPT:-scripts/screenshots.sh}"

# Every scene the screenshots ask for must be a ShowcaseScene. An unknown
# name falls back to hello, and would fail below as "no orange fill",
# hiding why.
known="$(sed -n 's/^    case \([a-zA-Z][a-zA-Z, ]*\)$/\1/p' Packages/PebbleKit/Sources/PebbleUI/ShowcaseScene.swift | tr ',' ' ')"
if [ -z "$known" ]; then
  echo "check-screenshots: found no scenes in ShowcaseScene.swift" >&2
  exit 1
fi
asked="$( (grep -oE 'shots="[^"]*"' "$shots_script" | sed 's/^shots="//; s/"$//' | tr ' ' '\n' | sed 's/:.*//'
           grep -oE -- '-pebbleScreen [a-zA-Z]+' "$shots_script" | sed 's/^-pebbleScreen //') | sort -u)"
for scene in $asked; do
  case " $(echo $known) " in
    *" $scene "*) ;;
    *) echo "check-screenshots: unknown scene \"$scene\" in $shots_script; ShowcaseScene has: $(echo $known)" >&2
       exit 1 ;;
  esac
done

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
# The light sheet too: its fill is darker, still well inside the tolerance.
swift scripts/fill-check.swift "$dir/mac-sheet-dark.png" 0.6 0.8 1 1
swift scripts/fill-check.swift "$dir/mac-sheet.png" 0.6 0.8 1 1
echo "check-screenshots: the fill shows, with white words on it"
