#!/bin/sh
# Fails if a file meant for one machine only is tracked by git, even one
# added past .gitignore with `git add -f`. Config/Cloud.local.xcconfig holds
# a real cloud address and must never be committed. Also fails if any
# tracked Config/*.xcconfig gives PEBBLE_CLOUD_ENDPOINT a value, plain or
# conditional (PEBBLE_CLOUD_ENDPOINT[config=Debug] = ...), or project.yml
# gives it one in its settings, or writes an address straight into the
# Info.plist key, and fails whenever it can't look, a tracked file it
# can't read included, so a broken check never reads as ok.
# Pass a different repository as $1 to check it instead, as the tests do.
set -eu

repo="${1:-.}"
local_only="Config/Cloud.local.xcconfig"

if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "local-config-check: $repo is not a git repository I can read, so I can't check it."
  exit 1
fi

if ! tracked="$(git -C "$repo" ls-files --cached -- "$local_only")"; then
  echo "local-config-check: git couldn't list the tracked files in $repo."
  exit 1
fi
if [ -n "$tracked" ]; then
  echo "local-config-check: $local_only is tracked by git. It holds a real address for one machine."
  echo "Remove it from git with: git rm --cached $local_only"
  exit 1
fi

if ! configs="$(git -C "$repo" ls-files --cached -- 'Config/*.xcconfig')"; then
  echo "local-config-check: git couldn't list the tracked config files in $repo."
  exit 1
fi
# One name per line, so a name with a space is still one file.
while IFS= read -r config; do
  [ -n "$config" ] || continue
  if [ ! -f "$repo/$config" ] || [ ! -r "$repo/$config" ]; then
    echo "local-config-check: can't read the tracked $config, so I can't check it."
    exit 1
  fi
  # The value after "=", with any condition before it and any // comment
  # after it taken off.
  if ! lines="$(sed -n -E 's/^[[:space:]]*PEBBLE_CLOUD_ENDPOINT(\[[^]]*\])*[[:space:]]*=//p' "$repo/$config")"; then
    echo "local-config-check: can't read the tracked $config, so I can't check it."
    exit 1
  fi
  value="$(printf '%s\n' "$lines" | sed 's|//.*||' | tr -d '[:space:]')"
  if [ -n "$value" ]; then
    echo "local-config-check: $config sets PEBBLE_CLOUD_ENDPOINT. A real address goes only in $local_only."
    exit 1
  fi
done <<EOF
$configs
EOF

# project.yml carries build settings too. Under any `settings:` a key of
# PEBBLE_CLOUD_ENDPOINT, plain or conditional, must have no value, and the
# Info.plist key may only pass the setting through, never hold an address.
if ! project="$(git -C "$repo" ls-files --cached -- project.yml)"; then
  echo "local-config-check: git couldn't list project.yml in $repo."
  exit 1
fi
if [ -n "$project" ]; then
  if [ ! -f "$repo/project.yml" ] || [ ! -r "$repo/project.yml" ]; then
    echo "local-config-check: can't read the tracked project.yml, so I can't check it."
    exit 1
  fi
  # The value after the key's colon, with quotes and any # comment taken off.
  values="$(sed -n -E 's/^[[:space:]]*"?PEBBLE_CLOUD_ENDPOINT(\[[^]]*\])*"?[[:space:]]*:(.*)$/\2/p' "$repo/project.yml" \
    | sed 's/[[:space:]]#.*$//' | tr -d "\"'[:space:]")"
  passed="$(sed -n -E 's/^[[:space:]]*PebbleCloudEndpoint[[:space:]]*:(.*)$/\1/p' "$repo/project.yml" \
    | sed 's/[[:space:]]#.*$//' | tr -d "\"'[:space:]" | grep -v -x -F '$(PEBBLE_CLOUD_ENDPOINT)' || true)"
  if [ -n "$values" ] || [ -n "$passed" ]; then
    echo "local-config-check: project.yml sets a cloud address. A real address goes only in $local_only."
    exit 1
  fi
fi
echo "local-config-check: ok ($local_only is not tracked, and no tracked config or project.yml sets an address)"
