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

/// Counts calls to a model.
private actor Calls {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

/// Holds each reply on its own gate, so a test decides exactly when each
/// one lands, with no timing involved.
private actor Landed {
    private(set) var first = false
    func markFirst() { first = true }
}

private struct TwoGateModel: ModelClient {
    let first: Gate
    let second: Gate
    let calls = Calls()
    let landed = Landed()
    var runsOnDevice: Bool { true }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        let call = await calls.next()
        if call == 1 {
            await first.wait()
            await landed.markFirst()
        } else {
            await second.wait()
        }
        return "Reply \(call)"
    }
}

@MainActor
struct WarmthTests {
    let brand = Brand(name: "Nova")

    /// Waits for the reply to land, up to a deadline long enough for a busy
    /// CI machine, and returns as soon as it does.
    private func settle(_ controller: ChatController, within limit: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + limit
        while controller.isReplying, ContinuousClock.now < deadline {
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
                                        names: InMemoryAgentNameStore(), replyBeat: .seconds(60))
        // The beat is a full minute, so a care reply that skips it is
        // clear even on a slow, busy machine.
        let started = ContinuousClock.now
        controller.submit("I want to end my life")
        await settle(controller)
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
        // The follow-up after care is never held back either.
        let again = ContinuousClock.now
        controller.submit("yes")
        await settle(controller)
        #expect(ContinuousClock.now - again < .seconds(30))
        #expect(controller.conversation.turns.last?.text == CareCheck.followUp)
    }

    @Test func careIsRecognisedFromTheTurnsNotTheReplyText() {
        let opening = Conversation.firstRun(named: "Nova").turns
        let asked = opening + [ChatTurn(id: UUID(), speaker: .person, text: "I want to end my life")]
        #expect(CareCheck.answersWithCare(asked))
        let cared = asked + [ChatTurn(id: UUID(), speaker: .agent, text: CareCheck.reply),
                             ChatTurn(id: UUID(), speaker: .person, text: "yes")]
        #expect(CareCheck.answersWithCare(cared))
        let plain = opening + [ChatTurn(id: UUID(), speaker: .person, text: "Plan my day")]
        #expect(!CareCheck.answersWithCare(plain))
    }

    @Test func aStoppedReplyNeverSettlesANewerOne() async throws {
        let first = Gate(), second = Gate()
        let model = TwoGateModel(first: first, second: second)
        let controller = ChatController(brand: brand, model: model,
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("First")
        #expect(controller.isReplying)
        controller.stopReplying()
        #expect(!controller.isReplying)
        controller.submit("Second")
        #expect(controller.isReplying, "the second send was accepted")
        #expect(controller.conversation.turns.last?.text == "Second", "the second send was accepted")
        // Let the stopped reply land while the newer one is still out.
        await first.release()
        while !(await model.landed.first) { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.isReplying)
        #expect(controller.conversation.turns.last?.text == "Second")
        #expect(!controller.conversation.turns.contains { $0.text == "Reply 1" })
        await second.release()
        await settle(controller)
        #expect(!controller.isReplying)
        #expect(controller.conversation.turns.last?.text == "Reply 2")
    }

    @Test func aFailedReplyIsExplainedKindlyAndKeepsTheWords() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.draft = "Plan my day"
        controller.submit(controller.draft)
        #expect(controller.draft.isEmpty)
        await gate.release()
        await settle(controller)
        #expect(controller.failure == FirstConversation.couldNotAnswer)
        #expect(controller.conversation.turns.last?.text == "Plan my day")
        #expect(!controller.isReplying)
        // "What you wrote is still here": back in the composer, ready to send.
        #expect(controller.draft == "Plan my day")
    }

    @Test func aFailedReplyNeverOverwritesANewDraft() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        controller.draft = "Something else"
        await gate.release()
        await settle(controller)
        #expect(controller.draft == "Something else")
    }

    @Test func theFirstRunLineIsSentWithoutATap() {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Help me plan my morning.", byHand: false)
        #expect(controller.sentCount == 0)
        #expect(controller.isReplying)
    }

    @Test func starterChipsShowInStillRendersAndWithReduceMotion() {
        #expect(StarterChip.isShown(arrived: false, reduceMotion: true, animatesEntrances: true))
        #expect(StarterChip.isShown(arrived: false, reduceMotion: false, animatesEntrances: false))
        #expect(!StarterChip.isShown(arrived: false, reduceMotion: false, animatesEntrances: true))
        #expect(StarterChip.isShown(arrived: true, reduceMotion: false, animatesEntrances: true))
        // Off unless a live screen turns it on.
        #expect(!EnvironmentValues().animatesEntrances)
    }

    @Test func unreadableNotesTurnOffAddingAndStayOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-unreadable-\(UUID().uuidString).json")
        let bytes = Data("not notes".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = MemoryModel(store: MemoryStore(fileURL: url))
        #expect(model.isUnreadable)
        #expect(!model.canAdd)
        model.newNote = "Prefers tea"
        model.add()
        #expect(try Data(contentsOf: url) == bytes)
        #expect(model.savedCount == 0)
        #expect(model.newNote == "Prefers tea")
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

    @Test func thinkingIsAnnouncedOnlyAfterTheBeat() {
        for beat in [Duration.zero, .milliseconds(600), .seconds(2)] {
            #expect(ChatView.thinkingNoticeDelay(after: beat) > beat)
        }
    }

    @Test func aSecondSaveInARowIsSpokenAgain() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store)
        let before = model.statusCount
        model.newNote = "Prefers tea"
        model.add()
        model.newNote = "Walks at noon"
        model.add()
        #expect(model.status == MemoryWords.saved)
        #expect(model.statusCount == before + 2)
    }

    @Test func savingAndForgettingAreMarkedOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-\(UUID().uuidString).json")
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
