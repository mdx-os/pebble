# Mia

Mia is an open-source, privacy-first personal agent for Mac, iPhone and iPad.
It runs open-weight models on your own devices by default, does real work for
you, and shows you what it did.

This repository's codename is **pebble**. "Mia" is the product name and is set
in one place, `Config/Brand.xcconfig`, so the product can be renamed without
touching code.

Status: day one. The app says hello on all three platforms, and the build
proves itself on every change. See [the roadmap](#roadmap).

## Build it

Requirements: macOS 26 or later, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make verify       # brand check, tests, builds, and screenshots on iPhone, iPad and Mac
make test         # unit tests only
make screenshots  # writes build/screenshots/{iphone,ipad,mac}.png
```

`make generate` creates `Pebble.xcodeproj` from `project.yml`. The project file
is generated, not committed.

## Layout

```
App/                  the app target (one target for Mac, iPhone and iPad)
Config/Brand.xcconfig the product name, set once
Packages/PebbleKit/   shared code, in layers
  PebbleCore            plain types, no UI
  PebbleUI              SwiftUI views
scripts/              build helpers
```

## Roadmap

1. A repo that proves itself: one command builds, tests and screenshots every platform. (now)
2. A daily pulse on what's new in AI and in other personal agents.
3. Mia talks: a named agent running a local open model.
4. A daily briefing, ideas and activity inside the app.
5. Mia improves Mia: small, verified changes every day.

## License

Apache 2.0. See [LICENSE](LICENSE).
