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

- `make verify`: brand check, tests, builds, and screenshots. CI runs this in the verify job, and runs `make secrets-check` as its own step.
- `make test`: package unit tests (Swift Testing)
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
  - `PebbleModel`: model adapter. `ModelClient` and the on-device placeholder. Imports PebbleCore. MLX and Ollama adapters plug in here.
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

- Warm first: plain human words in the UI, no system jargon.
- Private by default: personal content never leaves the device without consent.
- Local open-weight models by default; cloud models only when the user chooses.
- Every action the agent can take is a capability with a permission and a log entry.

## Pull requests

- Small PRs, one verifiable change each, one writer per branch.
- Title like `[area] Clear outcome`. Body: why, what changed, how it was verified.
- No em dashes or en dashes in commits, PR bodies or UI copy.
- No co-authored-by footers unless the founder asks.
- Squash merge.
- Push after every verified unit of work.

## Never

- Commit secrets, API keys or signing material. The xAI key and signing keys
  live in CI secrets or the Keychain.
- Run untrusted PR code on a self-hosted runner. PR checks use GitHub's runners.
- Copy code from MDx without reading it first; MDx carries enterprise
  assumptions and internal names that do not belong here.

## Enforcement

What checks each rule today. The kind is CI job, type, lint, test, or docs.
Docs means nothing fails when the rule is broken, so a repeat miss can move
to a stronger kind. The verify CI job runs `make verify` (brand check, tests,
builds, screenshots). A separate CI step runs `make secrets-check`.

| Rule | Enforcement |
| --- | --- |
| `make verify` passes on a pull request | CI job |
| Run `make verify` before opening the PR. A compile or a green CI run is not enough | docs |
| A UI change includes before-and-after screenshots from `make screenshots` | docs |
| The second time a mistake shows up, make it a lint, a skill, or a CI gate | docs |
| `App/` stays one thin target for Mac, iPhone and iPad | docs |
| A layer imports only layers below it, as listed in `Package.swift` | type |
| `PebbleCore` stays plain types: no SwiftUI and no networking | docs |
| New code goes in a package, not in `App/` | docs |
| A new layer is added to `Package.swift` with its place in the order written down | docs |
| The product name lives only in `Config/Brand.xcconfig`. Code reads `Brand` and never spells it (`make brand-check`) | lint |
| Code, modules, bundle IDs and the repo use the codename `pebble` | docs |
| Each user may name their own agent. That name is not a contact (`AgentNameTests`) | test |
| Warm first: plain human words in the UI, no system jargon | docs |
| Personal content stays on the device unless the person agrees it can leave | docs |
| Local open-weight models are the default. Cloud models run only when the person chooses | docs |
| Every action the agent can take is a capability with a permission and a log entry | docs |
| Small PRs, one verifiable change each, one writer per branch | docs |
| Title like `[area] Clear outcome`. Body: why, what changed, how it was verified | docs |
| No em dashes or en dashes in commits, PR bodies or UI copy | docs |
| No co-authored-by footers unless the founder asks | docs |
| Squash merge | docs |
| Push after every verified unit of work | docs |
| Do not commit secrets, API keys or signing material (`make secrets-check`) | CI job |
| Do not run untrusted PR code on a self-hosted runner. PR checks use GitHub's runners | docs |
| Read MDx code before copying it. Leave enterprise assumptions and internal names out | docs |
