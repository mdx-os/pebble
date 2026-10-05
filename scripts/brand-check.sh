#!/bin/sh
# Fails if the product's public name is spelled out in code.
# The name lives only in Config/Brand.xcconfig; code reads it at runtime.
set -eu

brand="$(sed -n 's/^BRAND_NAME *= *//p' Config/Brand.xcconfig | tr -d '[:space:]')"
if [ -z "$brand" ]; then
  echo "brand-check: BRAND_NAME is not set in Config/Brand.xcconfig"
  exit 1
fi

if hits="$(grep -rnw --include='*.swift' -e "$brand" App Packages)"; then
  echo "brand-check: \"$brand\" is spelled out in code. Read it from Brand instead:"
  echo "$hits"
  exit 1
fi
echo "brand-check: ok (\"$brand\" appears only in Config/Brand.xcconfig)"
