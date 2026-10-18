# Voice

How the agent talks, everywhere: the first run, the chat, memory, and the
questions it asks before it acts. Read this before writing any words a
person will see. The words themselves live in `PebbleCore` (`FirstRunWords`,
`FirstConversation`, `MemoryWords`, `ConfirmationWords`, `FeedWords`, `TaskWords`, `BackgroundWords` and friends), so a
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
  `privacyNote`, `FeedWords.sampleNote` and `CloudWords.offDetail`. Memory lines follow it too: notes never reach a model,
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
- Help from the cloud (`CloudWords`) is off until the person says yes to
  a question that names what changes. Before anything from a chat leaves,
  the person sees "Here is exactly what leaves your device" with the very
  bytes that will be sent. `CloudModel` reports `.mayLeaveDevice`, so a
  chat on the cloud, and every line that reads the flag from it, never
  says "on this device".

## When someone may be in danger

The care replies in `CareCheck` are safety copy, not voice copy. Do not
rewrite them for tone. Any change to them needs its own pull request and
its own review.

## Asking before acting

Before the agent sends, buys or shares anything, it asks. It asks too
before it keeps something new in the person's notes that they didn't type,
such as the weekly digest ("Keep this in What I remember?"). The question
names exactly what will happen, to whom, and for how much. A digest line
ends with where its note came from, in the same words as the note's own
label ("(From Calendar)", "(You told me)"), so nothing is relabelled. The buttons say
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
it never promises a new one. Background work is a real feed source now, and
the line still holds: it shows only while nothing has been made, so it never
hides a card, and it never promises a summary the system may not give time for.

Examples are always labeled. Sample cards start with "Example" for
VoiceOver, and a sample opened to read or a sample question says "This is
an example. Nothing here was really done."

### Readable words

Words a person reads clear 4.5 to 1 against what they sit on, in light and
dark. Use `Theme.accentText` for words in the accent's warmth,
`Theme.secondaryText` for quieter words and placeholders, and `Theme.onAccent`
on the accent fill. A system control that fills with the tint and writes
white on it (the selected sidebar row, Done) takes `Theme.tintFill`, and only
those: it is a fill, never words, and the sidebar's icons in it clear 3 to 1. The raw
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
scripted task's card says "Example", like every other example. A real
task that was going when the app closed comes back stopped and says so
("I stopped when the app closed, so I didn't finish this."), never done.
A digest whose notes change before it is kept stops and says so ("One of
the notes I was tidying changed, so I stopped. Nothing was kept."), since a
yes would be for other words. Forgetting a note never says "Gone" while a
digest the person changed may still hold its words: the line says they are
still there when they are found, and that they may be when they aren't but
could have been reworded. A digest the agent takes out of the notes itself,
because every note it quoted went, says so ("I took the weekly digest out
of your notes, because the notes it quoted are gone or changed."), never
that the person removed it.

### Work while you're away

Background work is off until the person turns it on, from the switch on the
memory screen, and the line under the switch says what it does and when:
"I try to make it overnight if you've unlocked since your last restart, and
otherwise when you open the app." on iPhone and iPad, since the summary's
file opens only after that first unlock, and the system may not give it
time even then. It says "try", never that it will. On the Mac it says
"while the app is open". It
names "what finished overnight" only when there are tasks to count and the
app keeps running, as on the Mac: on iPhone and iPad a summary made while
closed almost never knows what finished. It says
"when there's something to tell you", since a quiet morning leaves no card.
Under it, "I'll look next at 7:00 AM tomorrow." says when it looks, not that
a card comes. It always ends by saying nothing is sent, bought or shared
without asking.

The morning summary only counts what is really there, and says so in the
past tense ("One thing was waiting for you."), since a question may have
timed out by the time it is read. Opened, it says where to look ("at the top
of Today, under Needs you") and from when it counted. A summary made late
says why, once: "I waited until you unlocked, so this came later than
planned." What is waiting is open now, so it is always said when Needs you
can be seen. A count it couldn't know, because nothing could be counted or the
app wasn't running for the whole time, is left out, never said as zero.
What finished is read from where the tasks are kept, so it is known even
after a night with the app closed; when that is locked away with the
screen, the summary says so ("Your tasks stay locked away while your screen
is locked, so I couldn't count what finished.") rather than leave it out. It
says "overnight" only for one night, and "since Tuesday" for longer. With
tasks to count, a morning that never ran gets its own card that names the
day and the reason, and promises nothing about the next one; several missed
in a row share one card that names them all and says only what is true of
each. With no tasks to count, that morning would almost always have been
quiet, so no card claims a summary was missed. None of these lines
mention the device: they are about time and power, not where words go.
The words live in `BackgroundWords`.

Forget everything says what went in plain words, and names only what was
really there: the notes and the tasks only when there were some, and the
words to hide only when they were erased. If the summaries' file couldn't
be erased, it says so and asks to try again. It never says "no trace": once
an earlier version's setting was seen, an empty marker file stays beside the
switch, holding nothing, but its being there shows the switch was once set.

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
