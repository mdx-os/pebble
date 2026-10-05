# Mia

Mia is an open-source, privacy-first personal agent for Mac, iPhone and iPad.
It runs open-weight models on your own devices by default, does real work for
you, and shows you what it did.

This repository's codename is **pebble**. "Mia" is the product name and is set
in one place, `Config/Brand.xcconfig`, so the product can be renamed without
touching code.

Status: the app opens a first conversation on Mac, iPhone, and iPad. You can
name your agent on the device. Replies come from an on-device placeholder
until a local model adapter is plugged in. See [the roadmap](#roadmap).

## Build it

Requirements: macOS 26 or later, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make verify       # brand check, tests, builds, and screenshots on iPhone, iPad and Mac
make test         # unit tests only
make pulse        # fetch public sources, snapshot them, write pulse/digest.json
make screenshots  # writes build/screenshots/{iphone,ipad,mac}.png
```

`make generate` creates `Pebble.xcodeproj` from `project.yml`. The project file
is generated, not committed.

When `make pulse` finds a real change, it also writes `build/pulse/notify.md`
and `build/pulse/summary.json`. A quiet run removes them.

## Layout

```
App/                  the app target (one target for Mac, iPhone and iPad)
Config/Brand.xcconfig the product name, set once
Packages/PebbleKit/   shared code, in layers
  PebbleCore            plain types, no UI, no networking
  PebblePulse           competitor watch fetching and snapshots
  PebbleModel           model adapter and the on-device placeholder
  PebbleUI              SwiftUI views
pulse/                source list and snapshots
scripts/              build helpers
```

## The model

The chat asks a `ModelClient` for each reply. The default is `LocalStubModel`,
an on-device placeholder with fixed warm replies. The app, the tests, and the
screenshots use it, so nobody has to download a model.

A real adapter is another `Sendable` type in `PebbleModel` that implements
`reply(to:)`. Pass it to `ChatView` the same way the app passes
`LocalStubModel`.

- MLX: load an open-weight model on the device and generate from the
  transcript. Keep the weights on the device. This path does not use the network.
- Ollama: send the transcript to an Ollama server the person is already
  running on this machine, at `127.0.0.1` port `11434`. That request stays in
  `PebbleModel`.

`PebbleCore` does not do networking. A cloud model stays off until the person
chooses one.

## The agent's name

The product name is set in `Config/Brand.xcconfig`. The name you call your
agent is separate. It is saved on this device, and you can change it from the
first conversation. It is not someone in your contacts.

## Roadmap

1. A repo that proves itself: one command builds, tests and screenshots every platform.
2. A daily pulse on what's new in AI and in other personal agents. Fetching, a digest of real changes, and idea cards drafted from that digest are in place.
3. Mia talks: a named agent with a face and a first conversation. You can rename the agent on the device. The chat calls a local model adapter. The default is an on-device placeholder until MLX or Ollama is plugged in. (now)
4. A daily briefing, ideas and activity inside the app.
5. Mia improves Mia: small, verified changes every day.

## License

Apache 2.0. See [LICENSE](LICENSE).
