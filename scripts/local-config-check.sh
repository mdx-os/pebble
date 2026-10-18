#!/bin/sh
# Fails if a file meant for one machine only is tracked by git, even one
# added past .gitignore with `git add -f`. Config/Cloud.local.xcconfig holds
# a real cloud address and must never be committed.
# Pass a different repository as $1 to check it instead, as the tests do.
set -eu

repo="${1:-.}"
local_only="Config/Cloud.local.xcconfig"

if tracked="$(git -C "$repo" ls-files --cached -- "$local_only")" && [ -n "$tracked" ]; then
  echo "local-config-check: $local_only is tracked by git. It holds a real address for one machine."
  echo "Remove it from git with: git rm --cached $local_only"
  exit 1
fi
echo "local-config-check: ok ($local_only is not tracked)"
