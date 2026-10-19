#!/bin/sh
# Fails on a mutation entry that is shaped wrong, before anything is built.
# A merge that keeps both sides of a file's tail (see .gitattributes) can
# join two entries into one or drop a line, and mutation-check would then
# break the wrong thing, or nothing. Each entry, a block of lines between
# blank lines, must have exactly one test: line naming at least one test,
# exactly one file: line naming a file that exists, and at least one perl:
# line. A block of comments alone is not an entry.
#
# Usage: scripts/mutation-manifest-check.sh [file...]
# With no files it reads scripts/mutation-manifest.txt and every
# scripts/mutation/*.txt. MUTATION_ROOT is where file: paths are found
# (default: the repository).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
base="${MUTATION_ROOT:-$root}"

if [ "$#" -eq 0 ]; then
  set -- "$root/scripts/mutation-manifest.txt"
  for area in "$root"/scripts/mutation/*.txt; do
    if [ -f "$area" ]; then set -- "$@" "$area"; fi
  done
fi

bad=0
entries=0

# The name to report a source by: its path in the repository if it is in it.
named() {
  case "$1" in
    "$root"/*) echo "${1#"$root"/}" ;;
    *) echo "$1" ;;
  esac
}

problem() {
  echo "mutation-manifest-check: $where: $1"
  bad=$((bad + 1))
}

# Checks the block that just ended, if it held anything but comments.
finish() {
  if [ "$lines" -eq 0 ]; then return 0; fi
  entries=$((entries + 1))
  if [ "$tests" -eq 0 ]; then problem "an entry with no test: line"; fi
  if [ "$tests" -gt 1 ]; then problem "$tests test: lines, two entries may have run together"; fi
  if [ "$tests" -eq 1 ] && [ -z "$(printf '%s' "$named_tests" | tr -d ' ')" ]; then
    problem "a test: line that names no test"
  fi
  if [ "$files" -eq 0 ]; then problem "an entry with no file: line"; fi
  if [ "$files" -gt 1 ]; then problem "$files file: lines, two entries may have run together"; fi
  if [ "$files" -eq 1 ] && [ ! -f "$base/$file" ]; then problem "no file $file"; fi
  if [ "$perls" -eq 0 ]; then problem "an entry with no perl: line"; fi
}

for source in "$@"; do
  name="$(named "$source")"
  if [ ! -r "$source" ]; then
    echo "mutation-manifest-check: can't read $name"
    exit 1
  fi
  number=0
  start=0
  lines=0 tests=0 files=0 perls=0 file="" named_tests=""
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if [ "$lines" -eq 0 ]; then start="$number"; fi
    where="$name:$start"
    case "$line" in
      "")
        finish
        lines=0 tests=0 files=0 perls=0 file="" named_tests=""
        ;;
      "#"*) ;;
      "test: "*) lines=$((lines + 1)) tests=$((tests + 1)) named_tests="${line#test: }" ;;
      "file: "*) lines=$((lines + 1)) files=$((files + 1)) file="${line#file: }" ;;
      "perl: "*) lines=$((lines + 1)) perls=$((perls + 1)) ;;
      *)
        where="$name:$number"
        problem "a line that is not a comment, test:, file: or perl: line: $line"
        lines=$((lines + 1))
        ;;
    esac
  done < "$source"
  where="$name:$start"
  finish
done

if [ "$bad" -ne 0 ]; then
  echo "mutation-manifest-check: $bad problem(s) in $entries entries"
  exit 1
fi
echo "mutation-manifest-check: ok, $entries entries in $# file(s)"
