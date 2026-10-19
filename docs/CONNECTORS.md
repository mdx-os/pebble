# Connectors

A connector reads something the person already keeps in another app, so
the agent can help with it. The first one reads the calendar and the
reminders. Connectors live in `Packages/PebbleKit/Sources/PebbleConnectors`,
a layer of their own.

## What a connector promises

- **Read only.** It never adds, changes or removes anything.
- **It never asks by itself.** Reading only looks at what the person has
  already allowed. Asking is a separate call, `requestAccess`, made only
  after the person asked for something that needs it, such as "what's on
  my day?". Once they have chosen, it never asks again; a no stays a no
  until they change it in Settings.
- **A closed calendar says so.** When the agent may not read, the answer
  is a reason in plain words (`CalendarBlock.words`), never an empty list.
  An empty list always means there really is nothing there.
- **What it reads stays in memory.** Nothing it reads is kept in a file,
  in the defaults or in a log, and nothing is sent anywhere, the cloud
  model included. The layer imports only Foundation and EventKit and
  depends on none of the package's other layers.

`ConnectorGate` in `Tools/GuardKit` holds every file in the layer to the
last promise: no other import, and no name that opens a connection, keeps
a file or logs. `ConnectorGateTests` also checks that the layer's target
lists no dependencies.

## The calendar

- `CalendarSource` is what the app uses: `access`, `requestAccess`,
  `events(in:)` and `reminders(dueBy:)`. `CalendarConnector` is the one
  implementation, over a `CalendarStore`.
- `EventKitCalendarStore` is the real store. `FakeCalendarStore` stands in
  for tests and examples, and behaves like the system: it hands back
  nothing it isn't allowed to.
- The values are plain: `CalendarEvent` (title, start, end, calendar name,
  all day, place) and `CalendarReminder` (title, due date, whether it has a
  time, list name, done).

## Helpers for Today

- `CalendarClashes.find` gives the timed events that share time in a
  window. All day events never clash, and two events that only touch, one
  ending as the next begins, don't either.
- `MorningCalendarSummary` is what a morning card can show: the first
  event not over yet, how many events the day has, its clashes, and the
  reminders that are overdue. The day runs midnight to midnight in the
  calendar it is given, so a day the clocks change has 23 or 25 hours.

## Before the app can ask

This layer isn't linked into the app yet. Wiring it in needs:

- `PebbleConnectors` added to the app's package products in `project.yml`.
- `NSCalendarsFullAccessUsageDescription` in the app's Info.plist, the
  reason shown when asking to read the calendar.
- `NSRemindersFullAccessUsageDescription`, the same for reminders.
- Once the Mac app runs in the App Sandbox, its calendars entitlement
  (`personal-information.calendars`), which covers reminders too. iPhone
  and iPad need no entitlement for this.

Without the usage strings the system ends the app as it asks.
