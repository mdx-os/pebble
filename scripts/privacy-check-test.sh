#!/bin/sh
# Self-test for scripts/privacy-check.sh. Copies what the check reads into a
# scratch tree, requires the check to pass there, then adds each fixture in
# scripts/privacy-fixtures on its own and requires the result its header
# names. That proves each pattern still catches its case under the system's
# grep, and that comments and allowed uses stay quiet.
#
# Each fixture's header, in // lines at its top:
#   into: <dir>      copy the fixture into this folder of the scratch tree
#   append: <file>   or add it to the end of this file
#   empty: <file>    or empty this file (the fixture's body is unused)
#   link: <target>   with into: a new folder under Sources, make it a target
#                    that PebbleModel depends on, so only a dependency reaches it
#   expect: <words>  privacy-check must fail and say these words, or "ok"
#                    to require it to pass
set -eu

repo="$(pwd)"
fixtures="$repo/scripts/privacy-fixtures"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fresh() {
  rm -rf "$scratch/tree"
  mkdir -p "$scratch/tree/Packages" "$scratch/tree/scripts"
  cp "$repo/project.yml" "$scratch/tree/"
  cp -R "$repo/App" "$scratch/tree/App"
  rsync -a --exclude .build --exclude .swiftpm "$repo/Packages/PebbleKit" "$scratch/tree/Packages/"
  cp "$repo/scripts/privacy-file-reads.txt" "$scratch/tree/scripts/"
}

run_check() {
  (cd "$scratch/tree" && sh "$repo/scripts/privacy-check.sh") > "$scratch/out" 2>&1
}

failures=0
fresh
if ! run_check; then
  echo "privacy-check-test: the check fails on an unchanged copy of the repo:"
  sed 's/^/  /' "$scratch/out"
  exit 1
fi

count=0
for fixture in "$fixtures"/*.swift; do
  name="$(basename "$fixture" .swift)"
  header() { sed -n "s#^// $1: *##p" "$fixture" | head -n 1; }
  into="$(header into)"; append="$(header append)"; empty="$(header empty)"
  link="$(header link)"; expect="$(header expect)"
  [ -n "$expect" ] || { echo "privacy-check-test: $name has no expect: line"; failures=1; continue; }
  fresh
  if [ -n "$into" ]; then
    mkdir -p "$scratch/tree/$into"
    cp "$fixture" "$scratch/tree/$into/Fixture$(echo "$name" | tr -d -- '-').swift"
    if [ -n "$link" ]; then
      perl -0pi -e "s~\.target\(name: \"PebbleModel\", dependencies: \[\"PebbleCore\"\]\),~.target(name: \"PebbleModel\", dependencies: [\"PebbleCore\", \"$link\"]),\n        .target(name: \"$link\"),~" \
        "$scratch/tree/Packages/PebbleKit/Package.swift"
      grep -q "\"$link\"" "$scratch/tree/Packages/PebbleKit/Package.swift" \
        || { echo "privacy-check-test: $name could not link $link; Package.swift changed shape"; failures=1; continue; }
    fi
  elif [ -n "$append" ]; then
    [ -f "$scratch/tree/$append" ] || { echo "privacy-check-test: $name appends to $append, which is gone"; failures=1; continue; }
    cat "$fixture" >> "$scratch/tree/$append"
  elif [ -n "$empty" ]; then
    [ -f "$scratch/tree/$empty" ] || { echo "privacy-check-test: $name empties $empty, which is gone"; failures=1; continue; }
    : > "$scratch/tree/$empty"
  else
    echo "privacy-check-test: $name has no into:, append: or empty: line"; failures=1; continue
  fi
  count=$((count + 1))
  if run_check; then
    if [ "$expect" != ok ]; then
      echo "privacy-check-test: $name should fail with \"$expect\", but the check passed"
      failures=1
    fi
  elif [ "$expect" = ok ]; then
    echo "privacy-check-test: $name should pass, but the check failed:"
    sed 's/^/  /' "$scratch/out"
    failures=1
  elif ! grep -qF -- "$expect" "$scratch/out"; then
    echo "privacy-check-test: $name failed, but without \"$expect\":"
    sed 's/^/  /' "$scratch/out"
    failures=1
  fi
done

[ "$count" -gt 0 ] || { echo "privacy-check-test: no fixtures in $fixtures"; exit 1; }
[ "$failures" -eq 0 ] && echo "privacy-check-test: ok ($count fixtures)"
exit "$failures"
