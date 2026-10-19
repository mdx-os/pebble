#!/bin/sh
# Keeps App/Resources/PrivacyInfo.xcprivacy, the export answer and the
# promise that personal content stays on the device true to the code.
#
# Enumerates every source folder project.yml compiles, all of App, and all
# transitively linked package targets, read from project.yml as XcodeGen
# resolves it, so a form the check can't read fails. GuardScan
# parses Swift once per file, ignoring comments and literal text. Non-Swift
# compiled sources fail closed until a reader and fixtures are added.
# Validates manifest categories and reason codes, network confinement, URL
# reads, transport closure ancestry, speech confinement and export tripwires.
# With --network-files, prints only network-bearing files after checks pass.
# make privacy-check-test proves both rejected and permitted cases.
set -eu

manifest="App/Resources/PrivacyInfo.xcprivacy"
package="Packages/PebbleKit"
# The opt-in cloud client: the only file allowed network code. It reaches
# the network only after the person turns the cloud on (PrivacyPlace says
# the chat may leave the device) and says send to each preview.
cloud_files="$package/Sources/PebbleModel/CloudModel.swift"
status=0

plutil -lint -s "$manifest" || { echo "privacy-check: $manifest is not a valid plist"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The Swift rules live in GuardScan, isolated from the app package graph.
# Fixture tests build once and pass that exact executable to every scratch tree.
if [ -n "${PRIVACY_AUDIT_BIN:-}" ]; then
  audit="$PRIVACY_AUDIT_BIN"
else
  swift build --package-path Tools/GuardKit --product privacy-audit --quiet >&2
  bin="$(swift build --package-path Tools/GuardKit --show-bin-path)"
  audit="$bin/privacy-audit"
fi

# The products the app links and the folders it compiles, from project.yml
# as XcodeGen resolves it. PrivacyProject fails on any form it can't read.
xcodegen dump --spec project.yml --type json --no-env --quiet --file "$work/spec.json" \
  || { echo "privacy-check: xcodegen could not read project.yml"; exit 1; }
"$audit" --project "$work/spec.json" > "$work/linked" || { cat "$work/linked"; exit 1; }
products="$(sed -n 's/^product //p' "$work/linked" | tr '\n' ' ')"
[ -n "$products" ] || { echo "privacy-check: project.yml links no package products"; exit 1; }

# Every source file of those products' targets and everything they depend
# on. A dependency on another package can't be read here, so it fails.
# PRIVACY_DESCRIBE_CACHE, a folder, keeps describe's output by all it reads:
# Package.swift and the names of every file and folder in the package. The
# self-test sets it, so a tree that changes neither reuses the output.
kept=""
if [ -n "${PRIVACY_DESCRIBE_CACHE:-}" ]; then
  key="$( { cat "$package/Package.swift"; (cd "$package" && find . \( -name .build -o -name .swiftpm \) -prune -o -print | LC_ALL=C sort); } | shasum | cut -d ' ' -f 1)"
  kept="$PRIVACY_DESCRIBE_CACHE/$key.json"
fi
if [ -n "$kept" ] && [ -f "$kept" ]; then
  cp "$kept" "$work/package.json"
else
  swift package --package-path "$package" describe --type json > "$work/package.json" \
    || { echo "privacy-check: swift package describe failed for $package"; exit 1; }
  [ -z "$kept" ] || { cp "$work/package.json" "$kept.$$" && mv "$kept.$$" "$kept"; }
fi
# shellcheck disable=SC2086
python3 -I -c '
import json, sys
described_path, package, products = sys.argv[1], sys.argv[2], sys.argv[3:]
described = json.load(open(described_path))
targets = {t["name"]: t for t in described["targets"]}
by_product = {p["name"]: p["targets"] for p in described["products"]}
todo, seen = [], []
for product in products:
    if product not in by_product:
        sys.exit("privacy-check: project.yml links %s, which %s does not make" % (product, package))
    todo += by_product[product]
while todo:
    name = todo.pop()
    if name in seen:
        continue
    seen.append(name)
    target = targets[name]
    if target.get("product_dependencies"):
        sys.exit("privacy-check: %s depends on %s from another package, which this check cannot read. Review it, then teach this script to scan it." % (name, ", ".join(target["product_dependencies"])))
    todo += target.get("target_dependencies", [])
    for source in target["sources"]:
        path = "%s/%s/%s" % (package, target["path"], source)
        if any(c.isspace() for c in path):
            sys.exit("privacy-check: %s has a space in its path" % path)
        print(path)
print(" ".join(sorted(seen)), file=sys.stderr)
' "$work/package.json" "$package" $products > "$work/files" 2> "$work/targets" || { cat "$work/targets"; exit 1; }
# Every source folder or file project.yml compiles, and all of App. Include
# all Xcode compiled source types, plus headers that could contain inline
# code. Unsupported languages fail closed in PrivacyAudit.
sed -n 's/^root //p' "$work/linked" > "$work/roots"
echo App >> "$work/roots"
while IFS= read -r root; do
  [ -e "$root" ] || { echo "privacy-check: project.yml compiles $root, which is not there"; exit 1; }
  find "$root" -type f \( -iname '*.swift' -o -iname '*.m' -o -iname '*.mm' -o -iname '*.c' -o -iname '*.cc' -o -iname '*.cpp' -o -iname '*.cxx' -o -iname '*.c++' -o -iname '*.metal' -o -iname '*.h' -o -iname '*.hpp' -o -iname '*.s' \) >> "$work/files"
done < "$work/roots"
sort -u "$work/files" -o "$work/files"

"$audit" "$work/files" "${1:-check}" || status=1
if [ "${1:-}" != --network-files ] && [ "$status" -eq 0 ]; then
  echo "privacy-check: ok ($manifest matches $(wc -l < "$work/files" | tr -d ' ') files in $(tr '\n' ' ' < "$work/roots")and $(cat "$work/targets"); network code only in $cloud_files)"
fi
exit "$status"
