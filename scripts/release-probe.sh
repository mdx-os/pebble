#!/bin/sh
# Runs the promise that a build that ships reads a cloud address only with
# the current cloud policy, in a Release build of PebbleCore itself, so
# what is checked is the code that ships and not a Debug stand-in. The
# package tests can't do this: they run in Debug, and some reach code kept
# to Debug.
#
# It writes a tiny package in build/release-probe that uses PebbleCore and
# PebbleModel, builds it in Release and runs it. The probe fails if it was
# built as Debug, if CloudEndpoint gives back an address with no policy,
# another policy, plain http or an empty address, or if it gives back none
# with the current policy and a plain https address.
#
# It also fails unless the identity token sources a Release build can
# offer are exactly Apple: the only kind compiled in is Apple, `apple`
# offers Apple's own source, and every other setting, `staging` with a pass
# and an address among them, offers none.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$root/build/release-probe"
mkdir -p "$probe/Sources/probe"

cat > "$probe/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "PebbleKit", path: "$root/Packages/PebbleKit")],
    targets: [.executableTarget(name: "probe", dependencies: [
        .product(name: "PebbleCore", package: "PebbleKit"), .product(name: "PebbleModel", package: "PebbleKit"),
    ])]
)
EOF

cat > "$probe/Sources/probe/main.swift" <<'EOF'
import Foundation
import PebbleCore
import PebbleModel

#if DEBUG
print("release-probe: built as Debug, so it proves nothing")
exit(1)
#else
let raw = "https://cloud.example.com"
let policy = CloudPolicy.currentVersion
func reads(_ info: [String: Any]) -> Bool { CloudEndpoint.url(infoDictionary: info) != nil }
if CloudEndpoint.url(from: raw) != nil || reads([CloudEndpoint.infoKey: raw])
    || reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: policy + "-other"])
    || reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: "mdx-zero-retention-1"])
    || reads([CloudEndpoint.infoKey: "http://cloud.example.com", CloudEndpoint.policyKey: policy])
    || reads([CloudEndpoint.infoKey: "", CloudEndpoint.policyKey: policy]) {
    print("release-probe: a Release build read a cloud address without the current policy and a plain https address")
    exit(1)
}
if !reads([CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: policy]) {
    print("release-probe: a Release build with the current policy read no address")
    exit(1)
}
if IdentitySourceKind.allCases != [.apple] {
    print("release-probe: a Release build holds a sign-in source other than Apple")
    exit(1)
}
func offered(_ setting: String) -> (any IdentityTokenSource)? {
    IdentitySignIn.offered(infoDictionary: [IdentitySignIn.settingKey: setting, "PebbleStagingSignInPass": "letterspass",
                                            CloudEndpoint.infoKey: raw, CloudEndpoint.policyKey: policy],
                           endpoint: URL(string: raw))
}
guard let apple = offered("apple"), apple is AppleIdentityTokenSource, apple.kind == .apple else {
    print("release-probe: a Release build that says apple offers no Sign in with Apple")
    exit(1)
}
for setting in ["staging", "", "fake", "Apple", "dev-token"] where offered(setting) != nil {
    print("release-probe: a Release build offers a sign-in source for a setting other than apple")
    exit(1)
}
print("release-probe: ok, a Release build reads an address only with the current policy, and offers Sign in with Apple only")
#endif
EOF

swift run --package-path "$probe" -c release --quiet probe
