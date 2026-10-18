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

# shellcheck disable=SC2086
if hits="$(grep -rniw $skip --include='*.swift' -e "$brand" App AppUITests Packages)"; then
  echo "brand-check: \"$brand\" is spelled out in code. Read it from Brand instead:"
  echo "$hits"
  exit 1
fi

# Each hit as "path: line", without its line number, so moving code
# around never breaks the list.
# shellcheck disable=SC2086
found="$(grep -rn $skip --include='*.swift' -e "$codename" App AppUITests Packages \
  | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1: /' | sort -u || true)"
new="$(printf '%s\n' "$found" | grep -vxF -f "$known" | grep -v '^$' || true)"
if [ -n "$new" ]; then
  echo "brand-check: \"$codename\" is spelled out in new code. Use a neutral name, such as \"showcase\" for a launch argument:"
  echo "$new"
  exit 1
fi
stale="$(grep -v '^$' "$known" | grep -vxF -f /dev/stdin <<EOF || true
$found
EOF
)"
if [ -n "$stale" ]; then
  echo "brand-check: these lines in $known no longer match any code. Take them out:"
  echo "$stale"
  exit 1
fi
echo "brand-check: ok (\"$brand\" appears only in Config/Brand.xcconfig, and \"$codename\" only where it was already)"
