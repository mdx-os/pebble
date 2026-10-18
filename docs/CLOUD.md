# The cloud service

Help from the cloud is off until the person turns it on. This page says what
the service is, who runs it, what it keeps and what signing in sends. The app
says the same things in the same words: they come from `CloudPolicy` in
`PebbleCore`, and `CloudPolicyTests` holds this page to them.

Policy version: `mdx-zero-retention-2`

## In short

MDx runs the cloud service itself. It stores no message bodies, only counts of requests and errors, kept for 7 days. Sign-in sends only Apple's identity token, a one-time nonce and a key made on the device, never an email or a name. The server checks the token once (Apple's signature, iss, aud, exp and the nonce), keeps only Apple's anonymous user ID (sub) and the device key, and throws the token away.

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
person's email nor their name. Each sign-in starts with a fresh nonce: 32
random bytes from the system, written as 64 letters. The Apple request
carries its SHA-256, as lowercase hex, and Apple puts that in the identity
token it gives back. The sign-in hop then carries exactly three values, and
nothing else:

- `appleToken`: Apple's identity token, its bytes written as letters, two
  letters from `a` to `p` for each byte, high half first.
- `nonce`: the nonce itself, sent once, for that one sign-in.
- `deviceKey`: a random key made on the device, kept in the Keychain for
  this device only. It is never synced and never restored to another device
  from a backup.

All three are letters only, so the check that hides personal details can
never mistake one for a phone number or a card number and refuse the
sign-in.

The token and the nonce live only in memory, for that one hop. Building the
preview takes them for the hop, so after that nothing in the app holds them,
whatever happens next: sent, refused, or not sent. Apple's sign-in ending
without a token, switching the cloud off and Forget everything drop them
too. They are never written to the Keychain, a file, UserDefaults or the
log. The cloud code logs only fixed words, through one logger that takes
nothing made at run time (`CloudLog`).

The hop is shown in the same preview as the message, above it, with its
values covered, and only the person's yes sends it. Its answer is
`{"session": "..."}`, a session made only of letters, at least 16 of them.
The app keeps it in memory only, and sends it on later messages as the
`Cloud-Session` header, which the preview shows, covered. Any other answer
is dropped, and the next message needs a new Apple sign-in.

The app says:

- "Signing in sends just three things: a sign-in token from Apple, a one-time code I made for it, and a random key I made for signing in. Never your email or your name."
- Over the sign-in in the preview: "To sign in, this carries an Apple sign-in token, used once, with a one-time code and the key I made. Never your email or your name."

## What the server checks, and what it keeps

The server checks the token once, when the hop arrives:

- Apple's signature, with Apple's public keys.
- `iss` is Apple.
- `aud` is the app's bundle ID.
- `exp` hasn't passed.
- `nonce` in the token equals the SHA-256 of the `nonce` sent, and that
  nonce was never used before.

If any check fails, the sign-in is refused. Either way the server then
throws the token away: nothing logs it or stores it. It keeps only Apple's
anonymous user ID for the person with this app (`sub`) and the device key.

The app says:

- "MDx checks Apple's token once and then throws it away. It keeps only the anonymous ID Apple gives this app for you, and that key."

## What it never sends

- The person's email or name, from Apple or anywhere else.
- Notes. Names from the notes, emails, phone numbers, addresses, card
  numbers and the private words are taken out of every message first.
- Anything from a chat in which the person said they might be in danger.
- Anything at all while the cloud is off, or before the person says yes to
  the preview.

## Forget everything and switching the cloud off

Both end every open cloud chat, then remove the device key from the
Keychain and drop the session and any token or nonce still held, so the
next sign-in starts fresh with a new key. What was already sent can't be
erased from the device. The service never kept a message; the ID and key it
kept for sign-in stay with it.

The app says:

- "Turning this off or using Forget everything erases my copy of that key, so I sign in fresh next time with a new one."

## Which builds may reach it

`Config/Cloud.xcconfig` declares `PEBBLE_CLOUD_POLICY = mdx-zero-retention-2`
and keeps the address empty. A real address goes only in the git-ignored
`Config/Cloud.local.xcconfig`. A build that could ship (anything but a
Debug build that isn't an archive) with an address fails unless
`PEBBLE_CLOUD_POLICY` equals `CloudPolicy.currentVersion` and the address is
plain https (`scripts/release-endpoint-check.sh`). The app itself reads the
address in such a build only when its Info.plist names that same policy
(`CloudEndpoint`), so it always shows the words of the service it reaches.

Any change to what the service does, or to the words above, gets a new
policy version in `CloudPolicy`, `Config/Cloud.xcconfig` and this page,
together. A build whose settings still name an older version, such as
`mdx-zero-retention-1`, fails and says the cloud policy changed.

## For the owner: before the first real sign-in

These need the Apple developer account, so the code stops short of them:

1. Turn on the Sign in with Apple capability for the app's App ID.
2. Add the `com.apple.developer.applesignin` entitlement (value `Default`)
   to the app, with signing set up for the team.
3. On the Mac, sign the app with a team, so it can use the data protection
   Keychain the device key is kept in.
4. Wire a Sign in with Apple button into the turn on question: build the
   request with `AppleCloudAuth.appleIDRequest()`, pass the credential to
   `AppleCloudAuth.accept(_:)`, and call `appleSignInEnded()` when Apple's
   sign-in is cancelled or fails. Until then the app has no token, and no
   sign-in hop is made. A token expires, so ask Apple again when the next
   message needs one.
5. Have the server do what this page says: decode `appleToken` from its
   letters, check Apple's signature with Apple's public keys, `iss`, `aud`
   equal to the app's bundle ID, `exp`, and that `nonce` in the token is the
   SHA-256 of the `nonce` sent and was never used before; keep only `sub`
   and `deviceKey`; never log or store the token; answer with a
   letters-only session, and keep nothing else but the counts.
6. Put the address in `Config/Cloud.local.xcconfig` on the build machine.
