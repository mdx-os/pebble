# Permissions and receipts

The agent may act only with a permission, and every action that leaves the device or changes something outside it leaves a receipt on the device. This note is the design for that rule. It adds no code, no network calls, and no telemetry.

Two open standards describe how a personal agent connects to a business. pebble does not adopt either protocol, SDK, or network flow. The shapes below are local. A later connector can map them onto either standard without changing what the person sees.

- [Personal Agent Protocol](https://sierra.ai/blog/introducing-personal-agent-protocol), announced 6 October 2026. An OAuth session. The person chooses read-only or write. A session may start as a guest. The v0.1 specification was planned for later in October 2026.
- [PACT](https://decagon.ai/blog/introducing-the-personal-agent-consent-trust-protocol-pact), announced 6 October 2026. Agent-to-agent communication plus the OAuth device flow. Each business defines its own scopes. Identity is separate from authority. If a step needs more authority, the conversation pauses in an authorization-required state and then continues. Actions under a grant can return a signed receipt.

The mapping table later in this note is provisional. Check it again when those specifications are published.

## The rule

A change is allowed one step at a time. **Allow this change** covers that step only. It is bound to one capability and a hash of that action's parameters. It runs once. Proposal, pending Mandeep: it expires at the end of the turn.

Standing write access is a different choice, **Always allow changes on this account**, made on the Connections screen. It is not the default, and it is not what the step-up ask grants. It has an expiry and a last-used time.

An irreversible capability always asks for that action, even when standing write is on. A capability that moves money cannot be represented until money has its own design. A write grant is not permission to pay.

A connection the person leaves in place can be read-only. Proposal, pending Mandeep: write includes looking, and read-only does not include a change.

The person can stop a grant at any time. **Connections** on this device lists every grant on this device. Grants are not synced to the person's other devices.

The agent does not ask for a broad grant up front, and it does not fail a task that is only short on access. It pauses and asks for the one step this task needs. Nothing for that step leaves the device until the person answers, and nothing leaves if they say **Not now**.

A receipt records what was done, which request it served, which permission covered it, when, and the result. The summary describes the action. It does not quote the person. Receipts stay on this device.

The name the person gave the agent is not an account and not a contact. Grants name a service and the account label that service returns after sign-in.

## What the person sees

The ask is filled in from the capability and the account. The model does not write it. Text from a page or a service does not choose the account or the access level. Only a tap moves an ask to allowed.

The account label is the one the service returns after sign-in. The ask shows that label before anything is sent. The agent does not invent a label. Until the service has returned one, the action waits.

### Allowing a look

> Look up orders at Northwind, on the account Northwind calls "Ada". This sends that question to Northwind. The connection can only look, and you can stop it any time.

Choices: **Only look** and **Not now**.

**Only look** is a standing read on that account. It does not allow changes.

### Allowing one change

> Change this order at Northwind, on the account Northwind calls "Ada". This allows that one change and nothing later.

Choices: **Allow this change** and **Not now**.

There is no **Always allow changes** button on this ask.

### Standing write

On **Connections**, each account can offer a separate control:

> Always allow changes on this account

The row shows when that permission expires and when it was last used. It covers later reversible changes on that account. It does not cover irreversible actions, and it does not cover money.

### An irreversible change

> Delete this order at Northwind, on the account Northwind calls "Ada". This cannot be undone. This allows that one change and nothing later.

Choices: **Allow this change** and **Not now**. Standing write does not skip this ask.

### A public look

> Look this up at Northwind. No account is used. This sends only the question, and it is recorded on this device.

Choices: **Look this up** and **Not now**.

Proposal, pending Mandeep: this ask is the default. A device setting, **Allow public lookups**, can skip the ask after the person turns it on. Either way, the look writes a receipt. It may send only the fields that capability lists. It sends nothing from an account, nothing from other conversations, and not the agent's name.

### After Not now

The conversation continues without that step. The agent does not ask again in that conversation for the same account and capability unless the person brings that action up.

### Stopping a connection

**Connections on this Mac**, **Connections on this iPhone**, or **Connections on this iPad** lists every grant on that device: the service, the account label from the service, **Only looking** or **Can make changes**, when it was allowed, when it expires, and when it was last used.

**Stop this** turns the grant off on this device before any later send. The connector deletes its credentials for that account and, where the service has one, calls the revocation endpoint. If the service cannot confirm, the row says **Stopped on this device**.

A request already sent is allowed to finish. Its receipt says it was sent before the stop. A later task that needs the grant pauses and asks again. Receipts already written stay until the person deletes them or they pass the retention time below.

### Looking through receipts

**What I did on this Mac**, **What I did on this iPhone**, or **What I did on this iPad** lists receipts on that device, newest first. Opening one shows the action, the service, the permission it used, the time, and the result. It does not show the person's words.

> Tuesday, 3:14 pm. Looked up an open order at Northwind. Used the connection that can only look. It worked.

## Data shapes

These are the records a later change would add to `PebbleCore`. They are plain values. No SwiftUI, no networking, no tokens, and no credentials. Parameter values are not stored. The step keeps a hash, and the parameters themselves live in memory only until the turn ends.

```text
Access
  readOnly | write

Account
  id
  serviceName          plain name the person sees
  accountLabel         returned by the service after sign-in
                       shown on the ask
                       no secrets, no passwords

Grant
  id
  accountId
  access               readOnly, or write only after the standing choice
  grantedAt
  expiresAt            set for standing write; empty for read-only
  lastUsedAt
  revokedAt            empty while the grant is active
  externalScopes       labels a connector stored after authorization
                       each label classified readOnly or write
                       from that connector's local allowlist

Capability
  id
  title                plain words the ask is built from
  access               readOnly looks; write changes something outside
  leavesDevice         true when the action sends anything off the device
  reversible           false means every action asks, even with standing write
  sendFields           the only fields a look or a change may send

StepUp
  id
  requestId            the turn that is waiting
  capabilityId
  parameterHash        SHA-256 of the canonical parameter bytes
  accountId            empty for a public look
  serviceName
  accountLabel         from the service; empty until sign-in returns it
  from                 empty, or readOnly
  to                   the one level this step needs
  createdAt
  expiresAt            proposal: the end of the turn
  state                waiting | allowed | declined | expired | used

Receipt
  id
  at
  requestId
  capabilityId
  parameterHash
  grantId              empty when no account grant was used
  stepUpId             set when a one-step allow was used
  access
  summary              capability title and service; no quote, no parameter values
  result               started | completed | failed | unknown
  sentBeforeStop       true only if the send had already happened when the person stopped the grant
  previousHash         SHA-256 of the previous receipt's immutable fields; empty on the first
  chainHash            SHA-256 of this receipt's immutable fields
  externalReceipt      optional opaque bytes, at most 64 KiB
                       a larger payload keeps its SHA-256 and byte length, not the body

PublicLookup
  allowed              device setting, default false
```

Immutable receipt fields are everything except `result` and `sentBeforeStop`. Updating those two does not break the chain. Rewriting a summary, or losing a receipt, does.

## Rules

- **Allow this change** creates a `StepUp`. It does not set `Grant.access` to write.
- The step matches one `capabilityId` and one `parameterHash`. A different parameter set is a different step.
- A step in `allowed` runs at most once. The send marks it `used`. When the turn ends, a step that is still `waiting` or `allowed` becomes `expired` and cannot run. A killed app is a turn that ended.
- Standing write is a `Grant` with `access = write`, created only from **Always allow changes on this account**. Proposal, pending Mandeep: it expires 30 days after `lastUsedAt`. Standing read stays until the person stops it.
- Proposal, pending Mandeep: write includes looking. Read-only does not cover a change.
- Irreversible capabilities (`reversible = false`) ignore standing write and require a matching one-step allow.
- No capability may move money. There is no access level, id, or scope that means pay, transfer, or purchase. Those wait for a separate design.
- Proposal, pending Mandeep: each connector classifies scopes with a local allowlist. A missing or unclassified scope counts as write and is asked. The business does not get to label a change as read-only. After authorization, the granted scopes must fall inside the ceiling the person chose. If they do not, the connector revokes and the action fails.
- The grant or the one-step allow is checked at send time, in the same transaction that appends the receipt with `result = started`. It is not checked only when the step is planned.
- That transaction also sets `used` on the step, or `lastUsedAt` on the standing grant, and only then may the connector send.
- If the process dies after the send, or the outcome never comes back, a later open moves a receipt still in `started` to `unknown`.
- A normal finish sets `completed` or `failed`.
- The store is append-only. The only writes to an existing receipt are `result` and `sentBeforeStop`. The person may delete one receipt or all of them. A deletion leaves a tombstone that keeps `id`, `previousHash`, and `chainHash`, and drops the summary and any external bytes, so the chain still links and the content is gone.
- Declining a step runs nothing and writes no receipt. Stopping a grant writes no receipt of its own. Proposal, pending Mandeep: keep both of those.
- `Account` is identity. `Grant.access` and `StepUp` are authority. They are stored separately so a later connector can follow either standard's split.

## Store

The store is `PermissionStore`, a file at `Application Support/pebble/permission-store`.

It is not `UserDefaults`, and it is not `UserDefaultsAgentNameStore`. The agent's name may stay where it is. Grants, step-ups, receipts, and the public-lookup setting must not.

- The file is excluded from backup (`isExcludedFromBackup`).
- On iOS, Data Protection is `complete`. This design does not read the file in the background or before the first unlock, so it does not use `completeUntilFirstUserAuthentication`.
- On macOS, the file is encrypted with a key kept in the Keychain. That item is not synchronizable, and its accessibility is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Proposal, pending Mandeep: receipts are kept 90 days. The person can delete one or all. Deleting a conversation keeps its receipts. There is no quoted text to strip, because summaries never quote the person. Nothing in this store is exported, shared, or synced.

## Staying compatible

Provisional. The specifications were not published when this note was written. Check this table again when they are.

| Local record | Personal Agent Protocol | PACT |
| --- | --- | --- |
| `Access.readOnly` | The person chose read-only on the OAuth session | Allowlisted business scopes that do not change the account |
| Standing `Access.write` | The person chose ongoing write, as a separate choice from one step | Allowlisted business scopes that change the account, only after that standing choice |
| `StepUp` in `waiting` | The person decides before this step runs; the visit is not failed | `authorization-required`; the same conversation continues |
| `StepUp` used once | One approval does not raise the session to standing write | One authorization-required grant does not become a standing scope set |
| `externalScopes` | Finer session limits, checked against the local ceiling | The business's scope strings, classified by the connector's allowlist |
| `externalReceipt` | No receipt in the announcement; company visibility stays on the company side | The signed receipt, stored here as opaque bytes within the size cap |
| Public look | A guest session, still with a local permission and a receipt | No delegation token; the local permission and receipt still apply |

A connector, if one is added later, translates at its own boundary. `PebbleCore` still stores only the records above. Signing, OAuth, device login, and agent-to-agent sessions are that connector's job. Credentials live in the connector, not in `PermissionStore`, and **Stop this** deletes them. The person still sees **Only look**, **Allow this change**, **Not now**, and **Stop this**.

## Where a later change would live

- `PebbleCore`: `Access`, `Account`, `Grant`, `Capability`, `StepUp`, `Receipt`, `PublicLookup`.
- `PermissionStore` in Application Support, as above.
- A new package layer above `PebbleCore` would talk to a service. It is not part of this design, and it does not belong in `PebbleCore`.
- `PebbleUI`: the in-chat ask, **Connections on this device**, and **What I did on this device**.

## Out of scope

OAuth, device login, signed agent identity, agent-to-agent sessions, MCP, OpenAPI, push notifications, payments and any other money movement, telemetry, and any upload of grants or receipts.

## Proposals that need Mandeep's call

These are the defaults written above. Privacy and permission choices stay his to change.

1. Standing write expires 30 days after last use. Standing read lasts until the person stops it.
2. Write includes looking. Looking is not its own extra grant once write is on.
3. A connector's local allowlist classifies scopes. A missing or unclassified scope counts as write and is asked. Granted scopes that exceed the ceiling revoke and fail.
4. Show only the plain choices, not the business's own scope words under them.
5. A public look asks every time unless the person turns on **Allow public lookups**. It always writes a receipt, and it sends only that capability's fields.
6. A declined step-up does not write a receipt. Stopping a grant does not write one either.
7. Receipts are kept 90 days. The person can delete one or all. Deleting a conversation keeps the receipts.
8. Grants and receipts do not leave the device: no export, no share, no sync, and the file is excluded from backup.
9. A one-step allow expires at the end of the turn.
10. Confirm the words: **Only look**, **Allow this change**, **Not now**, **Always allow changes on this account**, **Stop this**, **Stopped on this device**, **Allow public lookups**, **Connections on this Mac** (or iPhone, or iPad), **What I did on this Mac** (or iPhone, or iPad).
