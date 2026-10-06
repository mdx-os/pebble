# Permissions and receipts

The agent may act only with a permission, and every action that leaves the device or changes something outside it leaves a receipt on the device. This note is the design for that rule. It adds no code, no network calls, and no telemetry.

Two open standards describe how a personal agent connects to a business. pebble does not adopt either protocol, SDK, or network flow. The shapes below are local, and a later connector can map them onto either standard without changing what the person sees.

- [Personal Agent Protocol](https://sierra.ai/blog/introducing-personal-agent-protocol) (Sierra and Meta, announced 6 October 2026). An OAuth session. The person chooses read-only or write. A session may start as a guest. The v0.1 specification is planned for later in October 2026.
- [PACT](https://decagon.ai/blog/introducing-the-personal-agent-consent-trust-protocol-pact) (Decagon and Instinct, announced 6 October 2026). Agent-to-agent communication plus the OAuth device flow. Each business defines its own scopes. Identity is separate from authority. If a step needs more authority, the conversation pauses in an authorization-required state and then continues. Actions under a grant can return a signed receipt.

## The rule

A connection to an outside account or service is either read-only or write. The person chooses that level, can stop it at any time, and can see every grant in one place.

The agent does not ask for a broad grant up front, and it does not fail a task that is only short on access. It pauses that conversation and asks for the one step up this task needs. Nothing for that step leaves the device until the person answers.

A receipt records what was done, which request it served, which permission covered it, when it happened, and the result. Receipts stay on the device.

The name the person gave the agent is not an account and not a contact. Grants name a service and an account.

## What the person sees

### Allowing a connection

The chat pauses before the first use of an account. The ask matches the step.

Looking only:

> I need a connection to Northwind to look up that order. It would only look, and you can stop it any time.

Choices: **Only look** and **Not now**.

A change, and no connection yet:

> Changing that order needs a connection to Northwind that can make changes. You can stop it any time.

Choices: **Allow changes** and **Not now**.

The ask names one service and one step. It does not offer other services, and it does not offer changes when looking is enough.

### Asking for a step up

If the connection can already look, and this step would change something:

> I can look at Northwind. Changing this order needs permission to make changes on that connection.

Choices: **Allow changes** and **Not now**.

The same conversation waits. **Not now** continues without that step. The agent does not repeat the ask in the same turn.

### Stopping a connection

**Connections** lists every grant: the service, the account, **Only looking** or **Can make changes**, and the day it was allowed. **Stop this** turns that grant off immediately. A later task that needs it pauses and asks again. Receipts already written stay.

### Looking through receipts

**What I did** lists receipts, newest first. Opening one shows a plain sentence, the request it belonged to, the connection it used, whether that connection could look or make changes, the time, and whether it worked. The list stays on the device.

> Tuesday, 3:14 pm. Looked up your open order at Northwind, for "where's my package?". Used the connection that can only look. It worked.

## Data shapes

These are the records a later change would add to `PebbleCore`. They are plain values. No SwiftUI, no networking, no tokens, no credentials.

```text
Access
  readOnly | write

Account
  id
  serviceName          plain name the person sees
  accountLabel         how the person recognizes the account
                       no secrets, no passwords

Grant
  id
  accountId
  access               the ceiling the person chose
  grantedAt
  revokedAt            empty while the grant is active
  externalScopes       optional opaque labels from a future connector
                       each label is itself readOnly or write
                       pebble does not interpret them

Capability
  id
  title                plain words
  access               readOnly looks; write changes something outside
  leavesDevice         true when the action sends anything off the device

StepUp
  id
  requestId            the conversation turn that is waiting
  accountId            empty when the connection does not exist yet
  serviceName
  accountLabel
  from                 empty, or readOnly
  to                   the one level this step needs
  state                waiting | allowed | declined

Receipt
  id
  at
  requestId
  capabilityId
  grantId              empty only when no account was involved
  access               the access the action used
  summary              one plain sentence
  result               completed | failed
  externalReceipt      optional opaque bytes a connector returned
                       kept on device, never uploaded by pebble
```

- One account has at most one active grant. Write is a higher ceiling on that same grant, not a second grant. Write covers looking. Read-only does not cover a change.
- The agent may run a capability only when an active grant for that account is at least the capability's access.
- If the grant is missing or too low, the agent records a `StepUp` in `waiting` and does not run the capability.
- Running a capability that leaves the device, or whose access is write, writes one receipt, including when the result is `failed`.
- Declining a step-up runs nothing and writes no receipt. The conversation already shows the ask.
- Stopping a grant sets `revokedAt`. Older receipts stay.
- `Account` is identity. `Grant.access` is authority. They are stored separately so a later connector can follow either standard's split.

## Staying compatible

| Local record | Personal Agent Protocol | PACT |
| --- | --- | --- |
| `Access.readOnly` | The person chose read-only on the OAuth session | Business scopes that do not change the account |
| `Access.write` | The person chose write | Business scopes that change the account |
| `StepUp` in `waiting` | The person decides before access is raised; the visit is not failed | `authorization-required`; the same conversation continues |
| `externalScopes` | Unused until a connector has a finer session limit | The business's own scope strings, grouped under read-only or write |
| `externalReceipt` | No receipt in the announcement; company visibility stays on the company side | The signed receipt of scopes used and actions taken, stored here as opaque bytes |
| Guest look, no account | A guest session for something like product availability | No delegation token; identity of the agent is a connector concern, not this layer |

A connector, if one is added later, translates at its own boundary. `PebbleCore` still stores only the records above. Signing, OAuth, device login, and agent-to-agent sessions are that connector's job. The person still sees **Only look**, **Allow changes**, **Not now**, and **Stop this**.

## Where a later change would live

- `PebbleCore`: `Access`, `Account`, `Grant`, `Capability`, `StepUp`, `Receipt`.
- A new package layer above `PebbleCore` would talk to a service. It is not part of this design, and it does not belong in `PebbleCore`.
- `PebbleUI`: the in-chat ask, **Connections**, and **What I did**.
- On-device storage, beside the agent's name. No sync in this design.

## Out of scope

OAuth, device login, signed agent identity, agent-to-agent sessions, MCP, OpenAPI, push notifications, payments, telemetry, and any upload of grants or receipts.

## Open questions for Mandeep

Privacy and permission choices below need Mandeep's call. The proposal is the default written above.

1. May the first grant be write when the step needs a change, or must every connection start at read-only, with write only as a later step up?
2. Does write include looking, or is looking always its own grant?
3. If a business scope is missing or unclassified, treat it as write and ask, or as read-only and proceed? Proposal: treat it as write and ask.
4. Show only **Only look** and **Allow changes**, or also show the business's own scope words under that choice?
5. A public or guest look that leaves the device and sends nothing about the person's account: write a receipt with no grant, or refuse until there is a grant?
6. Should a declined step-up, or stopping a grant, write a receipt? Proposal: no.
7. How long do receipts stay, and may the person delete them?
8. May grants or receipts ever leave the device, including export, share, or iCloud backup? Proposal: no.
9. If the person stops a grant while a request has already been sent, finish that request and record it, or try to cancel it?
10. Confirm the person-facing words: **Only look**, **Allow changes**, **Not now**, **Stop this**, **Connections**, **What I did**.
