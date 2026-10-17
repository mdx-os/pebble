#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// A model that answers only when the test lets it.
private actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        open = true
        waiting?.resume()
        waiting = nil
    }
}

private struct GatedModel: ModelClient {
    let gate: Gate
    var fails = false
    var runsOnDevice: Bool { true }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        await gate.wait()
        if fails { throw ModelClientError.noPersonTurn }
        return "Here's a plan"
    }
}

@MainActor
struct WarmthTests {
    let brand = Brand(name: "Nova")

    private func settle(_ controller: ChatController) async {
        for _ in 0..<200 where controller.isReplying {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func theThinkingPresenceShowsWhileAReplyComesAndThenGoes() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(!controller.isReplying)
        controller.submit("Plan my day")
        #expect(controller.isReplying)
        #expect(controller.sentCount == 1)
        await gate.release()
        await settle(controller)
        #expect(!controller.isReplying)
        #expect(controller.conversation.turns.last?.text == "Here's a plan")
        #expect(controller.failure == nil)
    }

    @Test func aQuickReplyWaitsACalmBeat() async {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .milliseconds(300))
        let started = ContinuousClock.now
        controller.submit("Help me plan my morning.")
        await settle(controller)
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(controller.conversation.turns.last?.speaker == .agent)
    }

    @Test func wordsOfCareAreNeverHeldBack() async {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .seconds(5))
        let started = ContinuousClock.now
        controller.submit("I want to end my life")
        await settle(controller)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
    }

    @Test func aFailedReplyIsExplainedKindlyAndKeepsTheWords() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        await gate.release()
        await settle(controller)
        #expect(controller.failure == FirstConversation.couldNotAnswer)
        #expect(controller.conversation.turns.last?.text == "Plan my day")
        #expect(!controller.isReplying)
    }

    @Test func theDotsHoldStillWithReduceMotion() {
        let early = (0..<3).map { Motion.dot($0, at: 0, reduceMotion: true) }
        let later = (0..<3).map { Motion.dot($0, at: 0.7, reduceMotion: true) }
        #expect(early.map(\.opacity) == later.map(\.opacity))
        #expect((early + later).allSatisfy { $0.lift == 0 })
        #expect(Motion.entranceOffset(reduceMotion: true) == 0)
        #expect(Motion.pressedScale(reduceMotion: true) == 1)
        #expect(Motion.stagger(2, reduceMotion: true) == 0)
    }

    @Test func theDotsBreatheWithoutReduceMotion() {
        let a = Motion.dot(0, at: 0, reduceMotion: false)
        let b = Motion.dot(0, at: 0.35, reduceMotion: false)
        #expect(a.opacity != b.opacity)
        #expect(Motion.dot(0, at: 0.35, reduceMotion: false).opacity != Motion.dot(2, at: 0.35, reduceMotion: false).opacity)
        #expect(Motion.entranceOffset(reduceMotion: false) > 0)
    }

    @Test(arguments: [true, false], [ColorScheme.light, .dark])
    func theThinkingDotsRender(reduceMotion: Bool, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: ThinkingDots(stillOverride: reduceMotion)
            .environment(\.colorScheme, scheme))
        #expect(try #require(renderer.cgImage).width > 0)
    }

    @Test(arguments: [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)], [ColorScheme.light, .dark])
    func emptyStatesRender(size: CGSize, scheme: ColorScheme) throws {
        for scene in [ShowcaseScene.memoryEmpty, .newChat, .thinking] {
            let renderer = ImageRenderer(content: scene.view(brand: brand)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height))
            #expect(try #require(renderer.cgImage).width == Int(size.width * renderer.scale))
        }
    }

    @Test func theEmptyMemoryHasNothingInIt() {
        let model = MemoryModel(store: ShowcaseScene.emptyMemory())
        #expect(model.notes.isEmpty)
        #expect(!model.isUnreadable && !model.isUnavailable)
    }

    @Test func theThinkingSceneShowsThePresence() {
        let controller = ShowcaseScene.thinkingChat(brand: brand)
        #expect(controller.isReplying)
        #expect(controller.conversation.turns.last?.speaker == .person)
    }

    @Test func savingAndForgettingAreMarkedOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-warmth-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store)
        model.newNote = "   "
        model.add()
        #expect(model.savedCount == 0)
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.savedCount == 1)
        #expect(model.status == MemoryWords.saved)
        let tea = try #require(model.notes.first)
        model.forget(tea)
        #expect(model.forgottenCount == 1)
        #expect(model.status == MemoryWords.forgotten)
    }

    @Test func noHapticsWithoutAPhone() {
        #if os(macOS)
        #expect(!Haptic.isAvailable)
        #endif
    }
}
#endif
