#!/bin/sh
# Self-test for scripts/local-only-check.sh, on a scratch copy of the
# folders it reads. The clean copy must pass; each planted network client
# must fail it. Run by make verify.
set -eu

check="$(pwd)/scripts/local-only-check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Packages/PebbleKit" "$work/Packages/MLXLM"
cp -R App "$work/App"
cp -R Packages/PebbleKit/Sources "$work/Packages/PebbleKit/Sources"
cp -R Packages/MLXLM/Sources "$work/Packages/MLXLM/Sources"

failures=0

passes() {
  if ! sh "$check" "$work" > "$work/out" 2>&1; then
    echo "local-only-check-test: $1 should pass, but failed:"
    cat "$work/out"
    failures=$((failures + 1))
  fi
}

# Puts $2 into the file $1 (relative to the copy), runs the check, and
# takes it out again. The check must fail.
fails_with() {
  file="$work/$1"
  existed=no
  if [ -f "$file" ]; then
    existed=yes
    cp "$file" "$work/saved"
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$2" >> "$file"
  if sh "$check" "$work" > "$work/out" 2>&1; then
    echo "local-only-check-test: \"$2\" in $1 should fail the check, but it passed."
    failures=$((failures + 1))
  fi
  if [ "$existed" = yes ]; then mv "$work/saved" "$file"; else rm -f "$file"; fi
}

passes "the tree as it is"

fails_with App/Sources/Leak.swift 'let session = URLSession.shared'
fails_with Packages/PebbleKit/Sources/PebbleCore/Leak.swift 'let session = URLSession.shared'
fails_with Packages/PebbleKit/Sources/PebbleBackground/Leak.swift 'let session = URLSession.shared'
fails_with Packages/PebbleKit/Sources/PebbleModel/MLXChatModel.swift 'let session = URLSession.shared'
fails_with Packages/PebbleKit/Sources/PebbleModel/OnDeviceModel.swift '// URLSession'
# The same file name in another folder is not the allowed file.
fails_with Packages/PebbleKit/Sources/PebbleModel/Other/ModelDownload.swift 'let session = URLSession.shared'
fails_with App/Sources/ModelDownload.swift 'let session = URLSession.shared'
# Hub clients and snapshots fail even in the allowed files.
fails_with Packages/PebbleKit/Sources/PebbleModel/ModelDownload.swift 'let hub = HubClient()'
fails_with Packages/PebbleKit/Sources/PebbleModel/ModelDownload.swift 'try await snapshot(from: repo)'
fails_with Packages/PebbleKit/Sources/PebbleModel/MLXChatModel.swift 'let folder = try await hub.snapshot( from: repo, matching: ["*.json"])'
fails_with Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift 'let model = try await from(pretrained: id)'
fails_with Packages/PebbleKit/Sources/PebbleCore/Leak.swift 'import Network'
# The copied MLX libraries ship in the app too.
fails_with Packages/MLXLM/Sources/MLXLMCommon/Leak.swift 'let session = URLSession.shared'
fails_with Packages/MLXLM/Sources/MLXLLM/Leak.swift 'let hub = HubClient()'

passes "the tree with every planted line taken out"

# A task's own snapshot is not a download.
printf '%s\n' 'let made = snapshot(advancing: false)' >> "$work/Packages/PebbleKit/Sources/PebbleCore/Tasks.swift"
passes "a task snapshot"

# A missing allowed file must fail, so its name can't be taken over.
mv "$work/Packages/PebbleKit/Sources/PebbleModel/ModelDownload.swift" "$work/moved"
if sh "$check" "$work" > "$work/out" 2>&1; then
  echo "local-only-check-test: a missing allowed file should fail the check, but it passed."
  failures=$((failures + 1))
fi
mv "$work/moved" "$work/Packages/PebbleKit/Sources/PebbleModel/ModelDownload.swift"

if [ "$failures" -gt 0 ]; then
  echo "local-only-check-test: $failures case(s) wrong"
  exit 1
fi
echo "local-only-check-test: ok"
