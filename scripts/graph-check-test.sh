#!/bin/sh
# Self-test for scripts/graph-check.sh, in a scratch tree under
# build/graph-check-test. A clean tree passes, with swift-syntax named
# only in a comment; then each way swift-syntax could reach the app's
# package graph must fail the check: named in PebbleKit's manifest, pinned
# in its resolved file, linked by project.yml, a test helper linked by the
# app, and brought in by a dependency of a dependency that never names it
# in PebbleKit's own manifest.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
check="$root/scripts/graph-check.sh"
scratch="$root/build/graph-check-test"
failures=0

# A package at $1 named $2 with one library target, depending on the
# packages at the paths after it, by their names.
package() {
  dir="$1"
  name="$2"
  shift 2
  deps=""
  uses=""
  for dep in "$@"; do
    deps="$deps        .package(path: \"$dep\"),
"
    uses="$uses.product(name: \"$(basename "$dep")\", package: \"$(basename "$dep")\"), "
  done
  mkdir -p "$dir/Sources/$name"
  printf 'public let here = 1\n' > "$dir/Sources/$name/$name.swift"
  cat > "$dir/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

// swift-syntax lives only in Tools/GuardKit; this comment names it.
let package = Package(
    name: "$name",
    products: [.library(name: "$name", targets: ["$name"])],
    dependencies: [
$deps    ],
    targets: [.target(name: "$name", dependencies: [$uses])]
)
EOF
}

fresh() {
  rm -rf "$scratch"
  mkdir -p "$scratch/Packages"
  package "$scratch/Packages/PebbleKit" PebbleKit
  cat > "$scratch/project.yml" <<'EOF'
# The guards' package, Tools/GuardKit, is not part of the app.
packages:
  PebbleKit:
    path: Packages/PebbleKit
targets:
  App:
    dependencies:
      - package: PebbleKit
        products: [PebbleCore, PebbleModel, PebbleUI, PebbleBackground]
EOF
}

# Runs the check on the scratch tree. $1 is pass or fail, $2 what the tree
# shows, and $3, for a failure, words the check must give as its reason,
# so a tree that fails for some other reason doesn't count.
expect() {
  want="$1"
  what="$2"
  reason="${3:-}"
  status=0
  out="$(sh "$check" "$scratch" 2>&1)" || status=$?
  if [ "$want" = pass ] && [ "$status" -ne 0 ]; then
    echo "graph-check-test: FAILED, $what should pass:"
    printf '%s\n' "$out"
    failures=$((failures + 1))
  elif [ "$want" = fail ] && [ "$status" -eq 0 ]; then
    echo "graph-check-test: FAILED, $what should fail, but the check said: $out"
    failures=$((failures + 1))
  elif [ "$want" = fail ] && ! printf '%s\n' "$out" | grep -qF "$reason"; then
    echo "graph-check-test: FAILED, $what failed, but not because the check saw it:"
    printf '%s\n' "$out"
    failures=$((failures + 1))
  else
    echo "graph-check-test: ok, $what: $want"
  fi
}

fresh
expect pass "a clean tree, swift-syntax named only in comments"

fresh
package "$scratch/Packages/PebbleKit" PebbleKit
perl -0pi -e 's~dependencies: \[\n~dependencies: [\n        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),\n~' \
  "$scratch/Packages/PebbleKit/Package.swift"
expect fail "swift-syntax in PebbleKit's manifest" "Packages/PebbleKit/Package.swift names swift-syntax"

fresh
printf '{ "pins" : [ { "identity" : "swift-syntax" } ], "version" : 3 }\n' > "$scratch/Packages/PebbleKit/Package.resolved"
expect fail "swift-syntax pinned in PebbleKit's resolved file" "Packages/PebbleKit/Package.resolved names swift-syntax"

fresh
perl -0pi -e 's~PebbleBackground\]~PebbleBackground, SwiftSyntax]~' "$scratch/project.yml"
expect fail "project.yml linking SwiftSyntax" "project.yml names swift-syntax"

fresh
perl -0pi -e 's~PebbleBackground\]~PebbleBackground, PromiseWords]~' "$scratch/project.yml"
expect fail "project.yml linking a test helper" "project.yml links a test helper"

fresh
mkdir -p "$scratch/Pebble.xcodeproj"
printf '\t\tA1 /* GuardScan */ = {isa = XCSwiftPackageProductDependency; productName = GuardScan; };\n' \
  > "$scratch/Pebble.xcodeproj/project.pbxproj"
expect fail "the generated project naming the guard package" "project.pbxproj names swift-syntax"

# A dependency of a dependency: PebbleKit names only Helper, and Helper
# brings in a package called swift-syntax.
fresh
package "$scratch/Deps/swift-syntax" SwiftSyntax
package "$scratch/Deps/Helper" Helper ../swift-syntax
perl -0pi -e 's~product\(name: "swift-syntax", package: "swift-syntax"\)~product(name: "SwiftSyntax", package: "swift-syntax")~' \
  "$scratch/Deps/Helper/Package.swift"
package "$scratch/Packages/PebbleKit" PebbleKit ../../Deps/Helper
expect fail "swift-syntax brought in by a dependency's dependency" "dependency graph holds swift-syntax"

rm -rf "$scratch"
if [ "$failures" -ne 0 ]; then
  echo "graph-check-test: $failures case(s) went the wrong way"
  exit 1
fi
echo "graph-check-test: ok"
