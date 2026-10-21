#!/bin/sh
# Fails if a file meant for one machine only is tracked by git, even one
# added past .gitignore with `git add -f`. Config/Cloud.local.xcconfig holds
# a real cloud address and must never be committed. Also fails if any
# tracked Config/*.xcconfig gives PEBBLE_CLOUD_ENDPOINT a value, plain or
# conditional (PEBBLE_CLOUD_ENDPOINT[config=Debug] = ...), or project.yml
# names either key in any shape but the empty setting and the pass
# through, or a tracked plist, App/Info.plist among them, gives the
# PebbleCloudEndpoint key a value of its own. It fails whenever it can't
# look, a tracked file it can't read included, so a broken check never
# reads as ok.
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

# project.yml carries build settings too. Every line that names either key,
# with quotes, blanks and any # comment taken off, must be one of the
# shapes that set nothing: PEBBLE_CLOUD_ENDPOINT, plain or conditional,
# with no value, or the Info.plist key passing the setting through or
# empty. Anything else fails, a value, a quoted key with one, or a key in
# an inline {...} map among them, so a shape this doesn't know never
# reads as clean.
if ! project="$(git -C "$repo" ls-files --cached -- project.yml)"; then
  echo "local-config-check: git couldn't list project.yml in $repo."
  exit 1
fi
if [ -n "$project" ]; then
  if [ ! -f "$repo/project.yml" ] || [ ! -r "$repo/project.yml" ]; then
    echo "local-config-check: can't read the tracked project.yml, so I can't check it."
    exit 1
  fi
  # Compared as plain strings, conditions taken off one by one, so no
  # regex dialect can read a shape differently.
  if ! LC_ALL=C awk '
    {
      line = $0
      sub(/^[[:space:]]*#.*$/, "", line)
      sub(/[[:space:]]#.*$/, "", line)
    }
    index(line, "PEBBLE_CLOUD_ENDPOINT") || index(line, "PebbleCloudEndpoint") {
      gsub(/["\047[:space:]]/, "", line)
      if (line == "PebbleCloudEndpoint:" || line == "PebbleCloudEndpoint:$(PEBBLE_CLOUD_ENDPOINT)") next
      if (substr(line, 1, 21) == "PEBBLE_CLOUD_ENDPOINT") {
        rest = substr(line, 22)
        while (substr(rest, 1, 1) == "[" && index(rest, "]")) rest = substr(rest, index(rest, "]") + 1)
        if (rest == ":") next
      }
      bad = 1
    }
    END { exit bad ? 1 : 0 }
  ' "$repo/project.yml"; then
    echo "local-config-check: project.yml sets a cloud address. A real address goes only in $local_only."
    exit 1
  fi
fi

# A tracked Info.plist can hold an address under PebbleCloudEndpoint
# whatever the settings say. The key's value may only pass the setting
# through or be empty, and any other line naming the key fails. A plist
# that isn't XML, which this can't read line by line, fails too.
if ! plists="$(git -C "$repo" ls-files --cached -- '*.plist')"; then
  echo "local-config-check: git couldn't list the tracked plists in $repo."
  exit 1
fi
while IFS= read -r plist; do
  [ -n "$plist" ] || continue
  if [ ! -f "$repo/$plist" ] || [ ! -r "$repo/$plist" ]; then
    echo "local-config-check: can't read the tracked $plist, so I can't check it."
    exit 1
  fi
  # One that isn't XML can't be read for the key line by line.
  if ! LC_ALL=C grep -q '<plist' "$repo/$plist"; then
    echo "local-config-check: the tracked $plist isn't an XML plist, so I can't check it."
    exit 1
  fi
  LC_ALL=C grep -q 'PebbleCloudEndpoint' "$repo/$plist" || continue
  if ! LC_ALL=C awk '
    { line = $0; gsub(/[[:space:]]/, "", line) }
    want {
      if (line == "") next
      if (line != "<string>$(PEBBLE_CLOUD_ENDPOINT)</string>" && line != "<string></string>" && line != "<string/>") bad = 1
      want = 0
      next
    }
    line == "<key>PebbleCloudEndpoint</key>" { want = 1; next }
    /PebbleCloudEndpoint/ { bad = 1 }
    END { exit (bad || want) ? 1 : 0 }
  ' "$repo/$plist"; then
    echo "local-config-check: $plist gives PebbleCloudEndpoint a value. A real address goes only in $local_only."
    exit 1
  fi
done <<EOF
$plists
EOF
echo "local-config-check: ok ($local_only is not tracked, and no tracked config, project.yml or plist sets an address)"
