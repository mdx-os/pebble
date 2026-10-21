# Mia

Mia is an open-source, privacy-first personal agent for Mac, iPhone and iPad.
It runs open-weight models on your own devices by default, does real work for
you, and shows you what it did.

This repository's codename is **pebble**. "Mia" is the product name and is set
in one place, `Config/Brand.xcconfig`, so the product can be renamed without
touching code.

Status: the app opens a first conversation on Mac, iPhone, and iPad. You can
name your agent on the device. After the first run, home is Today, with the
chat's composer right on it: type, press Return, and the chat opens with your
words sent. Today is built to hold what the agent did, made and noticed, with
any question that needs your yes pinned on top, but no real source of
finished work ships yet, so for now it is a quiet place to start a chat. The
feed shows sample cards, marked as examples, only in the showcase screens.
Replies come from an on-device placeholder until a local model adapter is
plugged in. See [the roadmap](#roadmap).

## Build it

Requirements: macOS 26 or later, Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make verify       # brand and privacy checks, tests, mutation check, builds, archives, and screenshots on iPhone, iPad and Mac
make test         # unit tests only
make archive      # unsigned Release archives for iOS and macOS, checked for TestFlight
make pulse        # fetch public sources, snapshot them, write pulse/digest.json
make screenshots  # writes build/screenshots/{iphone,ipad,mac}.png
```

`make generate` creates `Pebble.xcodeproj` from `project.yml`. The project file
is generated, not committed.

The package tests run in Debug only, as `make test` and CI run them. The UI
tests use the showcase (`ShowcaseScene.morning`, `ShowcaseScene.emptyMemory()`),
which is Debug only, so `swift test -c release` does not build them. Release
is checked by `make build-release` instead.

Signing and uploading a TestFlight build is in [docs/RELEASE.md](docs/RELEASE.md).

When `make pulse` finds a real change, it also writes `build/pulse/notify.md`
and `build/pulse/summary.json`. A quiet run removes them.

## Layout

```
App/                  the app target (one target for Mac, iPhone and iPad)
  Resources/            app icon, launch color, privacy manifest
Config/Brand.xcconfig the product name, set once
Config/Version.xcconfig the version and build number, set once
Packages/PebbleKit/   shared code, in layers
  PebbleCore            plain types, no UI, no networking
  PebblePulse           public source watch fetching and snapshots
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

- Cloud: `CloudModel` sends to the address in `Config/Cloud.local.xcconfig`,
  which git ignores and which doesn't exist by default, so the setting can't
  be turned on. It is for Debug builds only: every build with an address
  fails unless it is Debug and not an archive, whatever the configuration
  is called, until who runs the server, how long it keeps what it is sent,
  and what sign-in sends are decided, and outside a Debug build the app
  reads no address at all, even if those checks were skipped. Turning it on (What I
  remember, then Help from the cloud) asks first, holds only for that
  address, and counts from the next new chat. Every request is redacted on
  the device by `Redactor` and shown to the person in full, method, address,
  every header including the Host, Content-Length, Cache-Control and
  Connection lines the system adds, and body, before it is sent; a test
  against a listener on the Mac's own loopback address holds the lines
  that arrive over HTTP/1.1 up against the card's. That is the only
  protocol tested: over HTTP/2 the system leaves out the Connection line,
  so the card may show a line more than went. Redirects, plain http and the header
  names URLSession reserves are refused. Words of crisis and chats that promised to stay on
  the device are never sent, and nothing is sent when the notes or private
  words can't be read. The setting and the private words are kept next to
  the notes, out of backups, and Forget everything ends every open cloud
  chat first. Sign-in is a `CloudAuth` hook that adds nothing by default; a
  sign-in the cloud needs is a hop shown in the same preview, its values
  covered on screen, and sent only by its yes, so no request of ours goes
  unshown. Its values are covered, though not their combined length,
  which the hop's Content-Length still shows. Since its values are
  covered, sign-in may carry only a credential or a device token: a name
  or value with a name, a private word or another personal detail in it,
  a name that isn't a short token, or a body that isn't a flat object of
  short values, is refused before anything is shown or sent. What goes is those
  checked values, written again, never the body sign-in handed over. The
  check knows only what the redactor knows, so the rest rests on the
  `CloudAuth` contract. The transport keeps and
  sets no cookie, cache or saved password. Turning the cloud off and
  Forget everything stop every open cloud chat from sending, then tell
  sign-in to forget what it kept. No keys live in the
  repo. `CloudModel` reports `PrivacyPlace.mayLeaveDevice`, so a chat
  started with the cloud on makes no device promise anywhere.
- What the cloud setting leaves on the device: the setting and the private
  words, kept beside the notes with the same protection. When a switch
  off can't be saved, as on a locked device, an empty file is left to mark
  it off. It is left unprotected so it can be written while locked, and it
  holds nothing personal; its only tell, to someone already reading the
  app's folder, is that the cloud was switched off.

## Looking into things

Say "look into ..." (or "research ...", "find out about ...") in the chat
and the agent offers to do it; nothing starts until you tap Look into it. A
feed card can offer the same with one tap. Words of crisis always get care
first and never become a task.

The request runs as a task (`ReconTask`, run by `ReconRunner` on the task
engine): plan a few questions, read the sources, check their dates, put a
summary together. It lands in Today as a card with a short summary, a few
key points, every point marked with its sources, a plain line wherever the
sources disagree, and when it was gathered. From the card you can open the
sources and ask a follow-up in the chat. A card that wasn't read from
examples also offers to remember a point.

Sources come through `SourceProvider`. The only one so far is
`SampleSources`, a set of made up documents kept on the device, so results
are labelled as examples, and no point from them can be remembered: the
card doesn't offer it, and the notes store refuses one (`ReconRunner.keepsPoints`,
`MemoryStore.remember(_:from:at:)`). With the cloud off, the summary is put
together on the device. With it on, the request goes through the same
redaction and preview as a chat, and choosing not to send keeps it on the
device. A recon asked for from a chat that stays on the device is put
together on the device too, whatever the cloud setting.

Once real sources are plugged in, a point you keep is saved with the source
`lookedUp`. One put together on the device is labelled with its first
source's publisher and lists each source in the note. One put into words in
the cloud names no publisher, since no one here checked which page said it:
it is labelled "From something I looked into" and the note says it was put
into words in the cloud. Builds from before looking into things can't read
that kind, so if you go back to one, those notes show as "My guess"
(`inferred`), the least trusted label. Their words are kept, but once that
older build saves the notes again, where they came from is lost and they
stay "My guess".

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
