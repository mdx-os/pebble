# Working in pebble

pebble is the codebase for Mia, an open-source personal agent for Mac, iPhone
and iPad. Humans direct and review; agents write most of the code. This file
is a map. Keep it short, and add a line whenever an agent makes a mistake that
a line here would have prevented.

## The one rule

Prove your work against the real thing. `make verify` must pass before you
open a PR, and a UI change needs before-and-after screenshots from
`make screenshots`. "It compiles" is not proof.

## Commands

- `make verify`: everything CI runs (brand check, tests, builds, screenshots)
- `make test`: package unit tests (Swift Testing)
- `make screenshots`: `build/screenshots/{iphone,ipad,mac}.png`
- `make generate`: regenerate `Pebble.xcodeproj` after editing `project.yml`
- `make secrets-check`: gitleaks over git history

## Layout and layers

- `App/`: one app target for all three platforms. Keep it thin.
- `Packages/PebbleKit/`: shared code in layers. A layer imports only layers
  below it; `Package.swift` enforces this.
  - `PebbleCore`: plain types. No SwiftUI, no networking.
  - `PebbleUI`: SwiftUI views shared by every platform.
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

## Never

- Commit secrets, API keys or signing material. The xAI key and signing keys
  live in CI secrets or the Keychain.
- Run untrusted PR code on a self-hosted runner. PR checks use GitHub's runners.
- Copy code from MDx without reading it first; MDx carries enterprise
  assumptions and internal names that do not belong here.
