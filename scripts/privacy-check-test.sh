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
#
# Every fixture runs the whole check in a tree of its own, copied from one
# clean copy, as many at once as the Mac has cores. The audit is built once
# in release and every run uses that binary. Runs share one store of
# swift package describe's output, kept by what describe reads, so a run
# only reuses it when Package.swift and the names of the package's files are
# the same. Results print in fixture order, whatever order they finish in.
# PRIVACY_RESULTS, a file, gets one line per fixture (its exit status, how
# often the expected words show and a hash of what the check said), to
# compare two checkers.
set -eu

repo="$(pwd)"
fixtures="$repo/scripts/privacy-fixtures"

# One fixture in its own tree: sh privacy-check-test.sh --fixture <scratch> <fixture>.
# It writes what it says to said, marks ran once the check runs, failed on a
# failure and done last, so a run that stops early counts as a failure.
if [ "${1:-}" = --fixture ]; then
  fixture="$3"
  name="$(basename "$fixture" .swift)"
  scratch="$2/fixtures/$name"
  mkdir -p "$scratch"
  exec > "$scratch/said" 2>&1
  stop() { : > "$scratch/failed"; rm -rf "$scratch/tree"; : > "$scratch/done"; exit 0; }
  header() { sed -n "s#^// $1: *##p" "$fixture" | head -n 1; }
  into="$(header into)"; append="$(header append)"; empty="$(header empty)"
  link="$(header link)"; expect="$(header expect)"; project="$(header project)"
  filename="$(header filename)"; reason="$(header reason)"; remove_category="$(header remove-category)"; category="$(header category)"
  [ -n "$expect" ] || { echo "privacy-check-test: $name has no expect: line"; stop; }
  cp -R "$2/clean" "$scratch/tree"
  if [ -n "$project" ]; then
    cp "$scratch/tree/project.yml" "$scratch/project.before"
    perl -0pi -e "$project" "$scratch/tree/project.yml"
    if cmp -s "$scratch/project.before" "$scratch/tree/project.yml"; then
      echo "privacy-check-test: $name's project: change no longer applies to project.yml"; stop
    fi
  fi
  if [ -n "$into" ]; then
    mkdir -p "$scratch/tree/$into"
    cp "$fixture" "$scratch/tree/$into/${filename:-Fixture$(echo "$name" | tr -d -- '-').swift}"
    if [ -n "$link" ]; then
      perl -0pi -e "s~\.target\(name: \"PebbleModel\", dependencies: \[\"PebbleCore\"\]\),~.target(name: \"PebbleModel\", dependencies: [\"PebbleCore\", \"$link\"]),\n        .target(name: \"$link\"),~" \
        "$scratch/tree/Packages/PebbleKit/Package.swift"
      grep -q "\"$link\"" "$scratch/tree/Packages/PebbleKit/Package.swift" \
        || { echo "privacy-check-test: $name could not link $link; Package.swift changed shape"; stop; }
    fi
  elif [ -n "$append" ]; then
    [ -f "$scratch/tree/$append" ] || { echo "privacy-check-test: $name appends to $append, which is gone"; stop; }
    cat "$fixture" >> "$scratch/tree/$append"
  elif [ -n "$empty" ]; then
    [ -f "$scratch/tree/$empty" ] || { echo "privacy-check-test: $name empties $empty, which is gone"; stop; }
    : > "$scratch/tree/$empty"
  elif [ -z "$project" ]; then
    echo "privacy-check-test: $name has no into:, append: or empty: line"; stop
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
  : > "$scratch/ran"
  status=0
  (cd "$scratch/tree" && sh "${PRIVACY_CHECK_SCRIPT:-$repo/scripts/privacy-check.sh}") > "$scratch/out" 2>&1 || status=$?
  echo "$name rc=$status match=$(grep -cF -- "$expect" "$scratch/out" || true) out=$(sed -E "s#$scratch/tree#S/tree#g; s#/(private/)?var/folders/[^ :]*/T/tmp\.[A-Za-z0-9]+#T#g" "$scratch/out" | shasum | cut -c1-12)" > "$scratch/result"
  if [ "$status" -eq 0 ]; then
    if [ "$expect" != ok ]; then
      echo "privacy-check-test: $name should fail with \"$expect\", but the check passed"
      stop
    fi
  elif [ "$expect" = ok ]; then
    echo "privacy-check-test: $name should pass, but the check failed:"
    sed 's/^/  /' "$scratch/out"
    stop
  elif ! grep -qF -- "$expect" "$scratch/out"; then
    echo "privacy-check-test: $name failed, but without \"$expect\":"
    sed 's/^/  /' "$scratch/out"
    stop
  fi
  rm -rf "$scratch/tree"
  : > "$scratch/done"
  exit 0
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Use the current checker on scratch source trees without rebuilding per case.
# Release, since the audit parses every file each run and debug swift-syntax
# is several times slower at that.
if [ -z "${PRIVACY_CHECK_SCRIPT:-}" ]; then
  swift build -c release --package-path "$repo/Tools/GuardKit" --product privacy-audit --quiet
  PRIVACY_AUDIT_BIN="$(swift build -c release --package-path "$repo/Tools/GuardKit" --show-bin-path)/privacy-audit"
  export PRIVACY_AUDIT_BIN
fi
PRIVACY_DESCRIBE_CACHE="$scratch/describe"
export PRIVACY_DESCRIBE_CACHE
mkdir -p "$PRIVACY_DESCRIBE_CACHE" "$scratch/fixtures" "$scratch/clean/Packages" "$scratch/clean/scripts"
cp "$repo/project.yml" "$scratch/clean/"
cp -R "$repo/App" "$scratch/clean/App"
rsync -a --exclude .build --exclude .swiftpm "$repo/Packages/PebbleKit" "$scratch/clean/Packages/"
cp "$repo/scripts/privacy-file-reads.txt" "$scratch/clean/scripts/"

cp -R "$scratch/clean" "$scratch/unchanged"
if ! (cd "$scratch/unchanged" && sh "${PRIVACY_CHECK_SCRIPT:-$repo/scripts/privacy-check.sh}") > "$scratch/out" 2>&1; then
  echo "privacy-check-test: the check fails on an unchanged copy of the repo:"
  sed 's/^/  /' "$scratch/out"
  exit 1
fi
rm -rf "$scratch/unchanged"

# PRIVACY_FIXTURES picks some by name, such as r3-*, to try them on an
# older checker named by PRIVACY_CHECK_SCRIPT and PRIVACY_AUDIT_BIN.
jobs="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
for fixture in "$fixtures"/${PRIVACY_FIXTURES:-*}.swift; do
  printf '%s\0' "$fixture"
done | xargs -0 -n 1 -P "$jobs" sh "$0" --fixture "$scratch" || true

failures=0
count=0
for fixture in "$fixtures"/${PRIVACY_FIXTURES:-*}.swift; do
  name="$(basename "$fixture" .swift)"
  ran="$scratch/fixtures/$name"
  if [ ! -f "$ran/done" ]; then
    echo "privacy-check-test: $name stopped before it finished:"
    sed 's/^/  /' "$ran/said" 2>/dev/null || true
    failures=1
    continue
  fi
  cat "$ran/said"
  [ ! -f "$ran/ran" ] || count=$((count + 1))
  [ ! -f "$ran/failed" ] || failures=1
  [ -z "${PRIVACY_RESULTS:-}" ] || [ ! -f "$ran/result" ] || cat "$ran/result" >> "$PRIVACY_RESULTS"
done

[ "$count" -gt 0 ] || { echo "privacy-check-test: no fixtures in $fixtures"; exit 1; }
[ "$failures" -eq 0 ] && echo "privacy-check-test: ok ($count fixtures)"
exit "$failures"
