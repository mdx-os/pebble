#!/bin/sh
# Ties screenshots to the code they show.
#
#   scripts/screenshot-stamp.sh tree               print the working tree's hash
#   scripts/screenshot-stamp.sh write DIR [TREE]   write DIR/STAMP (TREE: a hash taken earlier)
#   scripts/screenshot-stamp.sh check DIR...       fail unless each DIR/STAMP matches the tree now
#
# The tree hash covers every file git would add, tracked or new, and leaves
# out what .gitignore leaves out. It is worked out in memory only: each
# file is hashed with `git hash-object` without -w, and so is the list of
# them, so nothing is written into .git/objects (an untracked file that
# should have been ignored, such as a stray key, never lands there as a
# loose object) and the real index and anything staged stay as they are.
set -eu

tree_hash() {
  # Paths are read one per line, so a path with a new line in it would
  # hash wrongly, and a symlink is hashed by what it points to, not as a
  # link. Only plain files are hashed, so a change inside a submodule or a
  # nested repository, which git lists as one path that is not a file, or
  # not at all, never makes the screenshots stale. The repository has none
  # of these; keep it that way.
  scratch="$(mktemp -d)"
  # Tracked files still on disk, and new files .gitignore doesn't leave out.
  # A deleted file isn't listed, so deleting one changes the hash too.
  git ls-files -z --cached --others --exclude-standard | tr '\0' '\n' | LC_ALL=C sort -u |
    while IFS= read -r path; do
      if [ -f "$path" ]; then printf '%s\n' "$path"; fi
    done > "$scratch/paths"
  while IFS= read -r path; do
    if [ -x "$path" ]; then echo 100755; else echo 100644; fi
  done < "$scratch/paths" > "$scratch/modes"
  git hash-object --stdin-paths < "$scratch/paths" > "$scratch/blobs"
  hash="$(paste -d ' ' "$scratch/modes" "$scratch/blobs" "$scratch/paths" | git hash-object --stdin)"
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
