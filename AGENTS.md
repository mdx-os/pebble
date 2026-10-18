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

- `make verify`: everything CI runs (brand check, comment lint, tests, mutation check, builds, screenshots)
- `make test`: package unit tests (Swift Testing)
- `make mutation-check`: breaks the code each test in `scripts/mutation-manifest.txt` covers, on a copy in `build/mutation`, and requires the test to fail. Every new package behavior test gets a manifest entry; a test that passes with its code broken protects nothing. The check runs only `swift test`, so a UI test that guards a promise needs a package twin pinning the same thing, with entries, listed at the top of the manifest
- `make release-test`: runs the "a shipped build reads no cloud address" promise in a Release build of PebbleCore (part of verify). Package tests run in Debug, so they can't see that code
- `make comment-lint`: no review history ("fix round", "item 11", "round 4") or personal names in code comments, project.yml, the Makefile or the mutation manifest. Say what the code or test protects. The names it blocks are never committed: they live in the git-ignored `Config/comment-lint-names.local.txt`, or in CI in the `COMMENT_LINT_NAMES` secret. In CI a missing list fails, except on a fork's pull request, which warns
- `make build-release`: Release builds for macOS and the iOS Simulator (part of verify). Anything behind `#if DEBUG`, like the showcase, must only be used behind it too. Every build with a cloud address fails unless it is Debug and not an archive, whatever the configuration is called
- `make pulse`: fetch the competitor watch, write `pulse/snapshots/` and `pulse/digest.json`. Real changes also write `build/pulse/notify.md` and `build/pulse/summary.json`
- `make screenshots`: `build/screenshots/{iphone,ipad,mac}.png`
- `make generate`: regenerate `Pebble.xcodeproj` after editing `project.yml`
- `make secrets-check`: gitleaks over git history

## Layout and layers

- `App/`: one app target for all three platforms. Keep it thin.
- `Packages/PebbleKit/`: shared code in layers. A layer imports only layers
  below it; `Package.swift` enforces this.
  - `PebbleCore`: plain types. No SwiftUI, no networking.
  - `PebblePulse`: competitor watch fetching and snapshots. Imports PebbleCore.
  - `PebbleModel`: model adapter. `ModelClient`, the on-device placeholder and `CloudModel` (off by default, every request previewed and redacted by `Redactor` in PebbleCore). Imports PebbleCore. MLX and Ollama adapters plug in here.
  - `PebbleUI`: SwiftUI views shared by every platform. Imports PebbleCore and PebbleModel.
- New code goes in a package, not in `App/`. New layers get added to
  `Package.swift` with their place in the order written down.

## The name

- The product name lives only in `Config/Brand.xcconfig`. Code reads it from
  `Brand` and never spells it. `make brand-check` enforces this.
- Code, modules, bundle IDs and the repo use the codename `pebble`.
- Each user may name their own agent. Never confuse the agent's name with a
  person in the user's contacts.

## Principles

- Warm first: plain human words in the UI, no system jargon. Every word a
  person sees follows `docs/VOICE.md`.
- Motion is gentle and stops with Reduce Motion; haptics are light and only
  on iPhone. Shared pieces live in `PebbleUI/Presence.swift`.
- Private by default: personal content never leaves the device without consent.
- Local open-weight models by default; cloud models only when the user chooses.
- Every action the agent can take is a capability with a permission and a log entry.

## Pull requests

- Small PRs, one verifiable change each, one writer per branch.
- Title like `[area] Clear outcome`. Body: why, what changed, how it was verified.
- No em dashes or en dashes in commits, PR bodies or UI copy.
- No co-authored-by footers unless the founder asks.
- Squash merge.

## Never

- Commit secrets, API keys or signing material. The xAI key and signing keys
  live in CI secrets or the Keychain.
- Run untrusted PR code on a self-hosted runner. PR checks use GitHub's runners.
- Copy code from MDx without reading it first; MDx carries enterprise
  assumptions and internal names that do not belong here.
