#!/bin/sh
# PERMANENT GUARD, run by `make screenshots` and so by `make verify`.
# The screenshot set must show the blue fill with white words on it, in
# dark mode, where it is hardest to read: the iPad sidebar with a row
# chosen, the same row with its count of waiting questions, and a sheet
# with its Done button on iPhone and on the Mac (on the Mac in light mode
# as well). Each scene asked for must exist, each file must exist, and
# scripts/fill-check.swift must find the fill in it, so a gray selection, a
# count in the system's gray, or a Done drawn as blue words on glass fails.
#
# 1x rendering is covered only through a downscale. SnapshotMode draws
# every Mac shot at 2x, whatever the display, so no shot here is ever drawn
# at 1x. The self-test below halves the 2x Mac sheets with sips and checks
# that fill-check, which counts shares of the region, still passes; that
# proves the check doesn't depend on scale, not that the app draws right
# at 1x.
# Usage: scripts/check-screenshots.sh [dir]   (default: build/screenshots)
set -eu

dir="${1:-build/screenshots}"
shots_script="${PEBBLE_SHOTS_SCRIPT:-scripts/screenshots.sh}"

# Every scene the screenshots ask for must be a ShowcaseScene. An unknown
# name falls back to hello, and would fail below as "no blue fill",
# hiding why.
if [ ! -f "$shots_script" ]; then
  echo "check-screenshots: $shots_script is missing, so no scene it asks for can be checked" >&2
  exit 1
fi
known="$(sed -n 's/^    case \([a-zA-Z][a-zA-Z, ]*\)$/\1/p' Packages/PebbleKit/Sources/PebbleUI/ShowcaseScene.swift | tr ',' ' ')"
if [ -z "$known" ]; then
  echo "check-screenshots: found no scenes in ShowcaseScene.swift; only bare 4-space \"case a, b\" lines are read," \
    "with no raw value or trailing comment" >&2
  exit 1
fi
asked="$( (grep -oE 'shots="[^"]*"' "$shots_script" | sed 's/^shots="//; s/"$//' | tr ' ' '\n' | sed 's/:.*//'
           grep -oE -- '-showcaseScreen [a-zA-Z]+' "$shots_script" | sed 's/^-showcaseScreen //') | sort -u)"
# None found means the way scenes are written changed, not that none are
# asked for, and the loop below would check nothing.
if [ -z "$asked" ]; then
  echo "check-screenshots: found no scenes asked for in $shots_script" >&2
  exit 1
fi
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

# Each region is left, top, right, bottom as fractions of the image, never
# pixels, so it lands on the same part of a shot at any scale.
# The sidebar's chosen row: the left third, near the top.
swift scripts/fill-check.swift "$dir/ipad-sidebar-dark.png" 0 0 0.34 0.2
# The same row with a question waiting: its count sits at the row's right
# end, so the right half of the row must still have white on the fill.
swift scripts/fill-check.swift "$dir/ipad-sidebar-badge-dark.png" 0 0 0.34 0.2
swift scripts/fill-check.swift "$dir/ipad-sidebar-badge-dark.png" 0.17 0 0.34 0.2 --badge
# Any white there would pass that, a long or wrapped label too. The same
# row with no count must show less white at its end, so the white that
# passed is the count's.
badge_white="$(swift scripts/fill-check.swift "$dir/ipad-sidebar-badge-dark.png" 0.17 0 0.34 0.2 --white)"
plain_white="$(swift scripts/fill-check.swift "$dir/ipad-sidebar-dark.png" 0.17 0 0.34 0.2 --white)"
if [ "$plain_white" -ge "$badge_white" ]; then
  echo "check-screenshots: the row's end has as much white with no count ($plain_white) as with one" \
    "($badge_white), so the white isn't the count" >&2
  exit 1
fi
echo "check-screenshots: the count adds white at the row's end ($plain_white with none, $badge_white with one)"
# Done: the top right of the sheet.
swift scripts/fill-check.swift "$dir/iphone-sheet-dark.png" 0.5 0 1 0.2
# Done on the Mac: the bottom right of the sheet. The Mac sheet is drawn by
# SnapshotMode with cacheDisplay, which renders FillButtonStyle's plain
# capsule faithfully but cannot draw Liquid Glass or the window's own
# materials. This checks Done's fill and words, not the glass around it.
# The light sheet too: its fill is darker, still well inside the tolerance.
swift scripts/fill-check.swift "$dir/mac-sheet-dark.png" 0.6 0.8 1 1
swift scripts/fill-check.swift "$dir/mac-sheet.png" 0.6 0.8 1 1

# SnapshotMode draws every Mac shot at 2x, whatever the display: 144 dots
# an inch, and the window twice its 1280 by 800 points.
for name in mac mac-sheet mac-sheet-dark; do
  dpi="$(sips -g dpiWidth "$dir/$name.png" | awk '/dpiWidth/ { print int($2) }')"
  if [ "$dpi" != 144 ]; then
    echo "check-screenshots: $dir/$name.png is at $dpi dots an inch, not 2x (144)" >&2
    exit 1
  fi
done
if [ "$(sips -g pixelWidth "$dir/mac.png" | awk '/pixelWidth/ { print $2 }')" != 2560 ]; then
  echo "check-screenshots: $dir/mac.png isn't 2560 pixels wide, 2x of the window" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Self-test: the fill check must not depend on the scale a shot was taken
# at. A Mac at 1x once drew this sheet at half the pixels and failed a
# check that counted pixels. A 1x copy of each passing Mac sheet must pass
# as well, and the same 1x copy with its colors turned gray, as a Done
# drawn gray would be, must fail on the same region.
gray_profile="/System/Library/ColorSync/Profiles/Generic Gray Gamma 2.2 Profile.icc"
if [ ! -f "$gray_profile" ]; then
  echo "check-screenshots: $gray_profile is missing, so the gray Done can't be made" >&2
  exit 1
fi
for name in mac-sheet-dark mac-sheet; do
  w="$(sips -g pixelWidth "$dir/$name.png" | awk '/pixelWidth/ { print $2 }')"
  h="$(sips -g pixelHeight "$dir/$name.png" | awk '/pixelHeight/ { print $2 }')"
  sips -z "$((h / 2))" "$((w / 2))" "$dir/$name.png" --out "$work/$name.png" >/dev/null
  swift scripts/fill-check.swift "$work/$name.png" 0.6 0.8 1 1
  sips --matchTo "$gray_profile" "$work/$name.png" --out "$work/$name-gray.png" >/dev/null
  if swift scripts/fill-check.swift "$work/$name-gray.png" 0.6 0.8 1 1 2>/dev/null; then
    echo "check-screenshots: fill-check passed a 1x $name with its Done turned gray" >&2
    exit 1
  fi
done

# The fill check's own cases: white words only inside a patch of fill,
# never the background between two, and a bad region fails with a reason.
swift scripts/fill-check.swift --self-test

sh scripts/shot-lib-test.sh
echo "check-screenshots: the fill shows, with white words on it"
