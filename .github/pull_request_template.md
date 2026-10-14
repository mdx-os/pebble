## Why

<!-- The problem or outcome, in one or two sentences. -->

## What changed

<!-- The change, small enough to review in one sitting. -->

## Evidence

<!-- Required for any change in behavior. Show Mia actually running:
     screenshots from `make screenshots` or a short screen recording.
     For non-UI work, paste the exact `make verify` or test output. -->

## Risk lane

- [ ] Fast: only docs, tests or test-only files. Add the `fast-lane` label to auto-merge once CI is green.
- [ ] Gated: touches app code, entitlements, Info.plist, dependencies, workflows, privacy or permissions copy, brand, or AGENTS.md. Mandeep merges.
