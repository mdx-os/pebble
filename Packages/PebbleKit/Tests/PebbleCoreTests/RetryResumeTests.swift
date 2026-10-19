import Foundation
import PebbleCore
import SourceScan
import Testing
import TestScratch

/// The retry and resume kit (docs/RETRY.md), run against faults: a drop
/// mid step, a 429 with Retry-After, the app closing mid task, a question
/// for the person, a step that hangs, a failure that isn't worth trying
/// again, and tries running out. Time is a test clock and every wait ends
/// at once, so nothing here waits on the real clock.
@Suite(.timeLimit(.minutes(1)))
struct RetryResumeTests {
    // MARK: Backoff

    @Test func theWaitDoublesUpToItsCapWithJitterInTheUpperHalf() {
        let policy = BackoffPolicy(maxTries: 10, baseDelay: 1, maxDelay: 8)
        let now = Date(timeIntervalSince1970: 0)
        let low = (1...6).map { policy.delay(afterTry: $0, failure: .dropped, now: now, random: 0) }
        let high = (1...6).map { policy.delay(afterTry: $0, failure: .dropped, now: now, random: 1) }
        #expect(low == [0.5, 1, 2, 4, 4, 4])
        #expect(high == [1, 2, 4, 8, 8, 8])
        #expect(policy.delay(afterTry: 3, failure: .dropped, now: now, random: 0.5) == 3)
        #expect(policy.delay(afterTry: 1000, failure: .dropped, now: now, random: 1) == 8)
    }

    @Test func retryAfterIsReadAsSecondsOrAnHTTPDate() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2015-10-21T07:27:00Z"))
        #expect(RetryAfter.seconds("120", now: now) == 120)
        #expect(RetryAfter.seconds(" 0 ", now: now) == 0)
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 60)
        #expect(RetryAfter.seconds("Wednesday, 21-Oct-15 07:29:00 GMT", now: now) == 120)
        #expect(RetryAfter.seconds("Wed Oct 21 07:30:00 2015", now: now) == 180)
        #expect(RetryAfter.seconds("Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0, "a date gone by waits for nothing")
        #expect(RetryAfter.seconds("-5", now: now) == nil)
        #expect(RetryAfter.seconds("soon", now: now) == nil)
        #expect(RetryAfter.seconds("", now: now) == nil)
    }

    @Test func retryAfterIsHonouredButCapped() {
        let policy = BackoffPolicy(maxRetryAfter: 300)
        let now = Date(timeIntervalSince1970: 0)
        #expect(policy.delay(afterTry: 1, failure: .busy(retryAfter: "30"), now: now, random: 0) == 30)
        #expect(policy.delay(afterTry: 1, failure: .busy(retryAfter: "99999"), now: now, random: 0) == 300)
        #expect(policy.delay(afterTry: 1, failure: .serverTrouble(retryAfter: "7"), now: now, random: 0) == 7)
        // A value that can't be read falls back to the doubling.
        #expect(policy.delay(afterTry: 1, failure: .busy(retryAfter: "later"), now: now, random: 0) == 0.5)
    }

    @Test func onlyTransientFailuresAreTriedAgain() {
        #expect(StepFailure.dropped.isTransient)
        #expect(StepFailure.timedOut.isTransient)
        #expect(StepFailure.busy(retryAfter: nil).isTransient)
        #expect(StepFailure.serverTrouble(retryAfter: nil).isTransient)
        for failure: StepFailure in [.refused, .badRequest, .notAllowed, .unexpected, .notSaved] {
            #expect(!failure.isTransient, "\(failure)")
        }
        #expect(StepFailure.status(200) == nil)
        #expect(StepFailure.status(429, retryAfter: "5") == .busy(retryAfter: "5"))
        #expect(StepFailure.status(503, retryAfter: "5") == .serverTrouble(retryAfter: "5"))
        #expect(StepFailure.status(400) == .badRequest)
        #expect(StepFailure.status(403) == .notAllowed)
        #expect(StepFailure.status(409) == .refused)
        #expect(StepFailure.status(408) == .timedOut)
    }

    // MARK: Keys

    @Test func aKeyComesFromTheTaskAndTheStepAlone() {
        #expect(IdempotencyKey(taskID: "trip", step: 2) == IdempotencyKey(taskID: "trip", step: 2))
        #expect(IdempotencyKey(taskID: "trip", step: 2) != IdempotencyKey(taskID: "trip", step: 3))
        #expect(IdempotencyKey(taskID: "trip", step: 2) != IdempotencyKey(taskID: "plan", step: 2))
    }

    // MARK: Faults

    /// A drop mid step: the far side may have it or not. Tried again with
    /// the same key, it lands once.
    @Test func aDropMidStepIsTriedAgainWithTheSameKey() async {
        let world = World()
        let far = FarSide()
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("send") { attempt in
                tries.add(attempt)
                far.send(attempt.key)
                if attempt.tryNumber == 1 { throw StepFailure.dropped }
                return .done
            },
        ])
        #expect(await runner.run() == .done)
        #expect(tries.keys(step: 0).count == 2)
        #expect(Set(tries.keys(step: 0)).count == 1, "every try of a step carries one key")
        #expect(far.applied == [IdempotencyKey(taskID: "task", step: 0): 1])
        #expect(far.repeats == 1)
        #expect(world.sleeper.backoffs == [0.75])
    }

    @Test func a429WaitsAsLongAsRetryAfterSays() async throws {
        let world = World()
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("ask") { attempt in
                tries.add(attempt)
                switch attempt.tryNumber {
                case 1: throw StepFailure.status(429, retryAfter: "30") ?? .unexpected
                case 2: throw StepFailure.status(429, retryAfter: "Thu, 01 Jan 1970 00:02:00 GMT") ?? .unexpected
                default: return .done
                }
            },
        ])
        #expect(await runner.run() == .done)
        // 30 seconds, then the date, 120 seconds after the start, read on
        // the test clock that the first wait moved on to 30.
        #expect(world.sleeper.backoffs == [30, 90])
        #expect(tries.keys(step: 0).count == 3)
    }

    /// The app closes mid task: the runner goes, and a new one is made
    /// from the saved checkpoint. Finished steps never run again, and the
    /// step that was cut short is sent again with its own key.
    @Test func closingMidTaskThenPickingUpRepeatsNothing() async throws {
        let store = InMemoryCheckpointStore()
        let far = FarSide()
        let tries = Tries()
        let (reached, signal) = AsyncStream<Void>.makeStream()
        let close = Flag(true)
        func steps() -> [RunStep] {
            (0..<4).map { index in
                RunStep("step \(index)") { attempt in
                    tries.add(attempt)
                    far.send(attempt.key)
                    if index == 2, close.take() {
                        signal.yield()
                        try await Hang.untilCancelled()
                    }
                    return .done
                }
            }
        }
        let first = World(store: store).runner(steps: steps())
        let running = Task { await first.run() }
        for await _ in reached { break }
        running.cancel()
        #expect(await running.value == .stopped(step: 2))
        #expect(store.checkpoints["task"]?.finished == 2)

        let second = World(store: store).runner(steps: steps())
        #expect(await second.run() == .done)
        #expect(tries.count(step: 0) == 1)
        #expect(tries.count(step: 1) == 1)
        #expect(tries.count(step: 2) == 2)
        #expect(tries.count(step: 3) == 1)
        #expect(Set(tries.keys(step: 2)).count == 1, "the step cut short is sent again with the same key")
        #expect(far.applied.count == 4)
        #expect(far.applied.values.allSatisfy { $0 == 1 }, "\(far.applied)")
        #expect(far.repeats == 1)
        // Run again once done, it only says so.
        #expect(await World(store: store).runner(steps: steps()).run() == .done)
        #expect(tries.total == 5)
    }

    @Test func aQuestionForThePersonKeepsItsPlaceAndGoesOnWithTheAnswer() async {
        let store = InMemoryCheckpointStore()
        let tries = Tries()
        let answers = GivenAnswers()
        let steps = [
            RunStep("look") { attempt in tries.add(attempt); return .done },
            RunStep("ask") { attempt in
                tries.add(attempt)
                guard let answer = attempt.answer else { return .needsYou(question: "Which day works?") }
                answers.add(answer)
                return .done
            },
            RunStep("book") { attempt in
                tries.add(attempt)
                return attempt.answer == nil ? .done : .needsYou(question: "The answer went too far")
            },
        ]
        #expect(await World(store: store).runner(steps: steps).run() == .waiting(step: 1, question: "Which day works?"))
        #expect(store.checkpoints["task"]?.question == "Which day works?")
        // Picked up without an answer, it is still waiting and runs nothing.
        #expect(await World(store: store).runner(steps: steps).run() == .waiting(step: 1, question: "Which day works?"))
        #expect(tries.total == 2)

        #expect(await World(store: store).runner(steps: steps).run(answer: "Tuesday") == .done)
        #expect(answers.all == ["Tuesday"])
        #expect(tries.count(step: 0) == 1)
        #expect(tries.count(step: 1) == 2)
        #expect(tries.count(step: 2) == 1)
        #expect(Set(tries.keys(step: 1)).count == 1)
    }

    @Test func aStepPastItsLimitEndsAsTimedOutAndIsTriedAgain() async {
        let world = World(limitsThatEnd: 1)
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("slow", limit: 5) { attempt in
                tries.add(attempt)
                if attempt.tryNumber == 1 {
                    world.sleeper.started()
                    try await Hang.untilCancelled()
                }
                return .done
            },
        ])
        #expect(await runner.run() == .done)
        // The second try's limit may be let go before it even starts.
        #expect(world.sleeper.limits.first == 5)
        #expect(tries.count(step: 0) == 2)
        #expect(Set(tries.keys(step: 0)).count == 1)
    }

    @Test func aStepThatAlwaysHangsEndsTheRunAsTimedOut() async {
        let world = World(policy: BackoffPolicy(maxTries: 2), limitsThatEnd: .max)
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("stuck", limit: 5) { attempt in
                tries.add(attempt)
                world.sleeper.started()
                // Never stops, even when let go: the run still ends.
                await Hang.ignoringCancel()
                return .done
            },
        ])
        #expect(await runner.run() == .failed(step: 0, reason: .timedOut))
        #expect(tries.count(step: 0) == 2)
    }

    @Test func aFailureThatIsNotTransientIsNeverTriedAgain() async {
        for failure: StepFailure in [.refused, .badRequest, .notAllowed] {
            let world = World()
            let tries = Tries()
            let runner = world.runner(steps: [
                RunStep("send") { attempt in tries.add(attempt); throw failure },
                RunStep("after") { attempt in tries.add(attempt); return .done },
            ])
            #expect(await runner.run() == .failed(step: 0, reason: failure))
            #expect(tries.total == 1, "\(failure)")
            #expect(world.sleeper.backoffs.isEmpty)
            #expect(world.store.checkpoints["task"]?.ended == .failed(step: 0, reason: failure))
        }
    }

    @Test func anErrorThatIsNotAStepFailureEndsTheRunWithoutATryAgain() async {
        struct Odd: Error {}
        let world = World()
        let tries = Tries()
        let runner = world.runner(steps: [RunStep("odd") { attempt in tries.add(attempt); throw Odd() }])
        #expect(await runner.run() == .failed(step: 0, reason: .unexpected))
        #expect(tries.total == 1)
    }

    @Test func triesRunOutAfterTheMaximum() async {
        let world = World(policy: BackoffPolicy(maxTries: 3, baseDelay: 1, maxDelay: 60))
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("send") { attempt in tries.add(attempt); throw StepFailure.dropped },
            RunStep("after") { attempt in tries.add(attempt); return .done },
        ])
        #expect(await runner.run() == .failed(step: 0, reason: .dropped))
        #expect(tries.count(step: 0) == 3)
        #expect(tries.count(step: 1) == 0)
        #expect(world.sleeper.backoffs == [0.75, 1.5])
        // A failed run stays failed: run again, it tries nothing.
        #expect(await runner.run() == .failed(step: 0, reason: .dropped))
        #expect(tries.total == 3)
    }

    @Test func aRunThatCannotKeepItsPlaceStopsThere() async {
        let world = World()
        let tries = Tries()
        let runner = world.runner(steps: [
            RunStep("one") { attempt in tries.add(attempt); world.store.locked = true; return .done },
            RunStep("two") { attempt in tries.add(attempt); return .done },
        ])
        #expect(await runner.run() == .failed(step: 0, reason: .notSaved))
        #expect(tries.total == 1)
        #expect(await runner.run() == .failed(step: 0, reason: .notSaved), "still locked, so nothing runs")
        #expect(tries.total == 1)
    }

    @Test func stoppingWhileWaitingToTryAgainEndsStopped() async {
        let world = World(backoffsHang: true)
        let (reached, signal) = AsyncStream<Void>.makeStream()
        let runner = world.runner(steps: [
            RunStep("send") { _ in signal.yield(); throw StepFailure.dropped },
        ])
        let running = Task { await runner.run() }
        for await _ in reached { break }
        running.cancel()
        #expect(await running.value == .stopped(step: 0))
        #expect(world.store.checkpoints["task"]?.ended == nil, "a stopped run picks up again")
    }

    // MARK: The file

    @Test(.scratchFiles) func aCheckpointOnDiskIsPickedUpByANewStore() async throws {
        let base = try #require(Scratch.folder)
        let file = CheckpointFileStore.location(base: base)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tries = Tries()
        let steps = (0..<3).map { index in
            RunStep("step \(index)") { attempt in
                tries.add(attempt)
                return index == 1 && attempt.answer == nil ? .needsYou(question: "Which one?") : .done
            }
        }
        let first = World(store: CheckpointFileStore(fileURL: file)).runner(steps: steps)
        #expect(await first.run() == .waiting(step: 1, question: "Which one?"))
        let reopened = CheckpointFileStore(fileURL: file)
        #expect(reopened.read()?["task"]?.finished == 1)
        #expect(await World(store: reopened).runner(steps: steps).run(answer: "The blue one") == .done)
        #expect(tries.count(step: 0) == 1)
        #expect(CheckpointFileStore(fileURL: file).read()?["task"]?.ended == .done)
        #expect(World(store: reopened).runner(steps: steps).forget())
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing kept, no file")
    }

    @Test(.scratchFiles) func aFileNoOneCanUnderstandGoes() throws {
        let base = try #require(Scratch.folder)
        let file = CheckpointFileStore.location(base: base)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a checkpoint".utf8).write(to: file)
        #expect(CheckpointFileStore(fileURL: file).read() == [:])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// PERMANENT GUARD. Written as the kept tasks are: whole, through a
    /// staged copy, and protected until the device is first unlocked.
    @Test func theCheckpointFileIsProtectedLikeTheTasks() throws {
        let mask = Data.WritingOptions.fileProtectionMask
        #expect(CheckpointFileStore.fileWriting(protected: true) == TaskStore.fileWriting(protected: true))
        #expect(CheckpointFileStore.fileWriting(protected: true).intersection(mask)
            == .completeFileProtectionUntilFirstUserAuthentication)
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent(
            "Packages/PebbleKit/Sources/PebbleCore/CheckpointRunner.swift"), encoding: .utf8)
        let writes = SwiftSource(text).calls(named: ["write"]).filter { $0.arguments.hasPrefix("to:") }
        #expect(writes.count == 1, "\(writes.map(\.arguments))")
        #expect(writes.allSatisfy { $0.arguments.contains("Self.fileWriting()") })
    }
}

// MARK: Test pieces

/// A clock that moves only when a wait moves it.
private final class RunTestClock: RunClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)

    var now: Date { lock.lock(); defer { lock.unlock() }; return time }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); time += seconds; lock.unlock()
    }
}

/// Every wait between tries ends at once and moves the clock on. A step's
/// limit ends at once for the first `limitsThatEnd` steps tried, and after
/// that never ends on its own, only when the step finishes first.
private final class TestSleeper: RunSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: RunTestClock
    private var limitsLeft: Int
    private let backoffsHang: Bool
    private var backoffWaits: [TimeInterval] = []
    private var limitWaits: [TimeInterval] = []

    init(clock: RunTestClock, limitsThatEnd: Int, backoffsHang: Bool) {
        self.clock = clock
        limitsLeft = limitsThatEnd
        self.backoffsHang = backoffsHang
    }

    var backoffs: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return backoffWaits }
    var limits: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return limitWaits }

    /// Steps that hang say so once they are under way, and a limit that
    /// ends at once waits for that, so it never ends a try not yet begun.
    private let starts = Starts()

    func started() { starts.add() }

    func sleep(_ seconds: TimeInterval, for wait: RunWait) async throws {
        let ends = note(seconds, for: wait)
        guard ends else { return try await Hang.untilCancelled() }
        if wait == .limit { try await starts.take() }
        clock.advance(seconds)
    }

    /// Writes the wait down. True when it ends at once.
    private func note(_ seconds: TimeInterval, for wait: RunWait) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch wait {
        case .backoff:
            backoffWaits.append(seconds)
            return !backoffsHang
        case .limit:
            limitWaits.append(seconds)
            guard limitsLeft > 0 else { return false }
            limitsLeft -= 1
            return true
        }
    }
}

/// Tokens, one for each step under way, taken by waits for them.
private final class Starts: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = 0
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func add() {
        lock.lock()
        if let (id, next) = waiting.first {
            waiting[id] = nil
            lock.unlock()
            next.resume()
            return
        }
        tokens += 1
        lock.unlock()
    }

    func take() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    next.resume(throwing: CancellationError())
                } else if tokens > 0 {
                    tokens -= 1
                    lock.unlock()
                    next.resume()
                } else {
                    waiting[id] = next
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let next = waiting.removeValue(forKey: id)
            lock.unlock()
            next?.resume(throwing: CancellationError())
        }
    }
}

/// A runner's surroundings for one test.
private struct World {
    let store: InMemoryCheckpointStore
    let fileStore: (any CheckpointStoring)?
    let clock = RunTestClock()
    let sleeper: TestSleeper
    let policy: BackoffPolicy

    init(store: InMemoryCheckpointStore = InMemoryCheckpointStore(), policy: BackoffPolicy = .standard,
         limitsThatEnd: Int = 0, backoffsHang: Bool = false) {
        self.store = store
        fileStore = nil
        self.policy = policy
        sleeper = TestSleeper(clock: clock, limitsThatEnd: limitsThatEnd, backoffsHang: backoffsHang)
    }

    init(store: any CheckpointStoring) {
        self.store = InMemoryCheckpointStore()
        fileStore = store
        policy = .standard
        sleeper = TestSleeper(clock: clock, limitsThatEnd: 0, backoffsHang: false)
    }

    func runner(steps: [RunStep]) -> CheckpointRunner {
        CheckpointRunner(taskID: "task", steps: steps, store: fileStore ?? store, policy: policy,
                         clock: clock, sleeper: sleeper, random: { 0.5 })
    }
}

/// The far side of a step: does what each new key asks once, and counts
/// a key it has seen as a repeat.
private final class FarSide: @unchecked Sendable {
    private let lock = NSLock()
    private var done: [IdempotencyKey: Int] = [:]
    private var repeated = 0

    func send(_ key: IdempotencyKey) {
        lock.lock(); defer { lock.unlock() }
        if done[key] == nil { done[key] = 1 } else { repeated += 1 }
    }

    var applied: [IdempotencyKey: Int] { lock.lock(); defer { lock.unlock() }; return done }
    var repeats: Int { lock.lock(); defer { lock.unlock() }; return repeated }
}

/// Every try of every step, in order.
private final class Tries: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [StepAttempt] = []

    func add(_ attempt: StepAttempt) {
        lock.lock(); all.append(attempt); lock.unlock()
    }

    var total: Int { lock.lock(); defer { lock.unlock() }; return all.count }

    func count(step: Int) -> Int { keys(step: step).count }

    func keys(step: Int) -> [IdempotencyKey] {
        lock.lock(); defer { lock.unlock() }
        return all.filter { $0.step == step }.map(\.key)
    }
}

private final class GivenAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    func add(_ answer: String) {
        lock.lock(); kept.append(answer); lock.unlock()
    }

    var all: [String] { lock.lock(); defer { lock.unlock() }; return kept }
}

/// True until taken once.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = value
        value = false
        return was
    }
}

/// Waits that end only on cancellation, or not at all, with no clock.
private enum Hang {
    static func untilCancelled() async throws {
        let gate = Gate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { gate.wait($0) }
        } onCancel: {
            gate.open()
        }
    }

    /// Never ends while the test runs. It holds no thread, and the run it
    /// is part of ends without it.
    static func ignoringCancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Parked.keep(continuation)
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var opened = false

        func wait(_ next: CheckedContinuation<Void, any Error>) {
            lock.lock()
            if opened {
                lock.unlock()
                next.resume(throwing: CancellationError())
                return
            }
            continuation = next
            lock.unlock()
        }

        func open() {
            lock.lock()
            opened = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Holds continuations that are never resumed, so none is reported as
    /// leaked while the test process runs.
    private enum Parked {
        nonisolated(unsafe) private static var kept: [CheckedContinuation<Void, Never>] = []
        private static let lock = NSLock()

        static func keep(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock(); kept.append(continuation); lock.unlock()
        }
    }
}
