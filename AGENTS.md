# Working in pebble

pebble is the codebase for Mia, an open-source personal agent for Mac, iPhone
and iPad. Humans direct and review; agents write most of the code. This file
is a map. Keep it short, and add a line whenever an agent makes a mistake that
a line here would have prevented.

## The one rule

Prove your work against the real artifact. `make verify` must pass before you
open a PR, and a UI change needs before-and-after screenshots from
`make screenshots`. "It compiles" is not proof, and a green CI run is not
enough. The second time the same mistake shows up, make it a permanent gate
in lint, a skill, or CI.

## Commands

- `make verify`: everything CI runs (brand check, tests, builds, screenshots)
- `make test`: package unit tests (Swift Testing), PebbleKit's and then the source guards' in `Tools/GuardKit`
- `make graph-check`: fail if swift-syntax can reach PebbleKit or the app project, named or through a dependency (part of verify). `make graph-check-test` is its self-test
- `make build-release`: Release builds for macOS and the iOS Simulator (part of verify). Anything behind `#if DEBUG`, like the showcase, must only be used behind it too
- `make pulse`: fetch the public source watch, write `pulse/snapshots/` and `pulse/digest.json`. Real changes also write `build/pulse/notify.md` and `build/pulse/summary.json`
- `make screenshots`: `build/screenshots/{iphone,ipad,mac}.png`, plus dark shots of the
  blue fill that `scripts/check-screenshots.sh` checks. Worktrees share simulators and
  the bundle ID, so when another session runs at once pass free ones:
  `make verify PEBBLE_IPAD="iPad Air 13-inch (M4)" PEBBLE_IPHONE="iPhone 17e"`
- The screenshots also get a `STAMP` with the commit and the working tree's hash. `make verify` makes them and then fails with "screenshots are stale, rerun make screenshots" if the stamp is missing or the tree has changed since. The tree hash is the contract: the same files make the same screenshots, so committing or amending them with nothing changed keeps them fresh. The commit line is only there to read. Screenshots always show the code as it is now
- `make screenshots-check`: that check alone, and `make screenshots-check-test` its self-test
- `make generate`: regenerate `Pebble.xcodeproj` after editing `project.yml`
- `make mutation-check`: break each entry of `scripts/mutation-manifest.txt` and
  `scripts/mutation/*.txt` on a copy in `build/mutation` and require its tests to fail.
  `ONLY=` runs the entries whose tests match. Add entries to `scripts/mutation/<area>.txt`
  (format in its README), never to the end of the old manifest
- `make mutation-manifest-check`: fail on an entry with no `test:`, `file:` or `perl:`
  line, a `file:` that is gone, or two `test:` or `file:` lines in one block (part of verify).
  Merge conflicts in these files are resolved by hand, never with a union merge: two
  entries with the same `test:` and `file:` lines would fold into one and hide a survivor
- `make secrets-check`: gitleaks over git history

## Layout and layers

- `App/`: one app target for all three platforms. Keep it thin.
- `Packages/PebbleKit/`: shared code in layers. A layer imports only layers
  below it; `Package.swift` enforces this.
  - `PebbleCore`: plain types. No SwiftUI, no networking.
  - `PebblePulse`: public source watch fetching and snapshots. Imports PebbleCore.
  - `PebbleModel`: model adapter. `ModelClient`, the on-device placeholder and `CloudModel` (off by default, every request previewed and redacted by `Redactor` in PebbleCore). Imports PebbleCore. MLX and Ollama adapters plug in here. The on-device task engine lives here too, made only by `OnDeviceTasks` from a key the compiler keeps private.
  - `PebbleBackground`: gives the background runner time (`BGTaskScheduler` on iOS, `NSBackgroundActivityScheduler` on the Mac). Imports PebbleCore. Scheduling decisions are pure functions in `BackgroundPlan`; the runner, its store and its switch live in PebbleCore's `Background.swift`, so no platform code goes there.
  - `PebbleUI`: SwiftUI views shared by every platform. Imports PebbleCore and PebbleModel.
- Where work is done (kept context, a framework, the relay, a remote run,
  then the person) is decided only by `FallbackRouter` in PebbleCore.
  The order and rules are in `docs/ROUTING.md`.
- New code goes in a package, not in `App/`. New layers get added to
  `Package.swift` with their place in the order written down.
- The source guards (privacy promise, contrast, accent, platform gate) read
  Swift through GuardScan, one SwiftSyntax parse per file, never a regex
  over the text. They live in `Tools/GuardKit`, a test-only package that
  reads PebbleKit by path, so swift-syntax never enters the app's package
  graph: PebbleKit and `project.yml` never name it (`make graph-check`).
  A new rule goes in its guard's rule list with a name, a wrong case in
  `GuardWrongCaseTests` that names it, and a `scripts/mutation/guards.txt`
  entry that turns it off. Rules compare names through `SyntaxSource.name`,
  never a token's `text`, so a name in backticks is still the name.
  swift-syntax is pinned to an exact version and only GuardScan uses it.
- `PromiseWords` (the device promise phrases and the allow list) and
  `SourceScan` are PebbleKit products only so GuardKit can read them. The
  app never links them.

## Background work

- On iPhone and iPad the app has the background fetch capability:
  `UIBackgroundModes: fetch` and one identifier in
  `BGTaskSchedulerPermittedIdentifiers`, both from `project.yml`. It lets
  the system wake the app for a short `BGAppRefreshTask`, so the morning
  summary can be made while the app is closed. It is off until the person
  turns on "Work while you're away".
- That run never touches the network. It counts what is already on the
  device and writes counts and times to its own file. Nothing in
  `PebbleBackground` or the runner opens a connection.
- The summary's file uses `completeUntilFirstUserAuthentication`, so it
  opens once the device has been unlocked since it started. Notes, private
  words and the task store (`TaskStore`: the engine's tasks, saved asks,
  receipts) keep `.complete`, and the summary never copies their words.
- Background work never changes a task while the task store won't open
  (`TaskStore.isShut`, found by trying the file). The store refuses the
  change and the engine makes none; nothing is held in memory to write at
  the next unlock, and nothing of a task's goes to a weaker file. Once it
  opens, the change is worked out again from what is there, as a task still
  going when the app closed is settled as stopped and written so.
  `LockedTaskStoreTests` guards this.
- The switch lives in `background-switch.json` with no file protection
  (`.none`), so a run before the first unlock can read it. It holds only a
  bool, dates and a reason (on or off, the next due time, why a run waited,
  whether a Forget everything is pending), never anything of the person's.
  Keep it that way: nothing else goes in that file. `UserDefaults` can't be
  read before the first unlock, so the switch is not kept there. Beside it,
  an empty `.background-switch.json.kept` marks that an earlier version's
  keys were seen in `UserDefaults`, so they never move over again. It holds
  no data and stays through Forget everything, so it is the one sign left
  that the switch was set; people who never had those keys get none.
- A switch write that fails is tried again at the next read, and an off
  that hasn't gone in makes the switch unknown. While the switch is
  unknown the runner never reads or writes its own file and shows no cards:
  a Forget everything still waiting is kept in the switch.
- Most background runs end quiet. iOS usually starts a fresh process for
  them, and Needs you lives only in memory, so the run counts nothing, makes
  no card and moves the job to tomorrow. A missing morning card after a
  night in the background is expected, not a bug. The runner counts
  `NeedsYou`, not the asks `TaskStore` keeps for a task while the app is
  closed, so those are not in the summary yet.
- What finished is counted from the task engine's own record in
  `TaskStore` (`TaskEngine.endings`), so a fresh launch counts it too.
  While the store won't open, as overnight with the screen locked, the
  summary says it couldn't count the tasks (`BackgroundWords.tasksLocked`)
  rather than leave them out or say zero.
- Forget everything clears the runner (its file and the switch's) and
  everything `TaskStore` keeps (saved tasks, receipts, nudges) in one tap.
  `BackgroundFeedTests` guards both together. Each window's recons go in
  the same tap, and `TaskStore` never keeps a recon (`ReconNeedsYouTests`).
- On Today a recon never runs on `DeviceTaskEngine`: it plays beside it on
  a scripted engine of its own (`JoinedTasks`), whose ids never reach the
  device's engine, so its topic is never in the device's file.
  `ReconBesideDeviceTasksTests` guards this.
- "Locked" for the runner means its file can't be opened yet, found by
  trying the file (`BackgroundConditions.background(store:...)`). Never
  derive it from `isProtectedDataAvailable` or the screen lock: a phone
  locked after its first unlock still makes the summary overnight.
- After a Forget everything erases the summary's file, the switch file
  goes too, with the keys an earlier version kept in `UserDefaults`.

## Manual checks before release

Things no test here can reach. Check each on a real iPhone before a release.

- `BackgroundStore.shutError` is `EPERM`. With "Work while you're away" on,
  restart the phone in the evening and leave it locked, never unlocked,
  until after 7:00. Unlock it but don't open the app, and download the
  app's container from Xcode's Devices window: `background-switch.json`
  (or the job in `background.json`) should hold `"locked"`. If neither
  does, opening the file failed with another error, and the runner took
  it as a disk error.

## The name

- The product name lives only in `Config/Brand.xcconfig`. Code reads it from
  `Brand` and never spells it. `make brand-check` enforces this.
- Code, modules, bundle IDs and the repo use the codename `pebble`.
- But never in a new key, path, folder or launch argument, where it would
  be written down and outlive a rename: `make brand-check` fails on a new
  lowercase `pebble` in Swift. Old ones stay in `scripts/brand-check-known.txt`.
- Each user may name their own agent. Never confuse the agent's name with a
  person in the user's contacts.

## Design tokens

- `PebbleUI/Theme.swift` owns the design system: `Theme.TypeScale` (Dynamic
  Type text styles, rounded `display` styles only for big warm words),
  `Theme.Space` (4 pt grid: 4 to 40), `Theme.Radius` (small, card, sheet),
  `Elevation` (flat, raised, floating, applied with `.elevation` or
  `.cardSurface`) and the palette (warm neutrals, blue accent, `Ink` with
  Increase Contrast pairs).
- Views use tokens, never literal font sizes, paddings, radii or colors.
  `DesignTokenTests` fails on a new `Color(red:...)` or
  `.font(.system(size:))` in PebbleUI outside Theme.swift.
- A new color for words needs a pair in `Theme.textPairs`.

## Principles

- Warm first: plain human words in the UI, no system jargon. Every word a
  person sees follows `docs/VOICE.md`.
- Motion is gentle and stops with Reduce Motion; haptics are light and only
  on iPhone. Shared pieces live in `PebbleUI/Presence.swift`.
- Never move VoiceOver focus while a line is being read; it cuts the line off.
  Wait for `announcementDidFinishNotification`, or leave focus alone. Manual
  check before merging such a change: on an iPhone with VoiceOver on, ask the
  chat to look into something and hear the whole offer before "Look into it".
- Private by default: personal content never leaves the device without consent.
- Local open-weight models by default; cloud models only when the user chooses.
- Every action the agent can take is a capability with a permission and a log entry.

## Pull requests

- Small PRs, one verifiable change each, one writer per branch.
- Title like `[area] Clear outcome`. Body: why, what changed, how it was verified.
- No em dashes or en dashes in commits, PR bodies or UI copy.
- No co-authored-by footers unless the founder asks.
- Squash merge.

## Learned the hard way

- `UNUserNotificationCenterDelegate`: use the completion-handler methods, not
  the async ones. The async ones answer UIKit off the main thread and crash
  the app as a notification opens. `NeedsYouFlowModelTests` guards this.
- `onReceive` of a `@Published` publisher replays its value each time the
  body runs. To react to a change, observe the object and use `onChange`.
- `DeviceTaskEngine` follows the notes whatever the model. Gate only
  starting a task on `place.staysOnDevice`, never making the engine, or a
  forgotten note's line stays in a kept digest after a model switch.
- An engine lets go of ended tasks by when they ended, never by when they
  began. A task dropped in the same change that ends it never tells its
  ledger how it ended. Retention lets go only of ends a delivered snapshot
  told, so an end still on its way is kept and steady work never stalls
  retention. `TaskLedgerRunTests` guards this.
- The ledger listens before saved tasks are restored: restoration can end
  more tasks than the engine keeps, and it trims the oldest as soon as
  their ends are told. A kept ledger is something to forget, so Forget
  everything shows for a ledger alone. `TaskLedgerCardTests` guards both.
- Record ledger outcomes before dispatching snapshots to the UI, whose
  sequence guard can drop older completions. Launch orphan detection waits
  for task restoration to resolve and its outcomes to be recorded. Only
  tasks absent from the reconciled snapshot are orphans, including when
  restoration ends a task. `TaskLedgerCardTests` guards this.
- A test that blocks waits only on a thread of its own, never on
  `DispatchQueue.global()` or the cooperative pool, and always with a
  generous limit (about 60 s). The pool starves on a busy runner, and a wait
  with no limit turns a regression into a hung run instead of a failure.
  `TaskLedgerRunTests` and `TaskLedgerCardTests` follow this.

## Never

- Commit secrets, API keys or signing material. The xAI key and signing keys
  live in CI secrets or the Keychain.
- Run untrusted PR code on a self-hosted runner. PR checks use GitHub's runners.
- Copy code from MDx without reading it first; MDx carries enterprise
  assumptions and internal names that do not belong here.

## Manual checks before release

Some things can't be proven by an automated test. Check these by hand before a release and note the result in the release PR:

- **Done's focus ring on the Mac:** turn on Full Keyboard Access, open a sheet, and Tab to Done. Exactly one ring shows around it, in light and in dark. If the system draws a second ring, add `.focusEffectDisabled()` to the button.
- **Done's focus ring on iPad:** with a hardware keyboard, Tab to Done. The ring shows in light and in dark.
- **Done's pointer hover on iPad:** with a trackpad or mouse, hover over Done. It shows the hover effect.
- **Today's count on the Mac:** with something waiting and another row chosen, turn on VoiceOver and move to Today in the sidebar. It says the count as "3 waiting for you", not just "3". If it says only the number, the system badge is dropping the label.
