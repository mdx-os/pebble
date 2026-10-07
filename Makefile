DERIVED := build/DerivedData

.PHONY: verify generate test build screenshots brand-check local-only-check resolved-check secrets-check pulse clean

## verify: everything CI runs. Run this before every PR.
verify: brand-check local-only-check resolved-check test build screenshots

## generate: create Pebble.xcodeproj from project.yml (the project file is not committed)
generate:
	xcodegen generate --quiet
	mkdir -p Pebble.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	cp Config/Package.resolved Pebble.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

## test: unit tests for the shared packages, using the committed pin only
test:
	swift test --package-path Packages/PebbleKit --disable-automatic-resolution --quiet

## pulse: fetch the competitor watch and write a digest of real changes.
## When something changed, also write build/pulse/notify.md and build/pulse/summary.json.
pulse:
	swift run --package-path Packages/PebbleKit pulse -- --root "$(CURDIR)"

## build: compile the app for macOS and the iOS Simulator
build: generate
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -onlyUsePackageVersionsFromResolvedFile
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO

## screenshots: first screen on iPhone, iPad and Mac, written to build/screenshots
screenshots: generate
	sh scripts/screenshots.sh build/screenshots

## brand-check: the product name must live only in Config/Brand.xcconfig
brand-check:
	sh scripts/brand-check.sh

## local-only-check: the app and model adapter must not name a network client
local-only-check:
	sh scripts/local-only-check.sh

## resolved-check: the package pin and the app pin must match
resolved-check:
	sh scripts/resolved-check.sh

## secrets-check: scan git history for leaked secrets
secrets-check:
	gitleaks git --no-banner --redact .

clean:
	rm -rf build Pebble.xcodeproj Packages/PebbleKit/.build
