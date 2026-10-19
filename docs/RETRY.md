# Retry and resume

How a task's steps keep going when something goes wrong: a connection that
drops, a far side that says "busy, come back later", a step that hangs, the
app closing halfway, or a question only the person can answer. The kit lives
in PebbleCore, in `RetryKit.swift` and `CheckpointRunner.swift`. It is pure
logic with no networking and nothing on screen. The task engine doesn't use
it yet; it is built so a step runner can plug it in later without changing
the engine.

## The pieces

- **A step** (`RunStep`) has a name, a limit and a body. The body gets a
  `StepAttempt` and either finishes, asks the person something, or throws a
  `StepFailure`.
- **The limit.** Each try of a step has a time limit. A try past it ends as
  timed out and is let go. The run moves on even if the step never stops by
  itself, so a step can never hang its run.
- **What a failure means.** A drop, a time out, "too many requests" (429) and
  trouble on the far side (5xx) are transient: worth another try. Refused, a
  bad request and not allowed are not, and end the run on the first try. So
  does anything a step throws that isn't a `StepFailure`.
  `StepFailure.status(_:retryAfter:)` reads an HTTP status.
- **Waiting between tries** (`BackoffPolicy`). The wait doubles from one
  second up to a cap, and a random point in the upper half of it is picked,
  so many runs that failed together don't all come back at once. When the
  far side sends Retry-After, as seconds or as an HTTP date, that wait is
  used instead, up to its own cap. Each step gets a fixed number of tries
  at most, the first one included.
- **The key** (`IdempotencyKey`). Every try of a step carries one key, made
  from the task and the step's place in it, never from the time. It is the
  same on every try and after the run is picked up again, so a far side
  that sees one request twice can tell it is the same request and do it
  once.
- **The checkpoint.** After each finished step the runner keeps how far it
  got, through a `CheckpointStoring`. A run picked up again, by a new runner
  after the app closed or with the person's answer, starts at the first step
  that isn't finished and never does a finished one again. If a checkpoint
  can't be kept the run stops there, rather than run ahead of what it could
  pick up.
- **A question for the person.** A step that needs the person returns
  `needsYou(question:)`. The run keeps the question and stops. Run without an
  answer it stays waiting and runs nothing. Run with the answer, that step
  is tried again with the answer in its attempt.

## Every run ends one way

`run()` always returns exactly one `RunOutcome`:

- `done`: every step finished.
- `failed(step:reason:)`: a step failed for good. It is kept, so running the
  task again only says so. When how the run ended can't be kept, as while
  the device is locked, the run ends `failed` with `notSaved` instead, and
  the runner holds the end. Run again, it keeps that end before anything
  else and then tells it, so a step that ended the run never runs again.
  A held end lives only in that runner's memory, so one task has one
  runner, and a new runner made after the app closes won't know of it.
- `failed` with `unreadable`: the kept checkpoint can't be understood, as
  one written by another version, or it says a place the run can't have
  reached, before the first step or past the last. Nothing runs and
  nothing is written over it until it is forgotten.
- `stopped(step:)`: the run was cancelled. Running it again picks up there.
- `waiting(step:question:)`: a step is waiting on the person.

Nothing ends silently.

## Where checkpoints are kept

Every change to the checkpoints, a save or a remove, is one `update`: the
store reads them, makes the change and writes them back without letting
go in between, so two runners keeping their places at once never lose
each other's.

`InMemoryCheckpointStore` is for tests. `CheckpointFileStore` keeps them in
one file beside the kept tasks, written the way `TaskStore` writes its file:
whole, through a staged copy that is renamed into place, readable only while
the device is unlocked, and left out of backups. A file that is there but
can't be read yet is never written over. Every `CheckpointFileStore` for
one file in the process shares one lock, found by the file's real path, so
two stores made for it, as `onDevice()` makes a new one each time, never
lose each other's changes either. Nothing makes that file yet; when
the kit is wired in, Forget everything has to clear it too.

### A record that can't be understood

The file holds one record for each task, and each is read on its own. A
record that can't be understood, as one a later version wrote or one
damaged on disk, makes only its own task unreadable: that task runs
nothing and says `unreadable`, and every other task keeps its place and
how it ended. Nothing ever deletes the file or writes over that record
because it can't be read. A change for another task writes the record
back byte for byte, and a save for the task itself is refused.

There are two ways past it. A person, or the app for them, forgets the
task (`CheckpointRunner.forget()`), which lets go of that task's record
alone; run again, the task starts from its first step, each step still
carrying its own key. Or a later version that understands the record
reads it as it was, since nothing in it was lost. A file that isn't a
set of records at all leaves every task unreadable and can't be changed
one task at a time; only clearing the whole file, as Forget everything
will, gets past that.

## Time in tests

All time comes from an injected `RunClock` and `RunSleeper`. The tests use a
clock that only moves when a wait moves it, and waits that end at once, so
the fault tests in `RetryResumeTests` run in milliseconds and the same way
every time. `make mutation-check` breaks each rule on its own (the
checkpoint save, Retry-After, the transient check, the most tries, the key,
where a run picks up, a save or remove in two goes, an end that couldn't
be kept, a lock for each store rather than each file, a kept place
outside the steps, a file deleted or read all or nothing when a record
can't be understood, and such a record dropped or written over) and
requires those tests to fail.
