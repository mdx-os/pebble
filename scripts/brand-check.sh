#!/bin/sh
# Fails if the product's public name is spelled out in code, in any case.
# The name lives only in Config/Brand.xcconfig; code reads it at runtime.
#
# Also fails on a new lowercase spelling of the codename in code, such as
# a key, a path or a launch argument, where it would be written down and
# outlive a rename. Module and type names (Pebble...) are fine. The
# spellings that were already there, and are kept on purpose (stored keys
# people's choices are under, the notes folder, the User-Agent), are listed
# in scripts/brand-check-known.txt as "path: line". A line there that no
# longer matches anything is reported too, so the list never grows stale.
set -eu

brand="$(sed -n 's/^BRAND_NAME *= *//p' Config/Brand.xcconfig | tr -d '[:space:]')"
if [ -z "$brand" ]; then
  echo "brand-check: BRAND_NAME is not set in Config/Brand.xcconfig"
  exit 1
fi
codename="pebble"
known="scripts/brand-check-known.txt"
skip="--exclude-dir=.build --exclude-dir=build --exclude-dir=DerivedData"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The lines of $1 that are not a whole line of $2. Blank lines are left out
# of both first: an empty pattern matches every line, so one blank line in
# the list would hide every new hit.
missing_from() {
  grep -v '^$' "$1" > "$work/lines" || true
  grep -v '^$' "$2" > "$work/patterns" || true
  if [ -s "$work/patterns" ]; then
    grep -vxF -f "$work/patterns" "$work/lines" || true
  else
    cat "$work/lines"
  fi
}

# The comparison checks itself first, on a list with a blank line and a line
# that matches nothing, against code with one new hit. Both must be reported,
# or the real check below could pass without reading anything.
printf '%s\n' "a.swift: kept" "a.swift: new" > "$work/self-found"
printf '%s\n' "a.swift: kept" "" "a.swift: gone" > "$work/self-known"
if [ "$(missing_from "$work/self-found" "$work/self-known")" != "a.swift: new" ] \
  || [ "$(missing_from "$work/self-known" "$work/self-found")" != "a.swift: gone" ]; then
  echo "brand-check: the known-lines comparison is broken. It must report a new hit and a stale line."
  exit 1
fi

# shellcheck disable=SC2086
if hits="$(grep -rniw $skip --include='*.swift' -e "$brand" App AppUITests Packages Tools)"; then
  echo "brand-check: \"$brand\" is spelled out in code. Read it from Brand instead:"
  echo "$hits"
  exit 1
fi

# Each hit as "path: line", without its line number, so moving code
# around never breaks the list.
# shellcheck disable=SC2086
grep -rn $skip --include='*.swift' -e "$codename" App AppUITests Packages Tools \
  | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1: /' | sort -u > "$work/found" || true
new="$(missing_from "$work/found" "$known")"
if [ -n "$new" ]; then
  echo "brand-check: \"$codename\" is spelled out in new code. Use a neutral name, such as \"showcase\" for a launch argument:"
  echo "$new"
  exit 1
fi
stale="$(missing_from "$known" "$work/found")"
if [ -n "$stale" ]; then
  echo "brand-check: these lines in $known no longer match any code. Take them out:"
  echo "$stale"
  exit 1
fi
echo "brand-check: ok (\"$brand\" appears only in Config/Brand.xcconfig, and \"$codename\" only where it was already)"
