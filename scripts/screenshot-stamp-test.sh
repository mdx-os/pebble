#!/bin/sh
# Self-test for scripts/screenshot-stamp.sh, in a scratch repository:
# a fresh stamp passes, a missing stamp fails, an edited, new or deleted
# file fails, an ignored file doesn't count, what `make test` and the
# builds write between the stamp and the check doesn't count, the real
# index is never touched, hashing writes nothing into .git/objects, and a
# new commit of the same files keeps the stamp.
set -eu

stamp="$(cd "$(dirname "$0")" && pwd)/screenshot-stamp.sh"
real_ignore="$(cd "$(dirname "$0")/.." && pwd)/.gitignore"
repo="$(mktemp -d)"
# Outside the scratch repository, so the log is never part of its tree.
err="$(mktemp)"
trap 'rm -rf "$repo" "$err"' EXIT
cd "$repo"
git init -q
git config user.email test@example.com
git config user.name test
printf 'build/\n' > .gitignore
echo one > a.txt
git add -A
git commit -q -m start

failures=0
expect() {
  want="$1"; shift
  if sh "$stamp" check build/shots >/dev/null 2>"$err"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    echo "ok: $* ($got)"
  else
    echo "not ok: $* (expected $want, got $got)"; cat "$err"
    failures=$((failures + 1))
  fi
}

expect fail "no stamp yet"
grep -q "screenshots are stale, rerun make screenshots" "$err" || {
  echo "not ok: the message names the fix"; failures=$((failures + 1)); }

sh "$stamp" write build/shots >/dev/null
grep -q "^commit $(git rev-parse HEAD)$" build/shots/STAMP || {
  echo "not ok: the stamp holds the HEAD commit"; failures=$((failures + 1)); }
expect pass "a fresh stamp"

echo ignored > build/other.png
expect pass "an ignored file changed"

echo two > a.txt
expect fail "an edited file"
grep -q "screenshots are stale, rerun make screenshots" "$err" || {
  echo "not ok: the message names the fix"; failures=$((failures + 1)); }
sh "$stamp" write build/shots >/dev/null
expect pass "stamped again after the edit"

echo new > b.txt
expect fail "a new untracked file"
sh "$stamp" write build/shots >/dev/null
rm b.txt
expect fail "a deleted file"

# Something staged in the real index stays exactly as it was.
sh "$stamp" write build/shots >/dev/null
echo staged > c.txt
git add c.txt
before="$(git ls-files -s | shasum)"
sh "$stamp" write build/shots >/dev/null
sh "$stamp" check build/shots >/dev/null
after="$(git ls-files -s | shasum)"
if [ "$before" = "$after" ] && [ -z "$(git diff --cached --name-only | grep -v '^c.txt$' || true)" ]; then
  echo "ok: the real index is untouched"
else
  echo "not ok: the real index changed"; failures=$((failures + 1))
fi

# A new file nobody has added is hashed in memory only: no object for it,
# or for the list of files, is written into .git/objects.
echo "not a real key" > stray.key
objects_before="$(find .git/objects -type f | wc -l)"
sh "$stamp" tree >/dev/null
sh "$stamp" write build/shots >/dev/null
sh "$stamp" check build/shots >/dev/null
objects_after="$(find .git/objects -type f | wc -l)"
if [ "$objects_before" = "$objects_after" ] && ! git cat-file -e "$(git hash-object stray.key)" 2>/dev/null; then
  echo "ok: hashing writes nothing into .git/objects"
else
  echo "not ok: hashing wrote into .git/objects ($objects_before before, $objects_after after)"
  failures=$((failures + 1))
fi
rm stray.key

# Between the stamp and the check, `make verify` runs `make test` and the
# builds. With the repository's own .gitignore, nothing they write counts.
cp "$real_ignore" .gitignore
git add .gitignore
git commit -q -m "real ignore"
sh "$stamp" write build/shots >/dev/null
mkdir -p Packages/PebbleKit/.build/debug Packages/PebbleKit/.swiftpm .swiftpm build/DerivedData Pebble.xcodeproj
echo test > Packages/PebbleKit/.build/debug/PebbleKitPackageTests.xctest
echo test > Packages/PebbleKit/.swiftpm/configuration
echo test > .swiftpm/configuration
echo build > build/DerivedData/info.plist
echo project > Pebble.xcodeproj/project.pbxproj
echo found > .DS_Store
expect pass "what make test and the builds write"

# The tree hash is the contract, not the commit: committing what the
# screenshots show, or amending that commit, changes nothing they show.
git add -A
git commit -q -m "the same files"
git commit -q --amend -m "the same files, amended"
expect pass "a new commit with the same files"

if [ "$failures" -ne 0 ]; then
  echo "screenshot-stamp-test: $failures failed" >&2
  exit 1
fi
echo "screenshot-stamp-test: all passed"
