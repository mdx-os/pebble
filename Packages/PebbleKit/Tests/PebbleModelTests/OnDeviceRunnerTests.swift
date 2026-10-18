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
}
