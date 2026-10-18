# Cutting a TestFlight build

The repo builds everything except the signature. `make archive` produces
unsigned Release archives for iOS (iPhone and iPad) and macOS and checks
them for what App Store Connect reads. Signing and upload happen on the
machine of whoever holds the Apple Developer account (Mandeep today), with
keys that never enter the repo.

## What is already in place

| Piece | Where |
| --- | --- |
| Version and build number, for every target | `Config/Version.xcconfig` |
| Product name | `Config/Brand.xcconfig` |
| App icon, iOS (1024 single size) and macOS (16 to 1024) | `App/Resources/Assets.xcassets/AppIcon.appiconset`, drawn by `scripts/app-icon.swift` |
| Launch screen, the backdrop color in light and dark | `UILaunchScreen` in `project.yml`, color `LaunchBackground` |
| Privacy manifest | `App/Resources/PrivacyInfo.xcprivacy`, kept honest by `make privacy-check` |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` in `project.yml` |
| Mac sandbox for Release | `ENABLE_APP_SANDBOX` in `project.yml`, nothing asked beyond it |
| Unsigned archives and their check | `make archive`, `scripts/release-check.sh` |

### Why the answers are what they are

- **Data collected: none. Tracking: none.** The app does no networking.
  Notes, the agent's name and its look stay in the app's own files and
  defaults on the device. `make privacy-check` fails if the app's code starts
  using the network, so this answer gets a fresh look when it does.
- **Required-reason APIs:** only `UserDefaults`, with reason `CA92.1`
  (the app's own settings, read only by the app). The check scans `App/`
  and every package product the app links.
- **Encryption:** the only encryption is the system's file protection on
  notes (`.completeFileProtection`), which is exempt. No HTTPS, no
  CryptoKit. When a model adapter talks to a server, look again: HTTPS
  through the system is still exempt, but the answer must be checked.

## Cutting a build

1. Raise the build number in `Config/Version.xcconfig`
   (`CURRENT_PROJECT_VERSION`). App Store Connect refuses a build number it
   has already seen for the same version. Change `MARKETING_VERSION` when
   the version people see should change.
2. Run `make verify`. It includes `make archive`, so the unsigned archives
   and their check must pass.
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

## What never goes in the repo

Team IDs, certificates, provisioning profiles, signing identities other
than the ad hoc `-`, App Store Connect API keys, and Apple ID passwords.
`.gitignore` lists the usual signing files, `scripts/release-check.sh` fails
if signing settings appear in `project.yml`, `Config/` or CI, and
`make secrets-check` scans history.
