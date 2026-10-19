# Routing

When the person asks for something, the agent decides where the work can
be done. `FallbackRouter` in PebbleCore makes that choice. It is pure: it
reads a `RouteAsk` and a `RouteContext` and gives back one `RouteDecision`,
with no clock, no globals and nothing read or written.

## The order

The router tries each place in this order and stops at the first that can
do the work:

1. What is already on the device: notes, tasks and what the agent remembers.
2. A system framework the app has, such as the calendar, when its
   permission is given, or can be asked for while the person is here.
3. A web page read through the relay. This leaves the device.
4. A longer run elsewhere, for research, many steps or code. This leaves
   the device.
5. Asking the person.

Asking the person is always there, so every ask ends somewhere. A decision
never goes back: routing again after a hop was turned down only tries the
hops after it.

## The rules

- **Leaving needs a yes.** Hops 3 and 4 are marked `leavesDevice`. Each
  one carries the same preview the chat shows, naming exactly where it
  goes and what goes, and the preview shows before anything runs. It goes
  ahead only when a grant covers that exact action and target. Without
  one, the decision is to ask first, with the preview. Nothing is ever
  sent silently.
- **Grants come only from the person.** The router reads the grants it is
  given through `GrantGate` and never makes one. Only the question sheet
  can issue a grant, so nothing a model says can widen what is allowed.
- **Off by default.** While outside help is off, hops 3 and 4 are skipped
  and the decision says so in plain words. It is off until the person
  turns it on, and always off when there is no endpoint, as in a Release
  build without one.
- **Every decision is written down.** `FallbackRouter.record` writes the
  decision to the task's ledger as a step line: the hop, a reason code,
  any framework's name and each hop passed over with its own code. Never
  the person's words.
- **Plain words.** What the person reads about a choice lives in
  `RouteWords` and follows `docs/VOICE.md`. The copy guards check it.

## What comes next

This is the decision only. Later work fills `RouteContext` from real
sources (what is kept, framework permissions, the relay's sign in, the
run allowance) and acts on the decision.
