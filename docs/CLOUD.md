# The cloud service

Help from the cloud is off until the person turns it on. This page says what
the service is, who runs it, what it keeps and what signing in sends. The app
says the same things in the same words: they come from `CloudPolicy` in
`PebbleCore`, and `CloudPolicyTests` holds this page to them.

Policy version: `mdx-zero-retention-1`

## In short

MDx runs the cloud service itself. It stores no message bodies, only counts of requests and errors, kept for 7 days. Sign-in sends only Apple's anonymous user ID and a key made on the device, never an email or a name.

## What it is

A small service that answers a chat with a bigger model than the one on the
device. The app sends it a chat only after the person has seen the whole
request in the preview and said yes. What it sends is redacted on the device
first.

## Who runs it

MDx runs it, as a small service on its own existing hosting. No other
company is handed the requests.

The app says:

- "Your messages go to a server MDx runs itself. MDx doesn't hand them to anyone else."

## What it keeps, and for how long

No request bodies are stored. The service keeps only aggregate counts, how
many requests came in and how many failed, and drops them after 7 days.
Nothing from any message is in those counts.

The app says:

- "MDx doesn't save what you send. It keeps only a count of messages and problems, for 7 days."
- In the preview: "This goes to MDx's own server. MDx doesn't save it, and keeps only a count of messages and problems for 7 days."

## What signing in sends

Sign in with Apple, with no scopes asked for, so Apple shares neither the
person's email nor their name. The sign-in hop then carries exactly two
values, and nothing else:

- `appleUser`: Apple's anonymous user ID for the person with this app.
- `deviceKey`: a random key made on the device, kept in the Keychain for
  this device only. It is never synced and never restored to another device
  from a backup.

`appleUser` goes exactly as Apple gives it. `deviceKey` is 32 random bytes
written as 64 letters from `a` to `p`, so the check that hides personal
details can never mistake it for a phone number or a card number and refuse
the sign-in.

The hop is shown in the same preview as the message, above it, with its
values covered, and only the person's yes sends it. Its answer is
`{"session": "..."}`, a session made only of letters, at least 16 of them.
The app keeps it in memory only, and sends it on later messages as the
`Cloud-Session` header, which the preview shows, covered. Any other answer
is dropped, and the next message signs in again.

The app says:

- "Signing in sends just two things: the anonymous ID Apple gives this app for you, and a random key I made for signing in. Never your email or your name."

## What it never sends

- The person's email or name, from Apple or anywhere else.
- Notes. Names from the notes, emails, phone numbers, addresses, card
  numbers and the private words are taken out of every message first.
- Anything from a chat in which the person said they might be in danger.
- Anything at all while the cloud is off, or before the person says yes to
  the preview.

## Forget everything and switching the cloud off

Both end every open cloud chat, then remove the Apple ID and the device key
from the Keychain and drop the session, so the next sign-in starts fresh
with a new key. What was already sent can't be erased from the device; the
service never kept it.

The app says:

- "Turning this off or using Forget everything erases that ID and key, so I sign in fresh next time."

## Which builds may reach it

`Config/Cloud.xcconfig` declares `PEBBLE_CLOUD_POLICY = mdx-zero-retention-1`
and keeps the address empty. A real address goes only in the git-ignored
`Config/Cloud.local.xcconfig`. A build that could ship (anything but a
Debug build that isn't an archive) with an address fails unless
`PEBBLE_CLOUD_POLICY` equals `CloudPolicy.currentVersion` and the address is
plain https (`scripts/release-endpoint-check.sh`). The app itself reads the
address in such a build only when its Info.plist names that same policy
(`CloudEndpoint`), so it always shows the words of the service it reaches.

Any change to what the service does, or to the words above, gets a new
policy version in `CloudPolicy`, `Config/Cloud.xcconfig` and this page,
together.

## For the owner: before the first real sign-in

These need the Apple developer account, so the code stops short of them:

1. Turn on the Sign in with Apple capability for the app's App ID.
2. Add the `com.apple.developer.applesignin` entitlement (value `Default`)
   to the app, with signing set up for the team.
3. On the Mac, sign the app with a team, so it can use the data protection
   Keychain the device key is kept in.
4. Wire a Sign in with Apple button into the turn on question, using
   `AppleCloudAuth.appleIDRequest()` and passing the credential to
   `AppleCloudAuth.accept(_:)`. Until then the app has no Apple ID, and no
   sign-in hop is made.
5. Have the server take `appleUser` and `deviceKey` as described above, answer with a letters-only session, and keep nothing but the
   counts. Note that the Apple ID alone is not proof of who signed in: Apple's
   identity token would prove it, but sending it is a third value and needs
   a new policy version.
6. Put the address in `Config/Cloud.local.xcconfig` on the build machine.
