#!/bin/sh
# Checks what App Store Connect will look at, before anyone signs.
# Usage: scripts/release-check.sh [archive-dir]   (default: build/archives)
# Reads the unsigned archives `make archive` writes, plus the icon sources,
# and makes sure no signing material is in the repo.
set -eu

archives="${1:-build/archives}"
# NSExceptionDomains someone has reviewed, separated by spaces. None yet.
reviewed_domains=""
status=0
fail() { echo "release-check: $*"; status=1; }

setting() { sed -n "s/^$1 *= *//p" Config/Version.xcconfig | tr -d '[:space:]'; }
version="$(setting MARKETING_VERSION)"
build="$(setting CURRENT_PROJECT_VERSION)"
echo "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || fail "MARKETING_VERSION \"$version\" is not like 1.2.3"
echo "$build" | grep -qE '^[0-9]+(\.[0-9]+){0,2}$' || fail "CURRENT_PROJECT_VERSION \"$build\" is not a number like 7 or 7.1"

# The icons: every file the catalog names, at the size it claims, and the
# iOS one without transparency, which App Store Connect refuses.
icons="App/Assets.xcassets/AppIcon.appiconset"
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
# A team or profile with any value, or a signing identity other than the
# ad hoc "-", in any spelling: with or without an [sdk=...] condition,
# quoted or not. Comment lines don't count.
signing_hits() {
  grep -nE '\b(DEVELOPMENT_TEAM|PROVISIONING_PROFILE(_SPECIFIER)?|CODE_SIGN_IDENTITY)\b' /dev/null "$@" \
    | grep -vE '^[^:]+:[0-9]+: *(#|//)' | grep -v '^Config/Signing.local.xcconfig' \
    | while IFS= read -r line; do
        # Every value set on the line; only "-" may stand.
        echo "$line" | grep -oE '(DEVELOPMENT_TEAM|PROVISIONING_PROFILE(_SPECIFIER)?|CODE_SIGN_IDENTITY)(\[[^]]*\])?"? *[:=] *("[^"]*"|[^ "]*)' \
          | sed -E 's/^[A-Z_]+(\[[^]]*\])?"? *[:=] *//; s/"//g' | grep -qvxE -e '-' -e '' && echo "$line"
      done || true
}
# The grep checks itself first, on lines it must catch and lines it must
# let by, or the real check below could pass without reading anything.
sample="$(mktemp)"
trap 'rm -f "$sample"' EXIT
cat > "$sample" <<'EOF'
CODE_SIGN_IDENTITY = Apple Distribution
CODE_SIGN_IDENTITY[sdk=iphoneos*] = iPhone Developer
	xcodebuild archive CODE_SIGN_IDENTITY="Apple Development"
DEVELOPMENT_TEAM = ABCDE12345
        "PROVISIONING_PROFILE_SPECIFIER": "Some Profile"
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "-"
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
// CODE_SIGN_IDENTITY = Apple Distribution
# CODE_SIGN_IDENTITY: Apple Distribution
	xcodebuild archive CODE_SIGNING_ALLOWED=NO
EOF
if [ "$(signing_hits "$sample" | cut -d: -f2 | tr '\n' ' ')" != "1 2 3 4 5 " ]; then
  fail "the signing grep is broken: on its own sample it must catch lines 1 to 5 and nothing else, and it caught: $(signing_hits "$sample" | cut -d: -f2 | tr '\n' ' ')"
fi
# shellcheck disable=SC2046
hits="$(signing_hits project.yml Config/*.xcconfig Makefile $(ls .github/workflows/*.yml 2>/dev/null || true))"
if [ -n "$hits" ]; then
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
  # No cloud address of ours: "Data Not Collected" holds only while the
  # cloud model is a server the person chose. See docs/RELEASE.md.
  [ -z "$(read_key PebbleCloudEndpoint)" ] \
    || fail "$platform ships a cloud address ($(read_key PebbleCloudEndpoint)). Release builds carry none; empty Config/Cloud.local.xcconfig on this machine"
  # App Transport Security stays as the system sets it.
  ats="$(python3 -I -c '
import plistlib, sys
ats = plistlib.load(open(sys.argv[1], "rb")).get("NSAppTransportSecurity", {})
reviewed = set(sys.argv[2].split())
for key, value in ats.items():
    if key.startswith("NSAllowsArbitraryLoads") and value:
        print(key)
for domain in ats.get("NSExceptionDomains", {}):
    if domain not in reviewed:
        print("NSExceptionDomains:" + domain)
' "$plist" "$reviewed_domains")"
  [ -z "$ats" ] || fail "$platform loosens App Transport Security ($(echo "$ats" | tr '\n' ' ')). The cloud client speaks only https; an exception needs a review, then its domain in reviewed_domains here"
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
  launch_looks="$(python3 -I -c '
import json, sys
for color in json.load(open(sys.argv[1]))["colors"]:
    print("+".join(sorted(a["value"] for a in color.get("appearances", []))) or "any")
' App/Assets.xcassets/LaunchBackground.colorset/Contents.json | sort | tr '\n' ' ')"
  [ "$launch_looks" = "any dark dark+high high " ] \
    || fail "LaunchBackground should have light, dark and both in high contrast; it has: $launch_looks"
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

# The Mac sandbox, from the build settings, since unsigned archives carry no
# entitlements to read.
mac_settings="$(xcodebuild -showBuildSettings -quiet -project Pebble.xcodeproj -target Pebble -configuration Release -sdk macosx 2>/dev/null || true)"
mac_setting() { echo "$mac_settings" | sed -n "s/^ *$1 = //p" | head -n 1; }
[ "$(mac_setting ENABLE_APP_SANDBOX)" = YES ] || fail "ENABLE_APP_SANDBOX is not YES for the macOS Release build"
entitlements="$(mac_setting CODE_SIGN_ENTITLEMENTS)"
entitled() {
  [ -n "$entitlements" ] && [ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null || true)" = true ]
}

# Saving or dragging a file out reaches past the sandbox; the system lets it
# only with this entitlement, and only in Release, so it would fail unseen.
if hits="$(grep -rnE --include='*.swift' '\.fileExporter\(|\.fileImporter\(|\bNSSavePanel\b|\bNSOpenPanel\b|\.draggable\(|\.onDrag\(' App Packages/PebbleKit/Sources)" \
  && ! entitled com.apple.security.files.user-selected.read-write; then
  fail "the app saves, opens or drags out files, which the Mac sandbox allows only with com.apple.security.files.user-selected.read-write in $entitlements:"
  echo "$hits" | sed 's/^/  /'
fi

# Network code exists only in the opt-in cloud client (privacy-check proves
# that, and that the app brings no encryption of its own). When it does, the
# sandboxed Mac app needs outgoing connections, or the cloud would work in
# every Debug run and fail only in TestFlight.
if network="$(sh scripts/privacy-check.sh --network-files)"; then
  if [ -n "$network" ]; then
    entitled com.apple.security.app-sandbox || fail "$entitlements does not turn on the sandbox"
    if entitled com.apple.security.network.client; then
      echo "release-check: network code only in $(echo "$network" | tr '\n' ' ')with outgoing connections allowed on the Mac"
    else
      fail "the app has network code ($(echo "$network" | tr '\n' ' ')) but the macOS Release entitlements (${entitlements:-none}) lack com.apple.security.network.client"
    fi
  fi
else
  echo "$network" | sed 's/^/  /'
  fail "privacy-check fails, so the export answer (ITSAppUsesNonExemptEncryption = NO) and the network rule can't be trusted; run make privacy-check"
fi

[ "$status" -eq 0 ] && echo "release-check: ok"
exit "$status"
