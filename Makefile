DERIVED := build/DerivedData

.PHONY: verify generate test build screenshots brand-check secrets-check pulse clean

## verify: everything CI runs. Run this before every PR.
verify: brand-check test build screenshots

## generate: create Pebble.xcodeproj from project.yml (the project file is not committed)
generate:
	xcodegen generate --quiet

## test: unit tests for the shared packages
test:
	swift test --package-path Packages/PebbleKit --quiet

## pulse: fetch the competitor watch, snapshot it, write a digest of real changes
pulse:
	swift run --package-path Packages/PebbleKit pulse -- --root "$(CURDIR)"

## build: compile the app for macOS and the iOS Simulator
build: generate
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED)
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

## screenshots: first screen on iPhone, iPad and Mac, written to build/screenshots
screenshots: generate
	sh scripts/screenshots.sh build/screenshots

## brand-check: the product name must live only in Config/Brand.xcconfig
brand-check:
	sh scripts/brand-check.sh

## secrets-check: scan git history for leaked secrets
secrets-check:
	gitleaks git --no-banner --redact .

clean:
	rm -rf build Pebble.xcodeproj Packages/PebbleKit/.build
