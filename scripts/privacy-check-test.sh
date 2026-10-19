#!/bin/sh
# Self-test for scripts/privacy-check.sh. Copies what the check reads into a
# scratch tree, requires the check to pass there, then adds each fixture in
# scripts/privacy-fixtures on its own and requires the result its header
# names. This proves the complete runner catches each regression and that
# comments and reviewed uses stay quiet.
#
# Each fixture's header, in // lines at its top:
#   into: <dir>      copy the fixture into this folder of the scratch tree
#   append: <file>   or add it to the end of this file
#   empty: <file>    or empty this file (the fixture's body is unused)
#   link: <target>   with into: a new folder under Sources, make it a target
#                    that PebbleModel depends on, so only a dependency reaches it
#   filename: <name> optional source name, including a non-Swift extension
#   project: <perl>  edit project.yml with this substitution, which must
#                    change it; on its own or with one of the above
#   reason: <code>   replace the first manifest entry's reason code
#   category: <name> replace its category
#   remove-category: <name> remove that manifest entry
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
  (cd "$scratch/tree" && sh "${PRIVACY_CHECK_SCRIPT:-$repo/scripts/privacy-check.sh}") > "$scratch/out" 2>&1
}

# Use the current checker on scratch source trees without rebuilding per case.
if [ -z "${PRIVACY_CHECK_SCRIPT:-}" ]; then
  swift build --package-path "$repo/Tools/GuardKit" --product privacy-audit --quiet
  PRIVACY_AUDIT_BIN="$(swift build --package-path "$repo/Tools/GuardKit" --show-bin-path)/privacy-audit"
  export PRIVACY_AUDIT_BIN
fi
failures=0
fresh
if ! run_check; then
  echo "privacy-check-test: the check fails on an unchanged copy of the repo:"
  sed 's/^/  /' "$scratch/out"
  exit 1
fi

count=0
# PRIVACY_FIXTURES picks some by name, such as r3-*, to try them on an
# older checker named by PRIVACY_CHECK_SCRIPT and PRIVACY_AUDIT_BIN.
for fixture in "$fixtures"/${PRIVACY_FIXTURES:-*}.swift; do
  name="$(basename "$fixture" .swift)"
  header() { sed -n "s#^// $1: *##p" "$fixture" | head -n 1; }
  into="$(header into)"; append="$(header append)"; empty="$(header empty)"
  link="$(header link)"; expect="$(header expect)"; project="$(header project)"
  filename="$(header filename)"; reason="$(header reason)"; remove_category="$(header remove-category)"; category="$(header category)"
  [ -n "$expect" ] || { echo "privacy-check-test: $name has no expect: line"; failures=1; continue; }
  fresh
  if [ -n "$project" ]; then
    cp "$scratch/tree/project.yml" "$scratch/project.before"
    perl -0pi -e "$project" "$scratch/tree/project.yml"
    if cmp -s "$scratch/project.before" "$scratch/tree/project.yml"; then
      echo "privacy-check-test: $name's project: change no longer applies to project.yml"; failures=1; continue
    fi
  fi
  if [ -n "$into" ]; then
    mkdir -p "$scratch/tree/$into"
    cp "$fixture" "$scratch/tree/$into/${filename:-Fixture$(echo "$name" | tr -d -- '-').swift}"
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
  elif [ -z "$project" ]; then
    echo "privacy-check-test: $name has no into:, append: or empty: line"; failures=1; continue
  fi
  python3 -I - "$scratch/tree/App/Resources/PrivacyInfo.xcprivacy" "$reason" "$remove_category" "$category" <<'MANIFEST'
import plistlib, sys
path, reason, remove, category = sys.argv[1:]
with open(path, "rb") as f: manifest = plistlib.load(f)
entries = manifest["NSPrivacyAccessedAPITypes"]
if remove: entries[:] = [e for e in entries if e["NSPrivacyAccessedAPIType"] != remove]
if reason: entries[0]["NSPrivacyAccessedAPITypeReasons"] = [reason]
if category: entries[0]["NSPrivacyAccessedAPIType"] = category
with open(path, "wb") as f: plistlib.dump(manifest, f)
MANIFEST
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
