#!/bin/sh
# Keeps App/Resources/PrivacyInfo.xcprivacy true to the code.
# Scans App/ and every package target the app links for Apple's
# required-reason APIs. Fails when one is used without its category in the
# manifest, or when the manifest names a category the code no longer uses.
# Also fails if the app's code starts using the network, since the manifest
# says nothing is collected and nothing is tracked.
set -eu

manifest="App/Resources/PrivacyInfo.xcprivacy"
plutil -lint -s "$manifest" || { echo "privacy-check: $manifest is not a valid plist"; exit 1; }

# The products the app links, from project.yml, and their sources. A product
# missing from the package means project.yml and this script disagree.
products="$(sed -n 's/^ *products: *\[\(.*\)\]/\1/p' project.yml | tr -d ' ' | tr ',' ' ')"
[ -n "$products" ] || { echo "privacy-check: no package products found in project.yml"; exit 1; }
dirs="App"
for product in $products; do
  dir="Packages/PebbleKit/Sources/$product"
  [ -d "$dir" ] || { echo "privacy-check: $product is linked but $dir is missing"; exit 1; }
  dirs="$dirs $dir"
done

status=0

# Each declared category with its reason codes, one per line.
declared="$(python3 -I -c '
import plistlib, re, sys
manifest = plistlib.load(open(sys.argv[1], "rb"))
if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains") or manifest.get("NSPrivacyCollectedDataTypes"):
    sys.exit("the manifest now claims tracking or collection; this script and docs/RELEASE.md need a look")
for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
    reasons = [r for r in entry.get("NSPrivacyAccessedAPITypeReasons", []) if re.fullmatch(r"[0-9A-F]{4}\.\d", r)]
    print(entry["NSPrivacyAccessedAPIType"], " ".join(reasons))
' "$manifest")" || { echo "privacy-check: could not read $manifest"; exit 1; }

# Patterns follow Apple's list at
# developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
check() {
  category="$1"; pattern="$2"
  # shellcheck disable=SC2086
  hits="$(grep -rnE --include='*.swift' --include='*.m' --include='*.c' -e "$pattern" $dirs || true)"
  line="$(echo "$declared" | grep "^$category " || true)"
  if [ -n "$hits" ] && [ -z "$line" ]; then
    echo "privacy-check: this code uses a required-reason API ($category) with no entry in $manifest:"
    echo "$hits" | sed 's/^/  /'
    echo "  Add the category with a reason code that is true for the app."
    status=1
  elif [ -z "$hits" ] && [ -n "$line" ]; then
    echo "privacy-check: $manifest declares $category, but no code uses it. Remove the entry."
    status=1
  elif [ -n "$line" ] && [ "$line" = "$category " ]; then
    echo "privacy-check: $category in $manifest has no valid reason code."
    status=1
  fi
}

check NSPrivacyAccessedAPICategoryUserDefaults \
  '\bUserDefaults\b|NSUserDefaults|@AppStorage'
check NSPrivacyAccessedAPICategoryFileTimestamp \
  '\bcreationDate\b|\bmodificationDate\b|fileModificationDate|fileCreationDate|contentModificationDate|creationDateKey|attributesOfItem|getattrlist|setattrlist|\b(f|l)?stat(at)?\('
check NSPrivacyAccessedAPICategorySystemBootTime \
  'systemUptime|mach_absolute_time'
check NSPrivacyAccessedAPICategoryDiskSpace \
  'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|attributesOfFileSystem|\bstatv?fs\('
check NSPrivacyAccessedAPICategoryActiveKeyboards \
  'activeInputModes'

# Nothing collected and nothing tracked holds only while the app's code
# stays off the network. When an adapter needs it, update the manifest's
# NSPrivacyCollectedDataTypes and the export answer in project.yml, then
# narrow this check.
# shellcheck disable=SC2086
if net="$(grep -rnE --include='*.swift' -e '\bURLSession\b|import Network\b|NWConnection|CFNetwork|WKWebView' $dirs)"; then
  echo "privacy-check: the app's code now reaches the network. Review $manifest and ITSAppUsesNonExemptEncryption:"
  echo "$net" | sed 's/^/  /'
  status=1
fi

[ "$status" -eq 0 ] && echo "privacy-check: ok ($manifest matches $dirs)"
exit "$status"
