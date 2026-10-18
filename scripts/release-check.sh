#!/bin/sh
# Checks what App Store Connect will look at, before anyone signs.
# Usage: scripts/release-check.sh [archive-dir]   (default: build/archives)
# Reads the unsigned archives `make archive` writes, plus the icon sources,
# and makes sure no signing material is in the repo.
set -eu

archives="${1:-build/archives}"
status=0
fail() { echo "release-check: $*"; status=1; }

setting() { sed -n "s/^$1 *= *//p" Config/Version.xcconfig | tr -d '[:space:]'; }
version="$(setting MARKETING_VERSION)"
build="$(setting CURRENT_PROJECT_VERSION)"
echo "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || fail "MARKETING_VERSION \"$version\" is not like 1.2.3"
echo "$build" | grep -qE '^[0-9]+(\.[0-9]+){0,2}$' || fail "CURRENT_PROJECT_VERSION \"$build\" is not a number like 7 or 7.1"

# The icons: every file the catalog names, at the size it claims, and the
# iOS one without transparency, which App Store Connect refuses.
icons="App/Resources/Assets.xcassets/AppIcon.appiconset"
wanted="$(python3 -I -c '
import json, sys
for image in json.load(open(sys.argv[1] + "/Contents.json"))["images"]:
    points = float(image["size"].split("x")[0])
    scale = float(image.get("scale", "1x")[:-1])
    print(image.get("filename", "-"), int(points * scale), image["idiom"])
' "$icons")"
while read -r file px idiom; do
  if [ "$file" = - ] || [ ! -f "$icons/$file" ]; then
    fail "$icons is missing the $idiom icon at $px pixels"
    continue
  fi
  size="$(sips -g pixelWidth -g pixelHeight "$icons/$file" | awk '/pixel/ {print $2}' | sort -u)"
  [ "$size" = "$px" ] || fail "$file should be ${px}x${px}"
  if [ "$idiom" = universal ] && sips -g hasAlpha "$icons/$file" | grep -q 'hasAlpha: yes'; then
    fail "$file has an alpha channel; the iOS icon must be opaque"
  fi
done <<EOF
$wanted
EOF

# No signing material in the repo, not even placeholders.
tracked="$(git ls-files)"
if echo "$tracked" | grep -E '\.(mobileprovision|provisionprofile|p12|p8|cer|certSigningRequest)$'; then
  fail "signing files are tracked by git"
fi
# shellcheck disable=SC2046
if hits="$(grep -nE '(DEVELOPMENT_TEAM|PROVISIONING_PROFILE(_SPECIFIER)?|CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]) *[:=] *"?[A-Za-z0-9]' project.yml Config/*.xcconfig Makefile .github/workflows/*.yml 2>/dev/null | grep -v '^Config/Signing.local.xcconfig')"; then
  fail "signing settings are set in the repo. They belong in Config/Signing.local.xcconfig:"
  echo "$hits" | sed 's/^/  /'
fi
git check-ignore -q Config/Signing.local.xcconfig || fail "Config/Signing.local.xcconfig must be ignored by git"

# Each archive's app, as App Store Connect will read it.
check_app() {
  platform="$1"; app="$2"; plist="$3"; resources="$4"; icon_key="$5"
  before="$status"; status=0
  read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
  [ "$(read_key CFBundleShortVersionString)" = "$version" ] || fail "$platform version is \"$(read_key CFBundleShortVersionString)\", not $version"
  [ "$(read_key CFBundleVersion)" = "$build" ] || fail "$platform build number is \"$(read_key CFBundleVersion)\", not $build"
  [ "$(read_key ITSAppUsesNonExemptEncryption)" = false ] || fail "$platform is missing ITSAppUsesNonExemptEncryption"
  [ "$(read_key "$icon_key")" = AppIcon ] || fail "$platform has no $icon_key; the icon did not compile"
  [ -n "$(read_key CFBundleDisplayName)" ] || fail "$platform has no display name"
  [ -n "$(read_key LSApplicationCategoryType)" ] || fail "$platform has no app category"
  [ -f "$resources/Assets.car" ] || fail "$platform has no compiled asset catalog"
  [ -f "$resources/PrivacyInfo.xcprivacy" ] || fail "$platform has no PrivacyInfo.xcprivacy"
  if [ -f "$resources/PrivacyInfo.xcprivacy" ] && ! cmp -s "$resources/PrivacyInfo.xcprivacy" App/Resources/PrivacyInfo.xcprivacy; then
    fail "$platform carries a different PrivacyInfo.xcprivacy than App/Resources"
  fi
  if [ -d "$app/_CodeSignature" ] || [ -d "$app/Contents/_CodeSignature" ]; then
    fail "$platform archive is signed; make archive leaves signing for later"
  fi
  [ "$status" -eq 0 ] && echo "release-check: $platform $version ($build) ok"
  [ "$before" -eq 0 ] || status=1
}

ios_app="$(find "$archives/Pebble-iOS.xcarchive/Products/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
mac_app="$(find "$archives/Pebble-macOS.xcarchive/Products/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | head -n 1)"
if [ -n "$ios_app" ]; then
  check_app iOS "$ios_app" "$ios_app/Info.plist" "$ios_app" CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName
  launch="$(/usr/libexec/PlistBuddy -c 'Print :UILaunchScreen:UIColorName' "$ios_app/Info.plist" 2>/dev/null || true)"
  [ "$launch" = LaunchBackground ] || fail "iOS launch screen has no color"
  for orientation in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
    /usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations~ipad' "$ios_app/Info.plist" | grep -q "UIInterfaceOrientation$orientation\$" \
      || fail "iPad is missing $orientation, which multitasking needs"
  done
else
  fail "no iOS archive in $archives; run make archive"
fi
if [ -n "$mac_app" ]; then
  check_app macOS "$mac_app" "$mac_app/Contents/Info.plist" "$mac_app/Contents/Resources" CFBundleIconName
else
  fail "no macOS archive in $archives; run make archive"
fi

[ "$status" -eq 0 ] && echo "release-check: ok"
exit "$status"
