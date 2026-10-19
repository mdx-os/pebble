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
  task again only says so.
- `stopped(step:)`: the run was cancelled. Running it again picks up there.
- `waiting(step:question:)`: a step is waiting on the person.

Nothing ends silently.

## Where checkpoints are kept

`InMemoryCheckpointStore` is for tests. `CheckpointFileStore` keeps them in
one file beside the kept tasks, written the way `TaskStore` writes its file:
whole, through a staged copy that is renamed into place, protected until the
device is first unlocked, and left out of backups. A file that is there but
can't be read yet is never written over. Nothing makes that file yet; when
the kit is wired in, Forget everything has to clear it too.

## Time in tests

All time comes from an injected `RunClock` and `RunSleeper`. The tests use a
clock that only moves when a wait moves it, and waits that end at once, so
the fault tests in `RetryResumeTests` run in milliseconds and the same way
every time. `make mutation-check` breaks each rule on its own (the
checkpoint save, Retry-After, the transient check, the most tries, the key,
and where a run picks up) and requires those tests to fail.
