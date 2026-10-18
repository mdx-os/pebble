DERIVED := build/DerivedData

.PHONY: verify generate test build build-release screenshots ui-screenshots device-screenshots ui-test brand-check local-config-check secrets-check pulse clean

## verify: everything CI runs. Run this before every PR.
verify: brand-check local-config-check test build build-release screenshots

## generate: create Pebble.xcodeproj from project.yml (the project file is not committed)
generate:
	xcodegen generate --quiet

## test: unit tests for the shared packages
test:
	swift test --package-path Packages/PebbleKit --quiet

## pulse: fetch the competitor watch and write a digest of real changes.
## When something changed, also write build/pulse/notify.md and build/pulse/summary.json.
pulse:
	swift run --package-path Packages/PebbleKit pulse -- --root "$(CURDIR)"

## build: compile the app for macOS and the iOS Simulator
build: generate
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED)
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

## build-release: compile the app in Release for macOS and the iOS Simulator, so
## code kept to Debug (the showcase screens) can never break a shipped build
build-release: generate
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED)
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

## screenshots: first screen on iPhone, iPad and Mac, written to build/screenshots
screenshots: generate
	sh scripts/screenshots.sh build/screenshots

## ui-screenshots: showcase screens in light and dark on one simulator, written to
## build/screenshots/ui (or OUT=dir). DEVICE= names the simulator, SCREENS= the screens.
ui-screenshots: generate
	xcodebuild build -quiet -project Pebble.xcodeproj -scheme Pebble -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO
	PEBBLE_IPHONE="$(or $(DEVICE),iPhone 17 Pro)" PEBBLE_SCREENS="$(SCREENS)" sh scripts/ui-screenshots.sh $(or $(OUT),build/screenshots/ui)

## device-screenshots: showcase screens on iPad Pro 13-inch, iPad mini and iPhone,
## portrait and landscape, written to build/screenshots/devices (or OUT=dir).
## DEVICES= names the simulators (separated by commas), SCREENS= the screens.
device-screenshots: generate
	PEBBLE_DEVICES="$(DEVICES)" PEBBLE_SCREENS="$(SCREENS)" \
		sh scripts/device-screenshots.sh $(or $(OUT),build/screenshots/devices)

## ui-test: drive the app in the Simulator: the iPad sidebar, Return to send,
## the keyboard shortcuts and the cloud screens, on an iPad and an iPhone
ui-test: generate
	xcodebuild test -quiet -project Pebble.xcodeproj -scheme Pebble -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,name=$(or $(PEBBLE_IPAD),iPad Pro 13-inch (M5))' \
		-destination 'platform=iOS Simulator,name=$(or $(PEBBLE_IPHONE),iPhone 17 Pro)' \
		-only-testing:PebbleAppUITests/HomeLayoutUITests \
		-only-testing:PebbleAppUITests/CloudUITests

## brand-check: the product name must live only in Config/Brand.xcconfig
brand-check:
	sh scripts/brand-check.sh

## local-config-check: fail if Config/Cloud.local.xcconfig is tracked by git
local-config-check:
	sh scripts/local-config-check.sh

## secrets-check: scan git history for leaked secrets, and fail if the
## one-machine Config/Cloud.local.xcconfig is ever tracked
secrets-check:
	sh scripts/local-config-check.sh
	gitleaks git --no-banner --redact .

clean:
	rm -rf build Pebble.xcodeproj Packages/PebbleKit/.build
