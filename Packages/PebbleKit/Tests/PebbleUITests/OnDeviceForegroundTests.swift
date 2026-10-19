import Foundation
import PebbleCore
@testable import PebbleModel
@testable import PebbleUI
import SwiftUI
import Testing

/// Stands in for MLX: runs until stopped, or for `runs`, and counts the
/// replies on the model now. The default outlasts any wait for the main
/// actor while the whole suite runs, so only a stop ends it.
private final class SlowGenerator: OnDeviceGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var began = 0
    let runs: Duration

    init(runs: Duration = .seconds(60)) {
        self.runs = runs
    }

    var running: Int {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return began
    }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        change(1)
        defer { change(-1) }
        let end = ContinuousClock.now + runs
        while ContinuousClock.now < end {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return "An answer to \(transcript.last?.text ?? "")"
    }

    /// Waits until a reply is on the model, up to half a minute.
    func waitForStart() async {
        for _ in 0..<6000 where started == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func change(_ by: Int) {
        lock.lock()
        now += by
        if by > 0 { began += 1 }
        lock.unlock()
    }

    func drain() async {}
}

/// What happened, in order: on the model, and as the app left the screen.
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

/// Stands in for MLX: runs until stopped, and leaves work on the graphics
/// chip that only `drain` waits for.
private struct DrainingGenerator: OnDeviceGenerating {
    let events: Events

    func reply(to transcript: [ChatTurn]) async throws -> String {
        events.add("start \(transcript.last?.text ?? "")")
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

/// Stands in for the weight loader: a stop does not keep it from evaluating.
/// Only after that evaluation does it notice the stop, and `drain` records
/// the wait for the graphics chip.
private struct UngovernedLoad: OnDeviceGenerating {
    let events: Events

    func reply(to transcript: [ChatTurn]) async throws -> String {
        events.add("load")
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
        events.add("eval")
        try Task.checkCancellation()
        return "opened \(transcript.last?.text ?? "")"
    }

    func drain() async {
        events.add("sync")
    }
}

/// Every task the controller asked to keep the app open for.
@MainActor
private final class KeptOpen {
    var tasks: [Task<Void, Never>] = []
}

@MainActor
struct OnDeviceForegroundTests {
    private let folder = URL(fileURLWithPath: "/tmp/no-such-model", isDirectory: true)
    private let brand = Brand(name: "Example")

    private func turns(_ text: String) -> [ChatTurn] {
        [ChatTurn(id: UUID(), speaker: .person, text: text)]
    }

    /// iPhone and iPad: going to the background stops the reply under way,
    /// keeps the app open until it has ended, and refuses new ones until
    /// the app is back in front.
    @Test func goingToTheBackgroundStopsTheReplyAndWaitsForIt() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let kept = KeptOpen()
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { kept.tasks.append($0) }

        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.moved(to: .background)
        #expect(kept.tasks.count == 1)
        await foreground.settling?.value
        #expect(generator.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await model.reply(to: turns("Still there?")) }
        #expect(generator.started == 1)

        foreground.moved(to: .foreground)
        await foreground.settling?.value
        let quick = MLXChatModel(directory: folder, runner: runner, generator: SlowGenerator(runs: .milliseconds(5)))
        #expect(try await quick.reply(to: turns("Hello")) == "An answer to Hello")
    }

    /// The Mac keeps answering in the background, as before.
    @Test func theMacKeepsAnsweringInTheBackground() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator(runs: .milliseconds(100))
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let kept = KeptOpen()
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: false) { kept.tasks.append($0) }

        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.moved(to: .background)
        #expect(foreground.settling == nil)
        #expect(kept.tasks.isEmpty)
        #expect(try await reply.value == "An answer to Plan my week")
        #expect(!runner.isAway)
    }

    /// Moves take effect in order, so back in front after a quick trip away ends in front.
    @Test func movesRunInOrder() async throws {
        let runner = OnDeviceRunner()
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { _ in }
        foreground.moved(to: .background)
        foreground.moved(to: .foreground)
        await foreground.settling?.value
        #expect(!runner.isAway)
        foreground.moved(to: .background)
        await foreground.settling?.value
        #expect(runner.isAway)
    }

    /// The last active window turning inactive closes the gate before the
    /// handler returns: the reply under way is stopped, nothing asked for
    /// after it reaches the model, and the kept-open time ends only after
    /// the stopped reply's work on the graphics chip has drained.
    @Test func inactiveClosesTheGateAndDrainsBeforeTheBackgroundEnds() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: DrainingGenerator(events: events))
        let kept = KeptOpen()
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { work in
            kept.tasks.append(Task {
                await work.value
                events.add("background done")
            })
        }

        let under = Task { try await model.reply(to: turns("under way")) }
        await events.waitFor("start under way")
        foreground.follow(.inactive)
        #expect(events.list == ["start under way", "drained"])
        #expect(runner.isAway)
        #expect(kept.tasks.count == 1, "the app is kept open from the moment it turns inactive")
        let late = Task { try await model.reply(to: turns("after inactive")) }
        foreground.follow(.background)
        #expect(kept.tasks.count == 1)
        for task in kept.tasks { await task.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await under.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await late.value }
        #expect(events.list == ["start under way", "drained", "background done"])
    }

    /// A weight load that keeps evaluating after it was stopped still has
    /// to finish, and its work has to drain, before leaving returns.
    @Test func leavingWaitsForALoadThatIgnoresCancellation() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: UngovernedLoad(events: events))
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { _ in }

        let reply = Task { try await model.reply(to: turns("load the weights")) }
        await events.waitFor("load")
        foreground.moved(to: .background)
        #expect(events.list == ["load", "eval", "sync"])
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
    }

    /// One window leaving does not stop a reply while another is still in
    /// front. The last one waits until the reply's work has drained.
    @Test func theLastWindowToLeaveWaitsForTheDrain() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: DrainingGenerator(events: events))
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { _ in }
        let first = NSObject()
        let second = NSObject()
        foreground.sceneActivated(ObjectIdentifier(first))
        foreground.sceneActivated(ObjectIdentifier(second))

        let reply = Task { try await model.reply(to: turns("in the other window")) }
        await events.waitFor("start in the other window")
        foreground.sceneDeactivated(ObjectIdentifier(first))
        #expect(!runner.isAway)
        #expect(events.list == ["start in the other window"])
        foreground.sceneDeactivated(ObjectIdentifier(second))
        #expect(runner.isAway)
        #expect(events.list == ["start in the other window", "drained"])
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
    }

    /// With nothing running, a reply asked for after the app turned
    /// inactive, while it is still on its way out, never reaches the model.
    @Test func nothingIsAdmittedAfterInactive() async throws {
        let events = Events()
        let runner = OnDeviceRunner()
        let model = MLXChatModel(directory: folder, runner: runner, generator: DrainingGenerator(events: events))
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { _ in }
        foreground.follow(.inactive)
        let late = Task { try await model.reply(to: turns("after inactive")) }
        try await Task.sleep(for: .milliseconds(100))
        foreground.follow(.background)
        await foreground.settling?.value
        await #expect(throws: MLXChatModelError.interrupted) { try await late.value }
        #expect(events.list.isEmpty)
    }

    /// Anything but active is away: inactive, as with the app switcher, is
    /// on the way out, and nothing new should reach the graphics chip.
    @Test func anythingButActiveIsAway() {
        #expect(OnDeviceForeground.place(for: .active) == .foreground)
        #expect(OnDeviceForeground.place(for: .background) == .background)
        #expect(OnDeviceForeground.place(for: .inactive) == .background)
        #if os(macOS)
        #expect(!OnDeviceForeground.platformStopsInBackground)
        #endif
    }

    /// In the chat: the message whose reply was stopped stays, its words
    /// are back in the composer with a plain line, and sending them again
    /// asks again, without a second copy, once the app is back.
    @Test func aStoppedReplyKeepsTheMessageToSendAgain() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = OnDeviceChat(MLXChatModel(directory: folder, runner: runner, generator: generator))
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true) { _ in }
        let controller = ChatController(brand: brand, model: model, names: InMemoryAgentNameStore(),
                                        replyBeat: .zero)
        controller.draft = "Plan my week"
        controller.submit(controller.draft)
        await generator.waitForStart()
        foreground.moved(to: .background)
        await foreground.settling?.value
        await controller.settled()

        #expect(controller.failure == OnDeviceModelWords.interrupted)
        #expect(controller.conversation.turns.last?.speaker == .person)
        #expect(controller.conversation.turns.last?.text == "Plan my week")
        #expect(controller.draft == "Plan my week")
        #expect(!controller.isReplying)
        #expect(model.active is MLXChatModel, "a stop is not a load failure")

        foreground.moved(to: .foreground)
        await foreground.settling?.value
        let people = controller.conversation.turns.filter { $0.speaker == .person }.count
        let quick = MLXChatModel(directory: folder, runner: runner, generator: SlowGenerator(runs: .milliseconds(5)))
        model.use(quick)
        controller.submit(controller.draft)
        await controller.settled()
        #expect(controller.failure == nil)
        #expect(controller.conversation.turns.filter { $0.speaker == .person }.count == people)
        #expect(controller.conversation.turns.last?.text == "An answer to Plan my week")
    }

    @Test func theStoppedLineIsPlain() {
        let line = OnDeviceModelWords.interrupted
        #expect(line.contains("What you wrote is still here"))
        #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
        #expect(ChatController.pointsAtTheDraft(line))
        #expect(ChatController.failureLine(for: MLXChatModelError.interrupted) == line)
        #expect(!ChatController.nothingWasSent(MLXChatModelError.interrupted))
    }
}
