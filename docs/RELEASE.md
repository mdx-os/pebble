# Cutting a TestFlight build

The repo builds everything except the signature. `make archive` produces
unsigned Release archives for iOS (iPhone and iPad) and macOS and checks
them for what App Store Connect reads. Signing and upload happen on the
machine of the account holder, who holds the Apple Developer account, with
keys that never enter the repo.

## What is already in place

| Piece | Where |
| --- | --- |
| Version and build number, for every target | `Config/Version.xcconfig` |
| Product name | `Config/Brand.xcconfig` |
| App icon, iOS (1024 single size, with dark and tinted) and macOS (16 to 1024) | `App/Assets.xcassets/AppIcon.appiconset`, the app's one asset catalog |
| Launch screen, the backdrop color in light and dark, each also in high contrast | `UILaunchScreen` in `project.yml`, color `LaunchBackground` in `App/Assets.xcassets` |
| Privacy manifest | `App/Resources/PrivacyInfo.xcprivacy`, kept honest by `make privacy-check` |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` in `project.yml` |
| Mac sandbox for Release | `ENABLE_APP_SANDBOX` in `project.yml`, with `App/Mac-Release.entitlements` asking only for outgoing connections |
| Unsigned archives and their check | `make archive`, `scripts/release-check.sh` |

### Why the answers are what they are

- **Data collected: none. Tracking: none.** Notes, the agent's name and its
  look stay in the app's own files and defaults on the device. The one way
  anything leaves is the opt-in cloud client (`CloudModel`): off by default,
  turned on only by the person, and every request shown to them, redacted,
  before it goes.
- **The rule that keeps "Data Not Collected" true.** It holds only while
  every request goes to a server the person chose and runs themselves:
  - no default endpoint. Release builds ship with `PebbleCloudEndpoint`
    empty, and `release-check` fails if an archive carries one. An address
    in `Config/Cloud.local.xcconfig` is for trying a server on one machine,
    never for a build that ships.
  - no key of ours. No API key, token or account of the project's goes in
    the app. The xAI key in CI is for `make pulse`, the public source watch,
    which the app never links.

  If any build sends notes or chats to a provider using our key or our
  endpoint, that provider is a third-party partner, and the manifest's
  `NSPrivacyCollectedDataTypes` and the App Privacy answers need User
  Content entries before it ships.
- **Network code** lives only in `Packages/PebbleKit/Sources/PebbleModel/CloudModel.swift`,
  and its transport is made only in `CloudHelpView.swift`, inside the
  closure `ModelChoice.model` calls with the cloud setting on, in its body
  and not its capture list.
  `make privacy-check` fails on network code anywhere else, in `App/`,
  any source folder `project.yml` compiles, or any PebbleKit target the
  app reaches. It reads `project.yml` through `xcodegen dump` and fails on
  a dependency or source it can't read. It fails if the gate or its tests
  (`offByDefaultMakesNoTransportAndKeepsChatsOnDevice`,
  `anEmptyAddressMeansDisabledEvenIfSavedOn`) go away. It also fails on
  system APIs that send the person's data to Apple: `CLGeocoder`,
  `MKLocalSearch`, the iCloud container, and speech recognition outside the reserved
  `PebbleModel/OnDeviceSpeech.swift` helper named `recognizeOnDevice`.
  No speech helper ships today. Adding it requires reviewing the exact
  request passed to recognition and tests that keep recognition on device.
  Swift source is parsed by GuardScan in the separate Tools/GuardKit package.
  All compiled App sources are enumerated; languages the checker cannot
  read fail until a parser and fixtures are added.
- **Required-reason APIs:** `UserDefaults`, with reason `CA92.1`
  (the app's own settings, read only by the app), and file timestamps,
  with reason `C617.1` (`lstat` on the grants file and its marker in the
  app's container, only to learn whether each is there). The check scans `App/`
  and every PebbleKit target the app links, with their dependencies.
- **Encryption:** the system's file protection on notes
  (`.completeFileProtection`) and HTTPS through `URLSession` in the cloud
  client. Both come from the system, so both are exempt, and
  `ITSAppUsesNonExemptEncryption = NO` is the current answer.
  `make privacy-check` flags `CryptoKit`, `CommonCrypto`,
  `SecKeyCreateEncryptedData`, `NIOSSL`, BoringSSL and certificate pinning
  as tripwires. A hit requires a fresh export review before shipping; it
  does not by itself prove that encryption is nonexempt. CryptoKit is a
  system framework too. Review the actual use, the App Store Connect
  questions and any reporting obligations before keeping or changing
  the answer.
- **Mac sandbox:** Release asks for `com.apple.security.network.client`
  (outgoing connections) and nothing else. `release-check` reads
  `ENABLE_APP_SANDBOX` and the entitlements from the Release build settings,
  requires outgoing connections whenever there is network code, and fails
  on `NSAllowsArbitraryLoads` or an `NSExceptionDomains` entry no one has
  reviewed. The app has no save panel, file exporter or drag out, so it
  doesn't need `files.user-selected.read-write`; `release-check` fails if
  one appears without it.

## Cutting a build

1. Raise the build number in `Config/Version.xcconfig`
   (`CURRENT_PROJECT_VERSION`). App Store Connect refuses a build number it
   has already seen for the same version. Change `MARKETING_VERSION` when
   the version people see should change.
2. Run `make verify`. It includes `make archive`, so the unsigned archives
   and their check must pass. Archive on a machine without
   `Config/Cloud.local.xcconfig`, or with it empty: a Release build
   carries no cloud address.
3. Merge to `main` the usual way, then sign and upload from a clean checkout
   of that commit, as below.

## Signing and upload (done by the account holder)

Nothing below is committed. Each value lives on the signing machine.

1. **Signing settings.** Create `Config/Signing.local.xcconfig`. Git
   ignores it, and `Config/Project.xcconfig` reads it when present:

   ```
   DEVELOPMENT_TEAM = <your team ID>
   ```

   With automatic signing (the project's style) that is enough for iOS.
   The Mac target is set to sign locally with an ad hoc identity (`-`) so
   anyone can build it; override that for a real build, as in step 3.
   The target's `CODE_SIGN_IDENTITY` value of `-` takes precedence over
   the local xcconfig. On the first Mac upload, check the signed archive
   and exported app to confirm the intended distribution identity and
   sandbox entitlements survived export.
2. **Bundle ID.** The app uses `com.mdxos.pebble` on iOS and macOS, one
   record for both (universal purchase). If it must change, change
   `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and `bundle_id` in
   `scripts/screenshots.sh` and `scripts/ui-screenshots.sh` in the same pull
   request.
3. **Archive signed.** Either open `Pebble.xcodeproj` after `make generate`
   and use Product, Archive (choose "Any iOS Device", then "My Mac"), or:

   ```sh
   make generate
   xcodebuild archive -project Pebble.xcodeproj -scheme Pebble -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/signed/Pebble-iOS.xcarchive \
     -allowProvisioningUpdates
   xcodebuild archive -project Pebble.xcodeproj -scheme Pebble -configuration Release \
     -destination 'generic/platform=macOS' -archivePath build/signed/Pebble-macOS.xcarchive \
     -allowProvisioningUpdates CODE_SIGN_IDENTITY="Apple Development"
   ```

   `-allowProvisioningUpdates` uses the Apple ID signed in to Xcode, or an
   App Store Connect API key passed with `-authenticationKeyPath`,
   `-authenticationKeyID` and `-authenticationKeyIssuerID`. Keep the key in
   the Keychain or CI secrets, never in the repo.
4. **Upload.** In Xcode's Organizer choose each archive, then Distribute
   App, then TestFlight and App Store. Xcode signs with the distribution
   certificate and makes the profiles.
5. **App Store Connect record**, once: a new app for iOS and macOS with the
   bundle ID above, its name (the product name from `Config/Brand.xcconfig`),
   primary language, and a SKU. Then:
   - App Privacy: "Data Not Collected", matching the manifest.
   - Export compliance: answered by the build; nothing to fill in.
   - TestFlight test information: a beta description, a feedback email,
     and, for testers outside the team, a review contact and a privacy
     policy URL.

## Tester notes: Mac data from a Debug build

Release builds for the Mac are sandboxed and Debug builds are not (so
`make screenshots` can write its PNG anywhere), so the two keep their data
in different places. Anyone who ran a Debug build from Xcode or
`make build` has a second copy that the TestFlight app never sees, and
Forget everything in the TestFlight app can't reach it:

| What | Debug (unsandboxed) | Release and TestFlight (sandboxed) |
| --- | --- | --- |
| Notes, private words, the cloud setting, the morning summary and its switch | `~/Library/Application Support/pebble/memory/` | `~/Library/Containers/com.mdxos.pebble/Data/Library/Application Support/pebble/memory/` |
| Saved tasks, receipts and nudges | `~/Library/Application Support/kept-tasks/` | the same, under `~/Library/Containers/com.mdxos.pebble/Data/Library/Application Support/` |
| The agent's name and look, and other settings | `~/Library/Preferences/com.mdxos.pebble.plist` | `~/Library/Containers/com.mdxos.pebble/Data/Library/Preferences/com.mdxos.pebble.plist` |

Put this in the TestFlight notes for Mac testers who also build from
source: to remove everything, use Forget everything in a Debug build too,
or delete the Debug paths above by hand. iPhone and iPad builds are always
sandboxed, so this is only about the Mac.

## What never goes in the repo

Team IDs, certificates, provisioning profiles, signing identities other
than the ad hoc `-`, App Store Connect API keys, and Apple ID passwords.
`.gitignore` lists the usual signing files, `scripts/release-check.sh` fails
if signing settings appear in `project.yml`, `Config/` or CI, and
`make secrets-check` scans history.
