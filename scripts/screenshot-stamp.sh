#!/bin/sh
# Ties screenshots to the code they show.
#
#   scripts/screenshot-stamp.sh tree               print the working tree's hash
#   scripts/screenshot-stamp.sh write DIR [TREE]   write DIR/STAMP (TREE: a hash taken earlier)
#   scripts/screenshot-stamp.sh check DIR...       fail unless each DIR/STAMP matches the tree now
#
# The tree hash covers every file git would add, tracked or new, and leaves
# out what .gitignore leaves out. It is made in a throwaway index
# (GIT_INDEX_FILE), so the real index and anything staged stay as they are.
set -eu

tree_hash() {
  scratch="$(mktemp -d)"
  # The throwaway index starts from HEAD, so only changed files are hashed again.
  if git rev-parse --verify -q HEAD >/dev/null; then
    GIT_INDEX_FILE="$scratch/index" git read-tree HEAD
  fi
  GIT_INDEX_FILE="$scratch/index" git add -A
  hash="$(GIT_INDEX_FILE="$scratch/index" git write-tree)"
  rm -rf "$scratch"
  echo "$hash"
}

head_commit() {
  git rev-parse --verify -q HEAD || echo none
}

command="${1:-}"
case "$command" in
  tree)
    tree_hash
    ;;
  write)
    dir="${2:?usage: screenshot-stamp.sh write DIR [TREE]}"
    tree="${3:-$(tree_hash)}"
    mkdir -p "$dir"
    printf 'commit %s\ntree %s\n' "$(head_commit)" "$tree" > "$dir/STAMP"
    echo "screenshots: stamped $dir/STAMP (tree $tree)"
    ;;
  check)
    shift
    [ "$#" -gt 0 ] || { echo "usage: screenshot-stamp.sh check DIR..." >&2; exit 2; }
    now="$(tree_hash)"
    for dir in "$@"; do
      stamp="$dir/STAMP"
      if [ ! -f "$stamp" ]; then
        echo "screenshots are stale, rerun make screenshots ($stamp is missing)" >&2
        exit 1
      fi
      made="$(sed -n 's/^tree //p' "$stamp")"
      if [ "$made" != "$now" ]; then
        echo "screenshots are stale, rerun make screenshots ($dir was made from tree ${made:-unknown}, the tree is now $now)" >&2
        exit 1
      fi
      echo "screenshots: $dir matches the working tree"
    done
    ;;
  *)
    echo "usage: screenshot-stamp.sh tree | write DIR [TREE] | check DIR..." >&2
    exit 2
    ;;
esac
