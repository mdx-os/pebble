#!/bin/sh
# Self-test for scripts/screenshot-stamp.sh, in a scratch repository:
# a fresh stamp passes, a missing stamp fails, an edited, new or deleted
# file fails, an ignored file doesn't count, and the real index is never
# touched.
set -eu

stamp="$(cd "$(dirname "$0")" && pwd)/screenshot-stamp.sh"
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

if [ "$failures" -ne 0 ]; then
  echo "screenshot-stamp-test: $failures failed" >&2
  exit 1
fi
echo "screenshot-stamp-test: all passed"
