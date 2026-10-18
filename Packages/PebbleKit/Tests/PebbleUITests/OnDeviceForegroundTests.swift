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
}

@MainActor
struct OnDeviceForegroundTests {
    private let folder = URL(fileURLWithPath: "/tmp/no-such-model", isDirectory: true)
    private let brand = Brand(name: "Example")

    private func turns(_ text: String) -> [ChatTurn] {
        [ChatTurn(id: UUID(), speaker: .person, text: text)]
    }

    /// iPhone and iPad: leaving the active state stops the reply under way
    /// before the call returns, and refuses new ones until the app is active again.
    @Test func goingToTheBackgroundStopsTheReplyAndWaitsForIt() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)

        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.moved(to: .background)
        #expect(generator.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
        await #expect(throws: MLXChatModelError.interrupted) { try await model.reply(to: turns("Still there?")) }
        #expect(generator.started == 1)

        foreground.moved(to: .foreground)
        let quick = MLXChatModel(directory: folder, runner: runner, generator: SlowGenerator(runs: .milliseconds(5)))
        #expect(try await quick.reply(to: turns("Hello")) == "An answer to Hello")
    }

    /// The Mac keeps answering in the background, as before.
    @Test func theMacKeepsAnsweringInTheBackground() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator(runs: .milliseconds(100))
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: false)

        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.moved(to: .background)
        #expect(try await reply.value == "An answer to Plan my week")
        #expect(await !runner.isAway)
    }

    /// Moves run in order, so back in front after a quick trip away ends in front.
    @Test func movesRunInOrder() async throws {
        let runner = OnDeviceRunner()
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)
        foreground.moved(to: .background)
        foreground.moved(to: .foreground)
        #expect(await !runner.isAway)
        foreground.moved(to: .background)
        #expect(await runner.isAway)
    }

    /// Inactive is the last scene leaving the active state, so it closes the
    /// gate the same way the background does. The chip is refused from then.
    @Test func deactivationClosesTheGate() async throws {
        #expect(OnDeviceForeground.place(for: .active) == .foreground)
        #expect(OnDeviceForeground.place(for: .inactive) == .background)
        #expect(OnDeviceForeground.place(for: .background) == .background)
        #if os(macOS)
        #expect(!OnDeviceForeground.platformStopsInBackground)
        #endif

        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)
        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.follow(.inactive)
        #expect(generator.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
    }

    /// One window deactivating leaves a reply alone while another is still
    /// active. The last one stops it before the call returns.
    @Test func theLastActiveSceneStopsTheReply() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)
        let front = NSObject()
        let other = NSObject()
        foreground.sceneActivated(ObjectIdentifier(front))
        foreground.sceneActivated(ObjectIdentifier(other))

        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.sceneDeactivated(ObjectIdentifier(other))
        #expect(generator.running == 1)
        #expect(await !runner.isAway)

        foreground.sceneDeactivated(ObjectIdentifier(front))
        #expect(generator.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }

        foreground.sceneActivated(ObjectIdentifier(front))
        let quick = MLXChatModel(directory: folder, runner: runner, generator: SlowGenerator(runs: .milliseconds(5)))
        #expect(try await quick.reply(to: turns("Hello")) == "An answer to Hello")
    }

    /// Entering the background with no scene still active does not return
    /// until the reply has ended.
    @Test func enteringTheBackgroundWaitsForTheReply() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = MLXChatModel(directory: folder, runner: runner, generator: generator)
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)
        let window = NSObject()
        foreground.sceneActivated(ObjectIdentifier(window))
        let reply = Task { try await model.reply(to: turns("Plan my week")) }
        await generator.waitForStart()
        foreground.sceneEnteredBackground(ObjectIdentifier(window))
        #expect(generator.running == 0)
        await #expect(throws: MLXChatModelError.interrupted) { try await reply.value }
    }

    /// In the chat: the message whose reply was stopped stays, its words
    /// are back in the composer with a plain line, and sending them again
    /// asks again, without a second copy, once the app is back.
    @Test func aStoppedReplyKeepsTheMessageToSendAgain() async throws {
        let runner = OnDeviceRunner()
        let generator = SlowGenerator()
        let model = OnDeviceChat(MLXChatModel(directory: folder, runner: runner, generator: generator))
        let foreground = OnDeviceForeground(runner: runner, stopsInBackground: true)
        let controller = ChatController(brand: brand, model: model, names: InMemoryAgentNameStore(),
                                        replyBeat: .zero)
        controller.draft = "Plan my week"
        controller.submit(controller.draft)
        await generator.waitForStart()
        foreground.moved(to: .background)
        await controller.settled()

        #expect(controller.failure == OnDeviceModelWords.interrupted)
        #expect(controller.conversation.turns.last?.speaker == .person)
        #expect(controller.conversation.turns.last?.text == "Plan my week")
        #expect(controller.draft == "Plan my week")
        #expect(!controller.isReplying)
        #expect(model.active is MLXChatModel, "a stop is not a load failure")

        foreground.moved(to: .foreground)
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
