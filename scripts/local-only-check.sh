#!/bin/sh
# Fails if the app or the on-device model adapter names a network client.
set -eu

for dir in App Packages/PebbleKit/Sources/PebbleModel; do
  if [ ! -d "$dir" ]; then
    echo "local-only-check: missing $dir"
    exit 1
  fi
done

pattern='HubClient|InferenceClient|snapshot\(|from\(pretrained:|URLSession'
if hits="$(grep -RInE -e "$pattern" App Packages/PebbleKit/Sources/PebbleModel)"; then
  echo "local-only-check: a network client is mentioned in the app or model adapter:"
  echo "$hits"
  exit 1
fi
echo "local-only-check: ok"
