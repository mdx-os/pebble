#!/bin/sh
# Keeps App/Resources/PrivacyInfo.xcprivacy, the export answer and the
# promise that personal content stays on the device true to the code.
#
# Reads every source file the app ships: App/ and each PebbleKit target the
# app links, followed through its dependencies (`swift package describe`),
# so code a linked target pulls in is read too. Whole-line // comments are
# blanked first, so a mention in a comment counts for nothing. Fails when:
#
# - a required-reason API is used without its category in the manifest, or
#   the manifest names a category the code no longer uses
# - network code appears outside the opt-in cloud client ($cloud_files)
# - the cloud client's transport is made anywhere but $transport_gate, or
#   there outside the cloud setting's gate, or the tests that prove the gate
#   are gone
# - a system API that uploads the person's data to Apple is used
# - the app brings its own encryption or certificate pinning, which would
#   make ITSAppUsesNonExemptEncryption = NO untrue
#
# Run from the repo root. With --network-files it prints, once every check
# passes, the shipped files that hold network code, for release-check.
# `make privacy-check-test` runs it on a scratch copy
# with each fixture in scripts/privacy-fixtures and requires it to fail.
set -eu

manifest="App/Resources/PrivacyInfo.xcprivacy"
package="Packages/PebbleKit"
# The opt-in cloud client: the only file allowed network code. It reaches
# the network only after the person turns the cloud on (PrivacyPlace says
# the chat may leave the device) and says send to each preview.
cloud_files="$package/Sources/PebbleModel/CloudModel.swift"
# The only file that may make the cloud client's transport, and only inside
# ModelChoice.model's cloud closure, which runs only with the setting on.
transport_gate="$package/Sources/PebbleUI/CloudHelpView.swift"
# The tests that fail if a transport is made with the setting off.
gate_tests="$package/Tests/PebbleUITests/CloudHelpTests.swift"
gate_test_names="offByDefaultMakesNoTransportAndKeepsChatsOnDevice anEmptyAddressMeansDisabledEvenIfSavedOn"
# Data(contentsOf:) and String(contentsOf:) read a remote URL as readily as
# a file. Each one the app ships is listed here, as "path: line", once
# someone has read it and seen that it reads a file.
file_reads="scripts/privacy-file-reads.txt"

status=0
fail() { echo "privacy-check: $*"; status=1; }
show() { sed 's/^/  /'; }

plutil -lint -s "$manifest" || { echo "privacy-check: $manifest is not a valid plist"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The products the app links, from project.yml.
products="$(sed -n 's/^ *products: *\[\(.*\)\]/\1/p' project.yml | tr -d ' ' | tr ',' ' ')"
[ -n "$products" ] || { echo "privacy-check: no package products found in project.yml"; exit 1; }

# Every source file of those products' targets and everything they depend
# on. A dependency on another package can't be read here, so it fails.
swift package --package-path "$package" describe --type json > "$work/package.json" \
  || { echo "privacy-check: swift package describe failed for $package"; exit 1; }
# shellcheck disable=SC2086
python3 -I -c '
import json, sys
described_path, package, products = sys.argv[1], sys.argv[2], sys.argv[3:]
described = json.load(open(described_path))
targets = {t["name"]: t for t in described["targets"]}
by_product = {p["name"]: p["targets"] for p in described["products"]}
todo, seen = [], []
for product in products:
    if product not in by_product:
        sys.exit("privacy-check: project.yml links %s, which %s does not make" % (product, package))
    todo += by_product[product]
while todo:
    name = todo.pop()
    if name in seen:
        continue
    seen.append(name)
    target = targets[name]
    if target.get("product_dependencies"):
        sys.exit("privacy-check: %s depends on %s from another package, which this check cannot read. Review it, then teach this script to scan it." % (name, ", ".join(target["product_dependencies"])))
    todo += target.get("target_dependencies", [])
    for source in target["sources"]:
        path = "%s/%s/%s" % (package, target["path"], source)
        if any(c.isspace() for c in path):
            sys.exit("privacy-check: %s has a space in its path" % path)
        print(path)
print(" ".join(sorted(seen)), file=sys.stderr)
' "$work/package.json" "$package" $products > "$work/files" 2> "$work/targets" || { cat "$work/targets"; exit 1; }
find App -type f \( -name '*.swift' -o -name '*.m' -o -name '*.c' -o -name '*.h' \) | sort >> "$work/files"

# Copies with whole-line // comments blanked, so line numbers still match.
mkdir -p "$work/src"
while read -r file; do
  mkdir -p "$work/src/$(dirname "$file")"
  sed -E 's#^[[:space:]]*//.*$##' "$file" > "$work/src/$file"
done < "$work/files"
files="$(tr '\n' ' ' < "$work/files")"

# The lines matching $1, as path:line:text, in the shipped code.
scan() {
  # shellcheck disable=SC2086
  (cd "$work/src" && grep -nE -e "$1" $files /dev/null) || true
}
# The same, leaving out the files named in $2.
scan_outside() {
  scan "$1" | while IFS= read -r hit; do
    case " $2 " in *" ${hit%%:*} "*) ;; *) echo "$hit" ;; esac
  done
}

# Required-reason APIs. Each declared category with its reason codes, one per line.
declared="$(python3 -I -c '
import plistlib, re, sys
manifest = plistlib.load(open(sys.argv[1], "rb"))
if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains") or manifest.get("NSPrivacyCollectedDataTypes"):
    sys.exit("the manifest now claims tracking or collection; this script and docs/RELEASE.md need a look")
for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
    reasons = [r for r in entry.get("NSPrivacyAccessedAPITypeReasons", []) if re.fullmatch(r"[0-9A-F]{4}\.\d", r)]
    print(entry["NSPrivacyAccessedAPIType"], " ".join(reasons))
' "$manifest")" || { echo "privacy-check: could not read $manifest"; exit 1; }

# Patterns follow Apple's list at
# developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
check() {
  category="$1"; pattern="$2"
  hits="$(scan "$pattern")"
  line="$(echo "$declared" | grep "^$category " || true)"
  if [ -n "$hits" ] && [ -z "$line" ]; then
    fail "this code uses a required-reason API ($category) with no entry in $manifest:"
    echo "$hits" | show
    echo "  Add the category with a reason code that is true for the app."
  elif [ -z "$hits" ] && [ -n "$line" ]; then
    fail "$manifest declares $category, but no code uses it. Remove the entry."
  elif [ -n "$line" ] && [ "$line" = "$category " ]; then
    fail "$category in $manifest has no valid reason code."
  fi
}

check NSPrivacyAccessedAPICategoryUserDefaults \
  '\bUserDefaults\b|NSUserDefaults|@AppStorage'
check NSPrivacyAccessedAPICategoryFileTimestamp \
  '\bcreationDate\b|\bmodificationDate\b|fileModificationDate|fileCreationDate|contentModificationDate|creationDateKey|attributesOfItem|getattrlist|setattrlist|\b(f|l)?stat(at)?\('
check NSPrivacyAccessedAPICategorySystemBootTime \
  'systemUptime|mach_absolute_time'
check NSPrivacyAccessedAPICategoryDiskSpace \
  'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize|attributesOfFileSystem|\bstatv?fs\('
check NSPrivacyAccessedAPICategoryActiveKeyboards \
  'activeInputModes'

# Network code. "Data Not Collected" and the device promise hold only while
# the network is reached by the cloud client alone, after the person's yes.
for file in $cloud_files $transport_gate; do
  grep -qxF "$file" "$work/files" || fail "$file is named here but the app no longer ships it. Update this script."
done
network='\bURLSession(Configuration|Task|DataTask|UploadTask|DownloadTask|StreamTask|WebSocketTask|Delegate|TaskDelegate|DataDelegate|DownloadDelegate|StreamDelegate|WebSocketDelegate|TaskMetrics)?\b|\b(NS|NSMutable)?URLRequest\b|\bNSURLConnection\b|\bimport +(Network|FoundationNetworking|AsyncHTTPClient|NIO[A-Za-z]*)\b|\b(NWConnection|NWListener|NWBrowser|NWPathMonitor|NWEndpoint)\b|\bCFNetwork\b|\bCF(Read|Write)?Stream(CreatePairWithSocket|CreateForHTTPRequest)|\bCFHTTPMessage|\bAsyncHTTPClient\b|\bHTTPClient\b|\bWKWebView\b|\bSFSafariViewController\b|\bASWebAuthenticationSession\b'
if hits="$(scan_outside "$network" "$cloud_files")" && [ -n "$hits" ]; then
  fail "network code outside the opt-in cloud client ($cloud_files):"
  echo "$hits" | show
  echo "  Personal content leaves the device only through the cloud client, after the person turns it on."
  echo "  Move this there, or if it must live elsewhere, review the manifest, docs/RELEASE.md and this script first."
fi

# Data(contentsOf:) and String(contentsOf:) fetch a remote URL as readily as
# a file, so each one must be listed in $file_reads.
reads='\b(NS)?(Data|String)\(contentsOf:'
scan "$reads" | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1: /' | sort -u > "$work/reads"
grep -v '^$' "$file_reads" | grep -v '^#' > "$work/reads-known" || true
if new="$(grep -vxF -f "$work/reads-known" "$work/reads")" && [ -n "$new" ]; then
  fail "a read by contents of a URL that no one has checked. If it reads a file on the device, add the line to $file_reads; if it reads the network, it belongs in the cloud client:"
  echo "$new" | show
fi
if stale="$(grep -vxF -f "$work/reads" "$work/reads-known")" && [ -n "$stale" ]; then
  fail "these lines in $file_reads no longer match any code. Take them out:"
  echo "$stale" | show
fi

# The transport is made in one place, inside the cloud setting's gate.
maker='\bURLSessionCloudTransport\(|\bCloudModel\('
if hits="$(scan_outside "$maker" "$cloud_files $transport_gate")" && [ -n "$hits" ]; then
  fail "the cloud client is made outside $transport_gate, where the cloud setting gates it:"
  echo "$hits" | show
fi
# In the gate's file, each use of the transport maker sits in the closure
# ModelChoice.model calls only with the setting on.
if [ -f "$work/src/$transport_gate" ]; then
  ungated="$(awk '
    /ModelChoice\.model\(/ { gate = NR }
    /makeTransport/ && !/let makeTransport|self\.makeTransport = / {
      if (!gate || NR - gate > 8) print FILENAME ":" NR ":" $0
    }' "$work/src/$transport_gate")"
  if [ -n "$ungated" ]; then
    fail "a transport is made outside ModelChoice.model's cloud closure:"
    echo "$ungated" | show
  fi
  grep -q 'ModelChoice\.model(' "$work/src/$transport_gate" \
    || fail "$transport_gate no longer asks ModelChoice.model, so nothing gates the transport on the cloud setting"
fi
if [ -f "$gate_tests" ]; then
  for name in $gate_test_names; do
    awk -v name="$name" '
      $0 ~ "func " name "\\(" { inside = 1 }
      inside && /maker\.made == 0/ { found = 1; exit }
      inside && /@Test/ && !($0 ~ name) { exit }
      END { exit !found }' "$gate_tests" \
      || fail "$gate_tests must keep $name, which expects maker.made == 0: no transport with the cloud setting off"
  done
else
  fail "$gate_tests is gone; it holds the tests that no transport is made with the cloud setting off"
fi

# System APIs that send what the person says or where they are to Apple.
uploads='\bCLGeocoder\b|\bMKLocalSearch[A-Za-z]*\b|\bMKDirections\b|\bMKLookAround[A-Za-z]*\b'
if hits="$(scan "$uploads")" && [ -n "$hits" ]; then
  fail "a system API that sends the person's data to Apple's servers:"
  echo "$hits" | show
  echo "  Private by default: this needs the person's yes and a new look at $manifest and docs/RELEASE.md."
fi
for file in $(scan '\bSFSpeechRecognizer\b' | cut -d: -f1 | sort -u); do
  if ! grep -qE 'requiresOnDeviceRecognition *= *true' "$work/src/$file"; then
    fail "$file uses SFSpeechRecognizer without requiresOnDeviceRecognition = true, so speech can go to Apple's servers"
  fi
done

# Encryption. ITSAppUsesNonExemptEncryption = NO is true only while TLS and
# every cipher come from the system.
crypto='\bimport +(CryptoKit|CommonCrypto|Crypto|_CryptoExtras|NIOSSL|BoringSSL|CNIOBoringSSL)\b|\bCryptoKit\b|\bCommonCrypto\b|\bCC(Crypt|Hmac|KeyDerivation)[A-Za-z]*\(|\bSecKeyCreateEncryptedData\b|\bSecKeyEncrypt\b|\bNIOSSL\b|\bBoringSSL\b|\bserverTrust\b|\bSecTrustEvaluate[A-Za-z]*\b|\bSecTrustSetAnchorCertificates\b|\bSecCertificateCopyData\b|\bSecTrustCopy(Key|CertificateChain)\b|[Pp]inned(Certificates|Keys|Domains)\b|didReceive +challenge|\bURLAuthenticationChallenge\b'
if hits="$(scan "$crypto")" && [ -n "$hits" ]; then
  fail "the app brings its own encryption or certificate pinning:"
  echo "$hits" | show
  echo "  ITSAppUsesNonExemptEncryption = NO in project.yml holds only while TLS and crypto come from the system."
  echo "  Read \"Encryption\" in docs/RELEASE.md and answer export compliance again before this ships."
fi

if [ "${1:-}" = --network-files ]; then
  # For release-check: the shipped files with network code, one per line,
  # once every check above has passed.
  [ "$status" -eq 0 ] && scan "$network" | cut -d: -f1 | sort -u
  exit "$status"
fi
if [ "$status" -eq 0 ]; then
  echo "privacy-check: ok ($manifest matches $(wc -l < "$work/files" | tr -d ' ') files in App and $(cat "$work/targets"); network code only in $cloud_files)"
fi
exit "$status"
