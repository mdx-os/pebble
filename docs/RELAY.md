# The relay protocol

Some tasks are too big for the device: research across many pages, several
steps with tools, or building something. The app can hand such a task to a
relay, a server the person chooses to use, after they have seen exactly
what goes. This page is the draft protocol, version 1. The sign-in part is incomplete
until the cloud policy change lands.

This repository holds only the app's side: the message types in
`PebbleCore/Relay.swift` and this page. It never holds a relay's address,
keys or anything about how a relay is built.

Nothing in any build sends a run yet.

## Before anything goes

The device shows the person the run before it is sent: the brief word for
word, the tools it may use and its limits. Nothing goes until they say yes.
The brief has already been through `Redactor` on the device, so names from
the notes, emails, phone numbers, addresses, card numbers and the private
words are taken out before the person sees it, and what they see is
exactly what is sent.

## Calls

Every path is under the configured cloud address. Signing in is the same
hop as for the cloud, and every call carries the same `Cloud-Session`
header. The sign-in part is incomplete until the cloud policy change lands
with its authentication contract in `docs/CLOUD.md`. This draft does not yet
specify how sessions are issued or validated. A call without a valid session
gets `signInNeeded`.

Bodies are JSON in UTF-8, sent with `Content-Type: application/json`. No
body may be over 8,388,608 bytes; the device refuses a bigger one before
reading it.

| Call | Body | Answer |
| --- | --- | --- |
| `POST v1/runs` | a run request | the run |
| `GET v1/runs/{runId}` | none | the run |
| `POST v1/runs/{runId}/answers` | an answer | the run |
| `POST v1/runs/{runId}/stop` | none | the run |
| `DELETE v1/runs/{runId}` | none | `204`, no body |
| `GET v1/keys` | none | the keys |

A success is `200` with the body above, apart from `DELETE`. Anything else
is an error, below.

### Starting a run: `POST v1/runs`

```json
{
  "clientRunId": "c7Run42",
  "kind": "research",
  "brief": "Look into the pool's new Sunday hours and tell me when it opens.",
  "tools": ["web.search", "web.read"],
  "limits": { "maxMinutes": 20, "maxSteps": 30 },
  "version": 1
}
```

- `clientRunId`: made on the device for this one run. It is the
  idempotency key: the same id twice from the same signed in device starts
  one run, and the second call answers with that same run as it is now. If
  the second body differs from the first, the relay answers `badRequest`
  and changes nothing. The device sends the same id again only when it
  didn't hear back, and never uses an id for another brief.
- `kind`: `research`, `steps` or `build`.
- `brief`: the exact text the person saw in the preview.
- `tools`: the tools the run may use, each named once. The relay uses no
  other. A tool it doesn't offer gets `toolNotOffered`.
- `limits`: the run stops on its own, as `failed`, once it has run
  `maxMinutes` or taken `maxSteps` steps. A limit past what the relay
  allows gets `limitTooHigh`.
- `version`: `1`. Any other gets `versionUnsupported`.

### The run: `GET v1/runs/{runId}`

Every call that changes a run answers with it too.

```json
{
  "runId": "r9Q1",
  "state": "needsYou",
  "steps": [
    { "words": "Planning a few questions", "state": "done" },
    { "words": "Reading the sources", "state": "working" }
  ],
  "needsYou": { "...": "below" },
  "receipts": [],
  "retryAfterSeconds": 10
}
```

- `runId`: made by the relay.
- `state`: `queued`, `working`, `needsYou`, `done`, `failed` or `stopped`.
  The last three are final: nothing more happens to the run.
- `steps`: the run's progress, as lines the person reads. Each step's
  `state` is `waiting`, `working`, `done`, `failed` or `skipped`. The words
  follow the app's voice: plain words, no system jargon.
- `needsYou`: there exactly when `state` is `needsYou`.
- `result`: there exactly when `state` is `done`.
- `receipts`: the run's receipt chain so far, below.
- `retryAfterSeconds`, optional: how long the device should wait before it
  asks again. The device polls with `GET`; nothing is pushed to it.

### A question for the person: `needsYou`

When the run reaches something that needs the person's yes, it waits and
says so:

```json
{
  "questionId": "q1",
  "action": "send",
  "target": { "id": "contact1", "name": "Sam", "handle": "sam@example.com" },
  "summary": "Send the pool's Sunday hours to Sam",
  "expiresAt": "2026-10-18T10:00:00Z"
}
```

- `action`: one of the app's own consequential actions, `send`,
  `purchase` or `sharePersonalInfo`.
- `target`: who it goes to. `name` and `handle` must be exactly what the
  person will be shown: one line each, no hidden characters, `name` at most
  40 code points with no `@`, `handle` at most 254.
- `summary`: one line saying what would happen.
- `price`: required for `purchase`, for example
  `"price": { "minorUnits": 1450, "currency": "CAD" }`. `minorUnits` is a
  positive integer in the currency's smallest unit, at most 9,223,372,036,854,775,807.
  Fractions, zero, negative amounts and overflow are refused. `currency` is
  an uppercase ISO 4217 code in Foundation's common ISO currency list;
  unknown codes and case or whitespace corrections are refused. This maps
  exactly to AskFirst's `Price`, and `RelayQuestion.proposedAction` carries
  that price into the device's approval sheet. A purchase without a price is
  refused, as is a price on any other action.
- `expiresAt`: after this the relay takes the answer as no.

The device asks with its own approval sheet, built from these fields. The
relay never decides for the person, and never acts on a question until its
answer comes.

### Answering: `POST v1/runs/{runId}/answers`

```json
{ "questionId": "q1", "answer": "yes" }
```

`answer` is `yes` or `no`. A question that isn't being asked gets
`questionNotFound`; one past its time gets `questionExpired`.

### Stopping: `POST v1/runs/{runId}/stop`

The relay stops the run at once, makes its state `stopped` and ends the
chain with `run.stopped`. Stopping a run that has already finished changes
nothing and answers with the run as it is.

### Dropping: `DELETE v1/runs/{runId}`

Tells the relay to drop everything about the run now: the brief, the
steps, the result, the receipts and the idempotency key. A run still going
is stopped first. The answer is `204` whether or not the relay still had
the run, so the device can always clear it. After it, `GET` on that run
gets `runNotFound`.

### The result

```json
{
  "text": "The pool opens on Sundays from 9 to 5, starting next week.",
  "sources": [{ "title": "Pool hours", "url": "https://example.com/pool/hours" }],
  "artifacts": [{ "name": "pool-hours.md", "kind": "markdown", "sha256": "...", "bytesBase64": "..." }]
}
```

- `text`: at most 20,000 code points. It may be empty when the artifacts
  are the result.
- `sources`: at most 20. Each `title` is one line of at most 200 code
  points; each `url` is `https`, with a host, printable ASCII, at most
  2,000 bytes.
- `artifacts`: at most 5. `name` is a plain file name: one line, at most
  100 code points, no `/`, `\` or `:` Unicode scalar (even when followed
  by a combining mark), and not starting with `.`. `kind`
  is `text`, `markdown`, `csv`, `json`, `png` or `pdf`. `bytesBase64` is
  the file in standard base64, at most 1,048,576 bytes once decoded, and
  all of a result's artifacts together at most 4,194,304. `sha256` is the
  lowercase hex SHA-256 of those bytes, and the device refuses an artifact
  whose bytes don't match it.

### The keys: `GET v1/keys`

```json
{ "keys": [{ "id": "k1", "ed25519": "..." }] }
```

One to four keys, so the relay can change keys without a gap. `ed25519` is
the 32 bytes of an Ed25519 public key in standard base64. The device takes
a chain signed by any key listed.

### Errors

Every answer that isn't a success has this body:

```json
{ "error": "slowDown", "retryAfterSeconds": 30 }
```

`retryAfterSeconds` is optional. The device acts on `error`, not the
status, and refuses a code that isn't listed here.

| `error` | Status | Means |
| --- | --- | --- |
| `badRequest` | 400 | The body isn't a message this version knows, or a `clientRunId` came again with another body |
| `versionUnsupported` | 400 | `version` is one the relay doesn't speak |
| `signInNeeded` | 401 | No session, or one that has ended |
| `runNotFound` | 404 | No such run, or it was dropped |
| `questionNotFound` | 404 | That question isn't being asked |
| `questionExpired` | 409 | Its time ran out and the relay took it as no |
| `runFinished` | 409 | The run is done, failed or stopped |
| `toolNotOffered` | 422 | A tool the relay doesn't offer |
| `limitTooHigh` | 422 | A limit past what the relay allows |
| `tooLarge` | 413 | The body is too big |
| `tooManyRuns` | 429 | Too many runs at once for this device |
| `slowDown` | 429 | Too many calls; wait `retryAfterSeconds` |
| `unavailable` | 503 | The relay can't take work now |

## How the device reads messages

- Keys it doesn't know are ignored, so a relay can add one without
  breaking an older app. Keys it knows are read strictly.
- A value outside its list is refused: an unknown `state`, `kind`,
  `action`, `answer`, step state, artifact kind, receipt kind or error code.
- `runId`, `clientRunId`, `questionId` and a key's `id` are 1 to 64 ASCII
  letters and digits, nothing else.
- A tool's name is 1 to 40 of lowercase ASCII letters, digits, `.` and
  `_`, starting with a letter.
- Times are `YYYY-MM-DDTHH:MM:SSZ`: UTC, whole seconds, a real date.
- Lengths are counted in Unicode code points unless they say bytes.
  "One line" means no control characters, no line or paragraph
  separators, no characters that turn text around (U+202A to U+202E,
  U+2066 to U+2069), and no space at either end. The brief and the result's
  text may hold line feeds and tabs, and no other control characters.
- `brief`: 1 to 8,000 code points. `tools`: at most 16. `maxMinutes`: 1 to
  120. `maxSteps`: 1 to 200. `steps`: at most 200, each `words` one line of
  at most 280. Target `id`: one line of at most 200. `summary`: one line of
  at most 500. `receipts`: at most 1,000. `retryAfterSeconds`: 1 to 3,600.
- A message that breaks any of these is refused whole.

## Receipts

Receipts let the device check, after the run, that the record of what
happened is the relay's own and hasn't changed since. They are content
free: no receipt carries any words from the brief, the result or the
person.

```json
{
  "runId": "r9Q1",
  "clientRunId": "c1",
  "seq": 2,
  "kind": "tool.used",
  "at": "2026-10-18T09:00:05Z",
  "tool": "web.search",
  "contentSha256": "...",
  "prevHash": "...",
  "hash": "..."
}
```

- `runId` and `clientRunId`: the run and the original request identity,
  present on every receipt and covered by its hash.
- `seq`: 1 for the first receipt, then one more each time.
- `kind`: one of `run.started`, `step.done`, `tool.used`, `needsYou.asked`,
  `needsYou.answered`, `run.done`, `run.failed` and `run.stopped`. The
  first receipt is `run.started`, and only the first. The last three are
  final: one ends the chain and nothing comes after it.
- `at`: when it happened.
- `tool`: on `tool.used`, always, and on nothing else.
- `contentSha256`, optional: the lowercase hex SHA-256 of bytes the relay
  fetched or made, such as a page it read. Never of anything the person
  wrote, and never of a short value that could be guessed.
- `prevHash`: the `hash` of the receipt before it. The first receipt's is
  64 zeros.
- `hash`: the lowercase hex SHA-256 of the receipt's canonical form.
- `signature`: on the final receipt, always, and on nothing else.

### The canonical form

Nine lines, each ending in a line feed (0x0A), in UTF-8, with nothing
before or after:

```
relay-receipt/1
runId:<runId>
clientRunId:<clientRunId>
seq:<seq in decimal, no leading zeros>
kind:<kind>
at:<at, exactly as sent>
tool:<tool, or nothing>
contentSha256:<contentSha256, or nothing>
prevHash:<prevHash>
```

An absent `tool` or `contentSha256` is written as nothing after its colon,
so its line is just `tool:` or `contentSha256:`. Every value is ASCII by
the rules above, so the form has one reading.

### The signature

The final receipt's `signature` is the 64 byte Ed25519 signature (RFC 8032)
over the 32 bytes of its `hash`, the hex turned back into bytes, in
standard base64. Since each hash covers the one before it, it signs the
whole chain. The key signs nothing else.

### What the device checks

1. The chain is not empty and starts with `run.started`.
2. `seq` runs 1, 2, 3 and on, with no gap.
3. Each `prevHash` is the hash before it, and 64 zeros for the first.
4. Each `hash` is the SHA-256 of that receipt's canonical form.
5. Nothing comes after a final receipt, and `run.started` comes only first.
6. Every receipt's `runId` and `clientRunId` match the expected identities
   kept by the device, independently of the chain being checked.
7. The final receipt matches the expected terminal state: `run.done` for
   `done`, `run.failed` for `failed`, or `run.stopped` for `stopped`. A
   nonterminal expected state is refused.
8. The final receipt's signature checks with a key from `GET v1/keys`.

`RelayReceipts.verify` requires the expected `runId`, `clientRunId` and
terminal state as well as the public key. For completed chains checked
with `verify`, a changed field, a dropped receipt or a reordered pair each
fails, as does replaying a valid chain for another run or terminal state.

The overload `RelayReceipts.verify(run, clientRunId:publicKey:)` checks a
whole `RelayRun`, using its own `runId` and `state` as the expected receipt
context. The client ID must come from the device's original request. When
polling, the caller must also match the response's `runId` to the requested
run. Decoding a run alone does not authenticate its receipts.

While a run is going, `checkLinks` checks steps 1 to 5 on the chain so far.
It cannot detect truncation or authenticate the chain. Those guarantees
require `verify` on a completed chain with the expected context.

## Retention

**Draft: no build uses runs yet.** The policy version for runs comes
later; until then the app's cloud policy is unchanged.

To serve this app, a relay must keep:

- Run content, the brief, the steps, the questions, the answers, the
  result and the receipts, in memory only. Never written to disk, and
  never to logs.
- Each run's content only until the device deletes the run or 30 minutes
  after it ends, whichever comes first.
- Beyond that, only counts of runs and of errors, kept for 7 days.

## Conformance vectors

The files in `Packages/PebbleKit/Tests/PebbleCoreTests/Fixtures/relay/`
are the vectors a relay can check itself against. Each is named
`<message>.valid.<case>.json` or `<message>.invalid.<reason>.json`. A
valid file must read and write back to the same JSON, less any keys this
version doesn't know. An invalid file must be refused. The `receipts`
files are lists of receipts: the valid one links, and each invalid one
reads as receipts but fails the checks above. The final receipts in these
files carry a signature of 64 zero bytes, and the keys file a key of 32
zero bytes, so they show the shape only; the signature checks are tested
with keys made at run time, and no real key is ever written down.

Run requests:

- `run-request.valid.research.json`
- `run-request.valid.no-tools.json`
- `run-request.valid.extra-keys.json`: unknown keys, ignored
- `run-request.invalid.unknown-kind.json`
- `run-request.invalid.client-run-id-not-plain.json`
- `run-request.invalid.client-run-id-too-long.json`
- `run-request.invalid.brief-empty.json`
- `run-request.invalid.brief-too-long.json`
- `run-request.invalid.missing-brief.json`
- `run-request.invalid.max-minutes-over.json`
- `run-request.invalid.max-steps-zero.json`
- `run-request.invalid.tool-name.json`
- `run-request.invalid.tools-repeated.json`
- `run-request.invalid.too-many-tools.json`
- `run-request.invalid.version-2.json`

Runs:

- `run.invalid.artifact-combining-dot.json`
- `run.invalid.non-purchase-price.json`
- `run.invalid.purchase-price-missing.json`
- `run.valid.purchase.json`
- `run.invalid.purchase-price-zero.json`
- `run.invalid.purchase-price-negative.json`
- `run.invalid.purchase-price-fraction.json`
- `run.invalid.purchase-price-overflow.json`
- `run.invalid.purchase-price-currency.json`
- `run.invalid.purchase-price-lowercase.json`
- `run.invalid.purchase-price-null.json`
- `run.invalid.target-combining-name.json`
- `run.invalid.target-combining-handle.json`
- `run.invalid.artifact-combining-slash.json`
- `run.invalid.artifact-combining-backslash.json`
- `run.invalid.artifact-combining-colon.json`

- `run.valid.queued.json`
- `run.valid.working.json`
- `run.valid.needs-you.json`
- `run.valid.done.json`
- `run.valid.failed.json`
- `run.valid.stopped.json`
- `run.valid.extra-keys.json`: unknown keys, ignored
- `run.invalid.unknown-state.json`
- `run.invalid.run-id-empty.json`
- `run.invalid.run-id-not-plain.json`
- `run.invalid.unknown-step-state.json`
- `run.invalid.step-words-too-long.json`
- `run.invalid.too-many-steps.json`
- `run.invalid.needs-you-without-state.json`
- `run.invalid.needs-you-state-without-question.json`
- `run.invalid.unknown-action.json`
- `run.invalid.question-id-not-plain.json`
- `run.invalid.handle-hidden-character.json`
- `run.invalid.target-name-too-long.json`
- `run.invalid.summary-too-long.json`
- `run.invalid.expires-not-utc.json`
- `run.invalid.done-without-result.json`
- `run.invalid.result-before-done.json`
- `run.invalid.source-not-https.json`
- `run.invalid.too-many-sources.json`
- `run.invalid.artifact-hash-mismatch.json`
- `run.invalid.artifact-name-folder.json`
- `run.invalid.unknown-artifact-kind.json`
- `run.invalid.unknown-receipt-kind.json`
- `run.invalid.receipt-tool-missing.json`
- `run.invalid.receipt-signature-not-final.json`
- `run.invalid.receipt-final-unsigned.json`
- `run.invalid.receipt-hash-not-lowercase.json`
- `run.invalid.retry-after-over.json`

Answers:

- `answer.valid.yes.json`
- `answer.valid.no.json`
- `answer.invalid.unknown-answer.json`
- `answer.invalid.question-id-not-plain.json`

Keys:

- `keys.valid.one.json`
- `keys.invalid.empty.json`
- `keys.invalid.too-many.json`
- `keys.invalid.wrong-length.json`

Errors:

- `error.valid.slow-down.json`
- `error.valid.run-not-found.json`
- `error.invalid.unknown-code.json`
- `error.invalid.retry-after-zero.json`

Receipt chains:

- `receipts.valid.done.json`
- `receipts.invalid.changed-field.json`
- `receipts.invalid.dropped.json`
- `receipts.invalid.reordered.json`
- `receipts.invalid.prev-hash.json`
- `receipts.invalid.not-started.json`

## Changing the protocol

A change a version 1 app can't read gets a new `version`, a new path
prefix (`v2/`), and a new copy of this page. Adding an optional key is not
such a change.
