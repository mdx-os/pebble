import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

/// How many replies are on the model at once, and the most there ever were.
private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var peak = 0
    private var began = 0

    func begin() {
        lock.lock()
        now += 1
        began += 1
        peak = max(peak, now)
        lock.unlock()
    }

    func end() {
        lock.lock()
        now -= 1
        lock.unlock()
    }

    var running: Int {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    var most: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return began
    }

    /// Waits until `count` replies have begun, up to half a minute.
    func waitForStarts(_ count: Int) async {
        for _ in 0..<6000 where started < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Stands in for MLX. Each reply runs for a while, and a stopped one still
/// takes a moment to finish its last work, as the model does, before it
/// counts as ended.
private struct CountingGenerator: OnDeviceGenerating {
    let inFlight: InFlight
    var runs: Duration = .milliseconds(80)
    var settles: TimeInterval = 0.05

    func reply(to transcript: [ChatTurn]) async throws -> String {
        inFlight.begin()
        defer { inFlight.end() }
        let end = ContinuousClock.now + runs
        while ContinuousClock.now < end {
            if Task.isCancelled {
                Self.finishLastWork(settles)
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return transcript.last?.text ?? ""
    }

    /// Blocks, as the model's last work does, without minding the cancel.
    private static func finishLastWork(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func drain() async {}
}

/// What happened on the model, in order.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []

    func add(_ event: String) {
        lock.withLock { all.append(event) }
    }

    var list: [String] {
        lock.withLock { all }
    }

    /// Waits until `event` has happened, up to half a minute.
    func waitFor(_ event: String) async {
        for _ in 0..<6000 where !list.contains(event) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Stands in for MLX reading a long prompt in chunks: a stop throws at
/// once, before the last evaluation, so work sent to the graphics chip is
/// still running when `reply` ends. Only `drain` waits for it.
private struct PrefillGenerator: OnDeviceGenerating {
    let events: Events

    func reply(to transcript: [ChatTurn]) async throws -> String {
        let text = transcript.last?.text ?? ""
        events.add("start \(text)")
        while true {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func drain() async {
        Self.waitForTheChip()
        events.add("drained")
    }

    /// Blocks, as a synchronize does.
    private static func waitForTheChip() {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

/// Parks a load until the test releases it, so a step no longer depends on
/// how long a sleep takes.
private final class LoadHold: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            let waiting = self.waiting
            self.waiting = []
            return waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// Stands in for MLX in its two parts, as `MLXEngine` has them: a load on
/// the processor that parks until it is released and minds no stop, as MLX's
/// evaluation of the weights doesn't, then the reply on the graphics chip.
/// Writes down each step, and whether the app was away when the chip was used.
private struct StepEngine: OnDeviceEngine {
    let events: Events
    let runner: OnDeviceRunner
    let hold: LoadHold

    func preflight(_ directory: URL) throws {}

    func load(_ directory: URL) async throws -> String {
        events.add("load 1")
        await hold.wait()
        events.add("load 2")
        events.add("load 3")
        return "weights"
    }

    func reply(to lines: [OnDeviceTranscriptLine], with loaded: String) async throws -> String {
        events.add(runner.isAway ? "graphics chip while away" : "graphics chip")
        return lines.last?.text ?? ""
    }

    func drain() {
        events.add("drained")
    }
}

struct OnDeviceRunnerTests {
    private let folder = URL(fileURLWithPath: "/tmp/no-such-model", isDirectory: true)

    private func turns(_ text: String) -> [ChatTurn] {
        [ChatTurn(id: UUID(), speaker: .person, text: text)]
    }

    /// Two replies asked for together, as from two windows, never run on
    /// the model at the same time, and both are answered.
    @Test func twoRepliesStartedTogetherNeverOverlap() async throws {
        let inFlight = InFlight()
        let runner = OnDeviceRunner()
        let one = MLXChatModel(directory: folder, runner: runner, generator: CountingGenerator(inFlight: inFlight))
        let other = MLXChatModel(directory: folder, runner: runner, generator: CountingGenerator(inFlight: inFlight))
        let turns = turns
        async let first = one.reply(to: turns("first"))
        async let second = one.reply(to: turns("second"))
        async let third = other.reply(to: turns("third"))
        let replies = try await [first, second, third]
        #expect(replies.sorted() == ["first", "second", "third"])
        #expect(inFlight.started == 3)
        #expect(inFlight.most == 1)
    }

    /// A stopped reply finishes its last work before the next one starts.
    @Test func aStoppedReplyEndsBeforeTheNextStarts() async throws {
        let inFlight = InFlight()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner,
                                 generator: CountingGenerator(inFlight: inFlight, runs: .seconds(60), settles: 0.1))
        let stopped = Task { try await model.reply(to: turns("stopped")) }
        await inFlight.waitForStarts(1)
        let next = Task { try await model.reply(to: turns("next")) }
        stopped.cancel()
        await #expect(throws: CancellationError.self) { try await stopped.value }
        next.cancel()
        _ = try? await next.value
        #expect(inFlight.most == 1)
    }

    /// Leaving the foreground stops the reply under way, returns only once
    /// it has ended, and refuses new ones until the app is back.
    @Test func leavingTheForegroundStopsAndWaits() async throws {
        let inFlight = InFlight()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner,
                                 generator: CountingGenerator(inFlight: inFlight, runs: .seconds(60), settles: 0.1))
        let under = Task { try await model.reply(to: turns("under way")) }
        await inFlight.waitForStarts(1)
        let waiting = Task { try await model.reply(to: turns("waiting")) }
        await runner.leaveForeground()
        #expect(inFlight.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await under.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await waiting.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await model.reply(to: turns("while away")) }
        #expect(inFlight.started == 1)
        #expect(!MLXChatModelError.interrupted.isLoadFailure)

        runner.returnToForeground()
        let quick = MLXChatModel(directory: folder, runner: runner,
                                 generator: CountingGenerator(inFlight: inFlight, runs: .milliseconds(5)))
        #expect(try await quick.reply(to: turns("back")) == "back")
    }

    /// A reply stopped while the prompt is read throws with work still on
    /// the graphics chip. The next reply starts only after that work drained.
    @Test func aReplyStoppedInPrefillDrainsBeforeTheNextStarts() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: PrefillGenerator(events: events))
        let stopped = Task { try await model.reply(to: turns("stopped")) }
        await events.waitFor("start stopped")
        let next = Task { try await model.reply(to: turns("next")) }
        stopped.cancel()
        await #expect(throws: CancellationError.self) { try await stopped.value }
        await events.waitFor("start next")
        next.cancel()
        _ = try? await next.value
        #expect(events.list == ["start stopped", "drained", "start next", "drained"])
    }

    /// Leaving the foreground returns only once the stopped reply's work
    /// on the graphics chip has drained.
    @Test func leavingTheForegroundWaitsForTheDrain() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: PrefillGenerator(events: events))
        let under = Task { try await model.reply(to: turns("under way")) }
        await events.waitFor("start under way")
        await runner.leaveForeground()
        events.add("background done")
        await #expect(throws: MLXChatModelError.interrupted) { try await under.value }
        #expect(events.list == ["start under way", "drained", "background done"])
    }

    /// Leaving during the first load, as the app turns inactive, returns
    /// without waiting for the load, and nothing reaches the graphics chip.
    /// The load ends on the processor and is kept, and back in front the
    /// next reply uses it.
    @Test func leavingDuringTheFirstLoadNeverReachesTheGraphicsChip() async throws {
        let events = Events()
        let hold = LoadHold()
        let runner = OnDeviceRunner()
        let model = model(events: events, runner: runner, hold: hold)
        let first = Task { try await model.reply(to: turns("first")) }
        await events.waitFor("load 1")
        runner.closeGate()
        await runner.drained()
        events.add("background done")
        #expect(events.list == ["load 1", "background done"])
        hold.release()
        await #expect(throws: MLXChatModelError.interrupted) { try await first.value }
        await events.waitFor("loaded")
        let list = events.list
        #expect(list.last == "loaded")
        let left = try #require(list.firstIndex(of: "background done"))
        #expect(left < (list.firstIndex(of: "load 3") ?? 0))
        #expect(!list.contains { $0.hasPrefix("graphics chip") || $0 == "drained" })

        runner.returnToForeground()
        #expect(try await model.reply(to: turns("back")) == "back")
        #expect(events.list.suffix(2) == ["graphics chip", "drained"])
        #expect(events.list.filter { $0.hasPrefix("load ") }.count == 3)
    }

    /// Leaving while a reply is still waiting on the first load, then coming
    /// back before that load ends, stops the reply. It does not stay pending
    /// until the load ends, and it generates nothing. The load is kept, and
    /// a fresh reply uses it.
    @Test func aReplyWaitingOnTheLoadStaysStoppedAfterComingBack() async throws {
        let events = Events()
        let hold = LoadHold()
        let runner = OnDeviceRunner()
        let model = model(events: events, runner: runner, hold: hold)
        let first = Task {
            defer { events.add("reply ended") }
            return try await model.reply(to: turns("first"))
        }
        await events.waitFor("load 1")
        runner.closeGate()
        await runner.drained()
        runner.returnToForeground()
        await events.waitFor("reply ended")
        #expect(events.list == ["load 1", "reply ended"])
        hold.release()
        await #expect(throws: MLXChatModelError.interrupted) { try await first.value }
        await events.waitFor("loaded")
        #expect(!events.list.contains { $0.hasPrefix("graphics chip") || $0 == "drained" })

        #expect(try await model.reply(to: turns("back")) == "back")
        #expect(events.list.suffix(2) == ["graphics chip", "drained"])
        #expect(events.list.filter { $0.hasPrefix("load ") }.count == 3)
    }

    /// A reply registered before leaving is still refused when it asks to
    /// run, including after the gate has opened again.
    @Test func aWaitingReplyIsRefusedAfterTheAppReturns() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let waiting = runner.registerWaiting {}
        runner.closeGate()
        runner.returnToForeground()
        await #expect(throws: MLXChatModelError.interrupted) {
            try await runner.run({
                events.add("ran")
                return "ran"
            }, drain: {
                events.add("drained")
            }, waiting: waiting)
        }
        runner.unregisterWaiting(waiting)
        #expect(events.list.isEmpty)

        let fresh = runner.registerWaiting {}
        #expect(try await runner.run({ "next" }, drain: {}, waiting: fresh) == "next")
        runner.unregisterWaiting(fresh)
    }

    private func model(events: Events, runner: OnDeviceRunner, hold: LoadHold) -> MLXChatModel {
        MLXChatModel(directory: folder, runner: runner,
                     generator: MLXGenerator(directory: folder,
                                             engine: StepEngine(events: events, runner: runner, hold: hold),
                                             onLoaded: { _ in events.add("loaded") }))
    }

    /// Once the gate is closed nothing is let onto the model, even a reply
    /// asked for in the same moment.
    @Test func aClosedGateAdmitsNothing() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: PrefillGenerator(events: events))
        runner.closeGate()
        #expect(runner.isAway)
        await #expect(throws: MLXChatModelError.interrupted) { try await model.reply(to: turns("late")) }
        await runner.drained()
        #expect(events.list.isEmpty)
    }
}
