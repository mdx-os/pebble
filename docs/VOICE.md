# Voice

How the agent talks, everywhere: the first run, the chat, memory, and the
questions it asks before it acts. Read this before writing any words a
person will see. The words themselves live in `PebbleCore` (`FirstRunWords`,
`FirstConversation`, `MemoryWords`, `ConfirmationWords`, `FeedWords`, `TaskWords` and friends), so a
change here usually means a change there.

## Who the agent is

A calm, kind companion that lives on the person's own device. It is glad to
help, it is honest about what it can't do yet, and it never pretends to be a
person. It can do serious work, but it never makes the person feel like they
are operating a machine.

The person names it. In copy, the agent speaks as "I" and calls the person
"you". It never says the product name in a sentence; code reads that from
`Brand`.

## Tone rules

1. **Warm, then useful.** One kind beat, then the point. Never more than one.
2. **Plain words.** Write the way you would say it to a friend across a
   table. No system words.
3. **Short.** One idea per sentence. Most lines fit in two short sentences.
4. **Calm.** No exclamation marks in errors or questions. At most one in a
   whole screen, and only for real good news.
5. **Honest.** Say what happened and what happens next. Never promise more
   than the code does.
6. **The person decides.** Offer, don't push. "Want to...?" beats "You
   should...".
7. **No dashes.** No em dashes and no en dashes, anywhere a person reads.
   Use a full stop, a comma, or "and". `CopyDashTests` checks this.

## Words to use and avoid

| Use | Avoid |
| --- | --- |
| remember, keep, forget, erase | store, persist, delete record, purge |
| this device | local storage, sandbox, client |
| note | entry, item, object |
| a moment, just now | latency, timeout (in copy), request |
| couldn't | failed, error, invalid, exception |
| try again | retry, resubmit |
| ask you first | require authorization, permission prompt |
| I'm not sure | unknown, null, N/A |
| Sorry | We apologize for the inconvenience |

## How to say no

Say no kindly, say why in a few words, and offer what you can do instead.

- Good: "I can't buy things on my own. I'll always ask you first, and you
  decide."
- Bad: "Action not permitted."

## How to say sorry

One "Sorry", once, then what happens now. Don't grovel and don't blame the
person.

- Good: "Sorry, I couldn't finish a reply just now. What you wrote is still
  here, so you can send it again."
- Bad: "Oops!! Something went wrong. Error 500."

## How to talk about privacy

Privacy promises are facts, not decoration. State them simply and only
when the code makes them true.

- Say "stays on this device", "kept only on this device" or "on this
  device" only when the flag says so. The flag is `PrivacyPlace`, read
  from the active model's `runsOnDevice` through `ModelClient.privacyPlace`
  and passed down by the app. There is no second flag. Every device line
  takes it: `FirstConversation.opening` and `presence`,
  `FirstRunWords.helloDetail`, `MemoryWords.empty`, `saved` and
  `privacyNote`, and `FeedWords.sampleNote`. Memory lines follow it too: notes never reach a model,
  but with a cloud model the chat does leave the device, so a promise on
  the memory screen would mislead. `PrivacyPlaceTests` pins every line.
- When the flag is off, say nothing about the device. Drop the sentence
  rather than replace it with a claim about the cloud.
- Never soften a promise that is true ("mostly private") and never stretch
  one that is not ("totally secure").
- Say only what the agent knows. After a note is forgotten, "Gone. I no
  longer have it." is true because the file is rewritten without the note.
  Don't claim more about the device's storage than the code can check.
- A promise about what happens next must have a button or a behavior
  behind it. "I'll look again" needs a Try again or a re-check.

## When someone may be in danger

The care replies in `CareCheck` are safety copy, not voice copy. Do not
rewrite them for tone. Any change to them needs its own pull request and
its own review.

## Asking before acting

Before the agent sends, buys or shares anything, it asks. The question
names exactly what will happen, to whom, and for how much. The buttons say
what they do ("Yes, go ahead" and "Not now", from `ProposedAction.yesTitle`
and `noTitle`; `CopyDashTests` checks they match), and the promise underneath
says the yes counts once, for exactly what is shown.

## Patterns

### Errors

Say what happened, then what the agent will do or what the person can do.
Never show a raw error string.

- Good: "I can't open my notes just now, usually because the device is
  locked. Unlock it, and I'll look again."
- Bad: "NSCocoaErrorDomain 257."

### Empty states

Say what will appear here, why it is worth having, and offer one clear
action.

- Good: "Nothing here yet. Tell me something worth keeping, like a
  birthday or how you take your tea. It stays on this device, and you can
  change or remove it anytime." with a button "Add your first note". With
  a model that leaves the device, the device sentence goes: "You can
  change or remove it anytime."
- Bad: "No data."

An empty state promises only what exists today. Today's empty state says
"It's just us for now. Write to me below, and I'll answer in the chat." with
the composer under it. It is true whether or not a chat is already going, so
it never promises a new one, and it says nothing about work done in the
background until a real feed source ships.

Examples are always labeled. Sample cards start with "Example" for
VoiceOver, and a sample opened to read or a sample question says "This is
an example. Nothing here was really done."

### Readable words

Words a person reads clear 4.5 to 1 against what they sit on, in light and
dark. Use `Theme.accentText` for words in the accent's warmth,
`Theme.secondaryText` for quieter words and placeholders, and `Theme.onAccent`
on the accent fill. A system control that fills with the tint and writes
white on it (the selected sidebar row, Done) takes `Theme.tintFill`. The raw
accent and the system grays are too faint for words.
`ContrastGuardTests` checks every pair in `Theme.textPairs` and scans the
screens for colors outside them.

### Waiting

Show a calm presence instead of a spinner. The thinking dots hold still
with Reduce Motion on, and VoiceOver hears "Thinking it over." once.

### Long work

A task card says what the agent is doing now, in plain words, not what
the machine is doing. When a step is slow, say so and say what happens
next: "That page was slow, so I'm trying another way." Only after a few
tries does the card ask the person, and then it offers Try again. Stop
says what was kept and what was not done. VoiceOver hears each new step
once, politely, never every tick of progress. Never say a change was
taken and then ask about the old thing: a step that can't change is left
undone, and the card says so ("You changed course, so I didn't hold a
Saturday visit."). A closed question says "You closed the question", which
is true for Not now and a sheet swiped away alike. A step the person said
yes to may already be under way, so never say it wasn't done: a change of
course lets it finish ("You'd already said yes to this, so I'm finishing
it."), and a stop says it may be done. A yes that didn't go through says
so on the card, so a tap is never met with silence, and so does an
Approve tapped after its question timed out. Forget everything says it
stops tasks still going. If a step said yes to was under way, a short line
stays on Today to say it may be done, naming nothing the task held. A
scripted task's card says "Example", like every other example.

### Confirmations

Short and specific. "Saved. It stays on this device." beats "Success!".
With a model that leaves the device it is just "Saved."

## Short examples

| Moment | Good | Bad |
| --- | --- | --- |
| First hello | "Hi there. I'm glad you're here." | "Welcome to the app." |
| Naming | "Type a name first. Any name works." | "Name is required." |
| Too long | "That's a little long. Try a name of N letters or fewer." (N is `AgentName.maxLength`) | "Max length exceeded." |
| Memory saved, model on device | "Saved. It stays on this device." | "Note created." |
| Memory saved, model may leave the device | "Saved." | "Saved. It stays on this device." |
| Memory header, model on device | "Kept only on this device. Removing a note erases it." | "Stored locally." |
| Memory header, model may leave the device | "Removing a note erases it." | "Kept only on this device." |
| Chat presence, model on device | "Here with you, on this device." | "Running locally." |
| Chat presence, model may leave the device | "Here with you." | "Here with you, on this device." |
| Question timed out | "That question timed out, so I didn't do it." | "Request expired." |
