#!/bin/sh
# Fails if the app, the plain types, the background runner or the model
# adapter names a network client.
#
# Two files may name URLSession, each by its exact path:
#   PebbleModel/ModelDownload.swift  fetches the pinned model files, only
#                                    when the person taps Download
#   PebbleModel/CloudModel.swift     the cloud model, off until the person
#                                    turns it on, every request shown first
# Anywhere else, URLSession fails, and so does a file of the same name in
# another folder. Hub clients and model snapshot downloads fail everywhere,
# those two files included.
#
#   sh scripts/local-only-check.sh [root]
#
# root defaults to the current folder; scripts/local-only-check-test.sh
# runs it on a scratch copy.
set -eu

root="${1:-.}"
cd "$root"

dirs="App Packages/PebbleKit/Sources/PebbleCore Packages/PebbleKit/Sources/PebbleModel Packages/PebbleKit/Sources/PebbleBackground"
allowed="Packages/PebbleKit/Sources/PebbleModel/ModelDownload.swift Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift"

for dir in $dirs; do
  if [ ! -d "$dir" ]; then
    echo "local-only-check: missing $dir"
    exit 1
  fi
done
# A file allowed here that is gone would leave its name free for anything.
for file in $allowed; do
  if [ ! -f "$file" ]; then
    echo "local-only-check: $file is allowed to name URLSession but is missing. Update the list in this script."
    exit 1
  fi
done

banned='HubClient|InferenceClient|snapshot\(|from\(pretrained:|import Network|NWConnection|NWPathMonitor'
# shellcheck disable=SC2086
if hits="$(grep -RInE -e "$banned" $dirs)"; then
  echo "local-only-check: a network client is mentioned in the app, the plain types, the background runner or the model adapter:"
  echo "$hits"
  exit 1
fi

# Each hit is "path:line:text"; a hit is allowed only when its whole path
# is one of the allowed paths.
exact="^($(printf '%s\n' $allowed | sed 's/[.]/[.]/g' | paste -sd '|' -)):"
# shellcheck disable=SC2086
outside="$(grep -RIn -e 'URLSession' $dirs | grep -vE "$exact" || true)"
if [ -n "$outside" ]; then
  echo "local-only-check: URLSession is named outside the model download and the cloud model:"
  echo "$outside"
  exit 1
fi
echo "local-only-check: ok"
