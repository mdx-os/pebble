import Foundation
import MLX
import MLXLMCommon
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

        await runner.returnToForeground()
        let quick = MLXChatModel(directory: folder, runner: runner,
                                 generator: CountingGenerator(inFlight: inFlight, runs: .milliseconds(5)))
        #expect(try await quick.reply(to: turns("back")) == "back")
    }

    /// The blocking stop, as the background callback calls it, does not
    /// return while the reply is still finishing its last work.
    @Test func leaveForegroundAndWaitBlocksUntilTheReplyEnds() async throws {
        let inFlight = InFlight()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner,
                                 generator: CountingGenerator(inFlight: inFlight, runs: .seconds(60), settles: 0.05))
        let under = Task { try await model.reply(to: turns("under way")) }
        await inFlight.waitForStarts(1)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                runner.leaveForegroundAndWait()
                done.resume()
            }
        }
        #expect(inFlight.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await under.value }
    }

    /// Cancelling between real prefill chunks throws before the finishing
    /// eval. The runner synchronizes the chip before the next reply starts.
    @Test func aCancelBetweenPrefillChunksSyncsBeforeTheNextReply() async throws {
        let order = PrefillOrder()
        let prefill = ChunkedPrefill(order: order)
        let runner = OnDeviceRunner {
            OnDeviceGPU.finish()
            order.synced()
        }
        let model = MLXChatModel(directory: folder, runner: runner, generator: prefill)
        let first = Task { try await model.reply(to: turns("a long prompt")) }
        await prefill.waitForFirstChunk()
        let next = Task { try await model.reply(to: turns("next")) }
        first.cancel()
        prefill.releaseFirstChunk()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await next.value == "next")
        // The first reply ends, then the chip is synced, then the next reply
        // starts. A sync that runs before the prefill returns, or a next reply
        // that starts before the sync, fails this.
        #expect(order.events == ["first@0", "ended@0", "sync@1", "next@1", "sync@2"])
        #expect(prefill.submitted >= 1)
        #expect(prefill.submitted == prefill.submittedWhenNextStarted)
    }
}

/// Order of prefill, graphics-chip sync, and the next reply.
private final class PrefillOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var syncs = 0
    private(set) var events: [String] = []

    func record(_ name: String) {
        lock.lock()
        events.append("\(name)@\(syncs)")
        lock.unlock()
    }

    func synced() {
        lock.lock()
        syncs += 1
        events.append("sync@\(syncs)")
        lock.unlock()
    }
}

/// The chunk loop `LLMModel.prepare` uses. Each chunk submits with
/// `asyncEval`. Cancellation throws on the next chunk, before `eval`.
private final class ChunkedPrefill: OnDeviceGenerating, @unchecked Sendable {
    let order: PrefillOrder
    private let gate = NSCondition()
    private var release = false
    private let lock = NSLock()
    private var calls = 0
    private var chunksSubmitted = 0
    private var chunksAtNextStart = 0
    /// Arrays kept until the reply returns, so a sync after the throw still sees them.
    private var held: [MLXArray] = []

    init(order: PrefillOrder) {
        self.order = order
    }

    var submittedWhenNextStarted: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunksAtNextStart
    }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        lock.lock()
        calls += 1
        let call = calls
        if call > 1 { chunksAtNextStart = chunksSubmitted }
        lock.unlock()
        order.record(call == 1 ? "first" : "next")
        if call > 1 { return transcript.last?.text ?? "" }
        defer { order.record("ended") }

        let prefill = PrefillParameters(stepSize: 2)
        var chunks = 0
        _ = try prefill.forEachChunk(total: 8, reserving: 1) { _ in
            let squared = MLXArray([Float(1), Float(2), Float(3)]) * MLXArray([Float(1), Float(2), Float(3)])
            self.hold(squared)
            asyncEval(squared)
            chunks += 1
            self.noteChunk()
            if chunks == 1 { self.waitUntilReleased() }
        }
        return transcript.last?.text ?? ""
    }

    var submitted: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunksSubmitted
    }

    func waitForFirstChunk() async {
        for _ in 0..<6000 where submitted == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseFirstChunk() {
        gate.lock()
        release = true
        gate.broadcast()
        gate.unlock()
    }

    private func hold(_ value: MLXArray) {
        lock.lock()
        held.append(value)
        lock.unlock()
    }

    private func noteChunk() {
        lock.lock()
        chunksSubmitted += 1
        lock.unlock()
    }

    private func waitUntilReleased() {
        gate.lock()
        while !release {
            gate.wait()
        }
        gate.unlock()
    }
}
