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
Replies come from a small open model running on the device, through MLX,
once you choose to download it from the memory screen. Until then an
on-device placeholder says plainly that the model isn't ready. See
[the roadmap](#roadmap).

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

The package tests run in Debug only, as `make test` and CI run them. The UI
tests use the showcase (`ShowcaseScene.morning`, `ShowcaseScene.emptyMemory()`),
which is Debug only, so `swift test -c release` does not build them. Release
is checked by `make build-release` instead.

When `make pulse` finds a real change, it also writes `build/pulse/notify.md`
and `build/pulse/summary.json`. A quiet run removes them.

## Layout

```
App/                  the app target (one target for Mac, iPhone and iPad)
Config/Brand.xcconfig the product name, set once
Packages/PebbleKit/   shared code, in layers
  PebbleCore            plain types, no UI, no networking
  PebblePulse           competitor watch fetching and snapshots
  PebbleModel           model adapter, the on-device placeholder, MLX and its download
  PebbleUI              SwiftUI views
pulse/                source list and snapshots
scripts/              build helpers
```

## The model

The chat asks a `ModelClient` for each reply. The app makes one,
`OnDeviceChat`, and shares it with every window. It answers with
`MLXChatModel`, running Qwen3 4B Instruct 2507 (4-bit MLX weights, pinned in
`PinnedModel`) on the device, once that model is downloaded. Until then it
holds `LocalStubModel`, which says plainly that the model isn't ready and how
to get it, instead of pretending to answer. Tests, screenshots, and CI use the
placeholder, so they never download or load a model and need no GPU.

Getting the model is always the person's choice: What I remember, then
Download on-device model, about 2.3 GB. Nothing is fetched at launch or on its
own. The download fetches only the pinned files at the pinned revision from
huggingface.co, with an ephemeral session, no cookies, no credentials and
nothing from a chat. Files land in a temporary folder under
`Application Support/<product name>/Models`, which backups skip; only once
every file has its pinned size and SHA-256 does the folder take its finished
name, and the chat moves to the model from its next reply. A stop, a failure
or a mismatch removes what came, and Try again starts over. All the network
code is in `PebbleModel/ModelDownload.swift`; `make local-only-check` lets
`URLSession` appear there and in `CloudModel.swift`, by exact path, and
nowhere else in the app, `PebbleCore`, `PebbleBackground` or `PebbleModel`.

The model is used only if its weights leave 1 GB of the memory this process
can draw on (`OnDeviceModel.headroomBytes`), so it fits iPhone 17e and the Mac.

Developers can point the app at another folder: the environment variable
`PEBBLE_MLX_MODEL`, or the UserDefaults key `onDeviceModelFolder`, wins over
the download. The value can be an absolute path, a path that starts with `~`,
or a `file://` URL with no host. The folder must contain `config.json`,
`tokenizer.json`, and at least one `.safetensors` file. A blank value, a
relative path, a remote address, a file URL with a host, a missing or
unusable folder, or weights too large for the memory here keeps the
placeholder, which says why.

Ollama is not plugged in yet. When it is, it should send the transcript
to an Ollama server the person is already running on this machine, at
`127.0.0.1` port `11434`, and that request stays in `PebbleModel`.

`PebbleCore` does not do networking. A cloud model stays off until the person
chooses one.

- Cloud: `CloudModel` sends to the address in `Config/Cloud.local.xcconfig`,
  which git ignores and which doesn't exist by default, so the setting can't
  be turned on. Turning it on (What I remember, then Help from the cloud)
  asks first and counts from the next new chat. Every request is redacted on
  the device by `Redactor` and shown to the person in full, method, address,
  headers and body, before it is sent. Redirects are refused. Words of crisis
  and chats that promised to stay on the device are never sent, and nothing
  is sent when the notes or private words can't be read. The setting and the
  private words are kept next to the notes, out of backups. Sign-in is a
  `CloudAuth` hook that adds nothing by default and may only use the network
  after the person says yes; no keys live in the repo. `CloudModel` reports
  `PrivacyPlace.mayLeaveDevice`, so a chat started with the cloud on makes
  no device promise anywhere.

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
3. Mia talks: a named agent with a face and a first conversation. You can rename the agent on the device. The chat answers with a small open model through MLX, on the device, once the person downloads it; until then a placeholder says so. Ollama is not plugged in yet. (now)
4. A daily briefing, ideas and activity inside the app.
5. Mia improves Mia: small, verified changes every day.

## License

Apache 2.0. See [LICENSE](LICENSE).
