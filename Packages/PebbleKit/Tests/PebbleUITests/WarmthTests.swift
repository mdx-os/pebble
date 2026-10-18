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

/// Holds each reply on its own gate, so a test decides exactly when each
/// one lands, with no timing involved. Which gate is chosen by what the
/// person said, never by which call reached the model first.
private struct TwoGateModel: ModelClient {
    let first: Gate
    let second: Gate
    var runsOnDevice: Bool { true }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        if transcript.last?.text == "First" {
            await first.wait()
            return "Reply 1"
        }
        await second.wait()
        return "Reply 2"
    }
}

/// Every transcript a model was handed.
private actor Transcripts {
    private(set) var all: [[ChatTurn]] = []
    func add(_ turns: [ChatTurn]) { all.append(turns) }
}

/// A model that writes down everything it is shown.
private struct SpyModel: ModelClient {
    let seen = Transcripts()
    var runsOnDevice: Bool { true }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        await seen.add(transcript)
        return "Noted."
    }
}

/// A model that does not run here, like a cloud model would.
private struct RemoteModel: ModelClient {
    func reply(to transcript: [ChatTurn]) async throws -> String { "From afar." }
}

@MainActor
struct WarmthTests {
    let brand = Brand(name: "Nova")

    /// Waits for the reply on its way to finish. No polling and no deadline:
    /// it returns exactly when the reply task does.
    private func settle(_ controller: ChatController) async {
        await controller.replyTask?.value
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

    /// Only the generation counter stands between a superseded reply and the
    /// screen: the first reply is never cancelled, it just stops being the
    /// newest. The test decides every step, so nothing rests on timing.
    @Test func aStoppedReplyNeverSettlesANewerOne() async throws {
        let first = Gate(), second = Gate()
        let controller = ChatController(brand: brand, model: TwoGateModel(first: first, second: second),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("First")
        let firstReply = try #require(controller.replyTask)
        // What a stop does to the screen, without cancelling the reply.
        controller.isReplying = false
        controller.submit("Second")
        let secondReply = try #require(controller.replyTask)
        #expect(controller.isReplying, "the second send was accepted")
        #expect(controller.conversation.turns.last?.text == "Second", "the second send was accepted")
        // The superseded reply lands first and runs to its end, uncancelled,
        // while the newer one is still out.
        await first.release()
        await firstReply.value
        #expect(!firstReply.isCancelled)
        #expect(controller.isReplying)
        #expect(controller.failure == nil)
        #expect(controller.conversation.turns.last?.text == "Second")
        #expect(!controller.conversation.turns.contains { $0.text == "Reply 1" })
        await second.release()
        await secondReply.value
        #expect(!controller.isReplying)
        #expect(controller.conversation.turns.last?.text == "Reply 2")
        #expect(!controller.conversation.turns.contains { $0.text == "Reply 1" })
    }

    @Test func aCancelledReplyChangesNothing() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        let reply = try #require(controller.replyTask)
        controller.stopReplying()
        #expect(!controller.isReplying)
        await gate.release()
        await reply.value
        #expect(controller.conversation.turns.last?.text == "Plan my day")
        #expect(controller.failure == nil)
        #expect(!controller.isReplying)
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
        #expect(FirstConversation.couldNotAnswer.contains("What you wrote is still here"))
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
        // The words weren't put back, so the line points at the bubble.
        #expect(controller.failure == FirstConversation.couldNotAnswerKeptDraft)
        #expect(!FirstConversation.couldNotAnswerKeptDraft.contains("still here"))
        #expect(controller.conversation.turns.last?.text == "Plan my day")
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

    @Test func aChipShownByReduceMotionHasStillArrivedWhenItIsTurnedOff() {
        let still = StarterChip.appearing(arrived: false, reduceMotion: true, animatesEntrances: true)
        #expect(still.arrived && !still.animates)
        // Reduce Motion goes off while the chip is on screen: it stays visible.
        #expect(StarterChip.isShown(arrived: still.arrived, reduceMotion: false, animatesEntrances: true))
        let live = StarterChip.appearing(arrived: false, reduceMotion: false, animatesEntrances: true)
        #expect(live.arrived && live.animates)
        let render = StarterChip.appearing(arrived: false, reduceMotion: false, animatesEntrances: false)
        #expect(render.arrived && !render.animates)
    }

    @Test func nothingIsSpokenWhileASheetCoversTheChat() {
        #expect(ChatView.speaks(covered: false))
        #expect(!ChatView.speaks(covered: true))
        #expect(covers(usesSidebar: true, section: .chat, showsShortcuts: true))
        #expect(covers(usesSidebar: false, section: .chat, showsShortcuts: true))
        #expect(covers(usesSidebar: false, section: .memory))
        #expect(!covers(usesSidebar: false, section: .chat))
        #expect(!covers(usesSidebar: true, section: .chat))
        // A question or a result opened from Today covers it too.
        #expect(covers(usesSidebar: true, section: .chat, readerOpen: true))
        #expect(covers(usesSidebar: false, section: .chat, readerOpen: true))
        #expect(covers(usesSidebar: true, section: .chat, questionOpen: true))
        #expect(covers(usesSidebar: false, section: .chat, questionOpen: true))
    }

    private func covers(usesSidebar: Bool, section: HomeSection, showsShortcuts: Bool = false,
                        readerOpen: Bool = false, questionOpen: Bool = false) -> Bool {
        HomeCover(usesSidebar: usesSidebar, section: section, showsShortcuts: showsShortcuts,
                  readerOpen: readerOpen, questionOpen: questionOpen).chatIsCovered
    }

    /// A reply that lands while a sheet covers the chat is not read over the
    /// sheet. It stays in the transcript to read once the sheet goes, but
    /// nothing reads it aloud then. The second check only shows that the
    /// same reply is spoken when nothing covers the chat.
    @Test func aReplyThatLandsWhileCoveredIsNotReadOverTheSheet() async throws {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        let covered = covers(usesSidebar: true, section: .chat, showsShortcuts: true)
        #expect(covered)
        controller.submit("Help me plan my morning.")
        await settle(controller)
        let reply = try #require(controller.conversation.turns.last)
        #expect(reply.speaker == .agent)
        #expect(ChatView.announcement(for: controller.conversation, covered: covered) == nil)
        #expect(ChatView.announcement(for: controller.conversation, covered: false) == reply.text)
    }

    // MARK: Sent from Today

    /// A line sent from Today fails after the person went back to Today.
    /// The words come back into Today's composer, and the failure shows
    /// right above it, so the line never reappears unexplained. It is
    /// spoken only while Today is in front.
    @Test func aFailedReplySentFromTodayIsExplainedOnToday() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        let today = TodayComposer(chat: controller, inFront: true, send: { _ in })
        #expect(today.failure == nil)
        controller.draft = "Plan my day"
        #expect(HomeView.sendsFromToday(controller.draft, chat: controller))
        await gate.release()
        await settle(controller)
        #expect(controller.draft == "Plan my day")
        #expect(today.failure == FirstConversation.couldNotAnswer)
        #expect(TodayComposer.spokenFailure(today.failure, inFront: true) == FirstConversation.couldNotAnswer)
        #expect(TodayComposer.spokenFailure(today.failure, inFront: false) == nil)
        let renderer = ImageRenderer(content: today.frame(width: 393))
        #expect(renderer.cgImage != nil)
    }

    /// With a newer draft kept, the words honestly say where the line is,
    /// in a way that is true on Today as well as in the chat.
    @Test func theKeptDraftLineIsTrueFromToday() {
        #expect(FirstConversation.couldNotAnswerKeptDraft.contains("in the chat"))
        #expect(!FirstConversation.couldNotAnswerKeptDraft.contains("above"))
        #expect(!FirstConversation.couldNotAnswerKeptDraft.contains("still here"))
    }

    /// The chat opens after a line sent from Today. A reply still on its
    /// way gets its "thinking", and one that landed before the chat was on
    /// screen is read as the chat arrives, once.
    @Test func aLineSentFromTodayIsStillSpokenWhenTheChatArrives() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
        HomeView.sendsFromToday("Plan my day", chat: controller)
        #expect(ChatView.arrival(for: controller, covered: false) == .thinking)
        #expect(ChatView.arrival(for: controller, covered: true) == .nothing)
        await gate.release()
        await settle(controller)
        // Covered keeps it for later.
        #expect(ChatView.arrival(for: controller, covered: true) == .nothing)
        #expect(ChatView.arrival(for: controller, covered: false) == .reply("Here's a plan"))
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
    }

    /// A reply a chat on screen saw land is never read again on arrival.
    @Test func aReplySeenLandingIsNotReadAgain() async {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        await settle(controller)
        controller.replyWasSeen()
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
    }

    /// The example note says "this device" only when the model keeps every
    /// word here, and the feed takes its place from the model, not a flag
    /// of its own.
    @Test func theExampleNoteFollowsThePrivacyPlace() {
        #expect(FeedWords.sampleNote(.onDevice).contains("this device"))
        #expect(!FeedWords.sampleNote(.mayLeaveDevice).localizedCaseInsensitiveContains("device"))
        for place in [PrivacyPlace.onDevice, .mayLeaveDevice] {
            let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), place: place)
            #expect(model.place == place)
        }
    }

    /// A file with no read permission stands in for locked notes, which only
    /// works when permissions apply, as for anyone but root.
    nonisolated static var permissionsAreEnforced: Bool { getuid() != 0 }

    @Test func unreadableNotesTurnOffAddingAndStayOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-unreadable-\(UUID().uuidString).json")
        let bytes = Data("not notes".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        #expect(model.isUnreadable)
        #expect(!model.canAdd)
        model.newNote = "Prefers tea"
        model.add()
        #expect(try Data(contentsOf: url) == bytes)
        #expect(model.savedCount == 0)
        #expect(model.newNote == "Prefers tea")
        #expect(model.status == MemoryWords.unreadable)
        // A writer that skips the screen is refused by the store itself.
        #expect(throws: MemoryStore.Unreadable.self) { try MemoryStore(fileURL: url).remember("Walks at noon", source: .inferred) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    /// Notes that can't be opened right now, such as on a locked iPhone, are
    /// never written over. A file with no read permission stands in for the
    /// locked file here, so the test is skipped as root, which reads it anyway.
    @Test(.enabled(if: Self.permissionsAreEnforced, "root reads a file with no read permission"))
    func lockedNotesTurnOffAddingAndStayOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-locked-\(UUID().uuidString).json")
        let seed = MemoryStore(fileURL: url)
        try seed.remember("Prefers tea", source: .toldMe)
        let bytes = try Data(contentsOf: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? seed.forgetEverything()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        // The stand-in needs permissions enforced, as they are for a normal user.
        try #require(FileManager.default.isReadableFile(atPath: url.path) == false)

        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        #expect(model.isUnavailable)
        #expect(!model.canAdd)
        model.newNote = "Walks at noon"
        model.add()
        #expect(model.status == MemoryWords.unavailable)
        #expect(model.savedCount == 0)
        #expect(model.newNote == "Walks at noon")
        // A writer that skips the screen is refused by the store itself.
        #expect(throws: MemoryStore.Unavailable.self) { try MemoryStore(fileURL: url).remember("Walks at noon", source: .inferred) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == bytes)
    }

    /// The screen's own guard holds even when the store would now accept the
    /// note: what the screen last saw as locked is not written to until it
    /// looks again. Skipped as root, like the test above.
    @Test(.enabled(if: Self.permissionsAreEnforced, "root reads a file with no read permission"))
    func theScreenRefusesNotesItLastSawAsLocked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-guard-\(UUID().uuidString).json")
        let seed = MemoryStore(fileURL: url)
        try seed.remember("Prefers tea", source: .toldMe)
        let bytes = try Data(contentsOf: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? seed.forgetEverything()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try #require(FileManager.default.isReadableFile(atPath: url.path) == false)
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        #expect(model.isUnavailable)

        // Opened again behind the screen's back.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        model.newNote = "Walks at noon"
        model.add()
        #expect(model.status == MemoryWords.unavailable)
        #expect(model.newNote == "Walks at noon")
        #expect(try Data(contentsOf: url) == bytes)
        // Looking again is what lets the note in.
        model.refresh()
        #expect(model.canAdd)
        model.add()
        #expect(model.savedCount == 1)
        #expect(model.notes.count == 2)
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
        let model = MemoryModel(store: ShowcaseScene.emptyMemory(), place: .onDevice)
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
        let model = MemoryModel(store: store, place: .onDevice)
        let before = model.statusCount
        model.newNote = "Prefers tea"
        model.add()
        model.newNote = "Walks at noon"
        model.add()
        #expect(model.status == MemoryWords.saved(.onDevice))
        #expect(model.statusCount == before + 2)
    }

    @Test func savingAndForgettingAreMarkedOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store, place: .onDevice)
        model.newNote = "   "
        model.add()
        #expect(model.savedCount == 0)
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.savedCount == 1)
        #expect(model.status == MemoryWords.saved(.onDevice))
        let tea = try #require(model.notes.first)
        model.forget(tea)
        #expect(model.forgottenCount == 1)
        #expect(model.status == MemoryWords.forgotten)
    }

    @Test func theDotsStayVisibleOnTheirBubble() {
        // The math itself: black on white is 21:1, a color on itself is 1:1.
        #expect(abs(Contrast.ratio(.black, .white) - 21) < 0.01)
        #expect(Contrast.ratio(.white, .white) == 1)
        #expect(Contrast.RGB.black.over(.white, opacity: 0.5) == Contrast.RGB(0.5, 0.5, 0.5))
        // The faintest a dot ever gets still reaches 3:1, light and dark.
        let times = stride(from: 0.0, through: 1.4, by: 0.01)
        let faintest = times.flatMap { t in (0..<3).map { Motion.dot($0, at: t, reduceMotion: false).opacity } }.min() ?? 0
        #expect(faintest >= Motion.dotFloor - 0.000_001)
        #expect(Motion.dot(0, at: 0, reduceMotion: true).opacity == Motion.dotFloor)
        for scheme in [ColorScheme.light, .dark] {
            #expect(Contrast.thinkingDot(scheme, opacity: Motion.dotFloor) >= 3, "\(scheme)")
        }
        // Increase Contrast makes them solid, moving or still.
        for t in times {
            #expect(Motion.dot(1, at: t, reduceMotion: false, increasedContrast: true).opacity == 1)
        }
        #expect(Motion.dot(1, at: 0, reduceMotion: true, increasedContrast: true).opacity == 1)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theDotsRenderWithIncreasedContrast(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: ThinkingDots(stillOverride: true)
            .environment(\.colorScheme, scheme)
            .environment(\._colorSchemeContrast, .increased))
        #expect(try #require(renderer.cgImage).width > 0)
    }

    // MARK: Privacy

    /// A note's words never reach the model, not even across a full turn.
    ///
    /// Today this passes because no code links the memory to the chat at
    /// all; there is no filter here for it to cover. It is a tripwire: the
    /// day memory is wired into what the model sees, this fails, so that
    /// change has to decide on purpose what may reach the model.
    @Test func aMemoryNoteNeverReachesTheModel() async throws {
        let token = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-private-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let memory = MemoryModel(store: store, place: .onDevice)
        memory.newNote = "My locker code is \(token)"
        memory.add()
        #expect(memory.status == MemoryWords.saved(.onDevice))
        #expect(store.notes().contains { $0.text.contains(token) })

        let spy = SpyModel()
        let controller = ChatController(brand: brand, model: spy, names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("What do you remember about me?")
        await settle(controller)
        controller.submit("What is my locker code?")
        await settle(controller)

        let seen = await spy.seen.all
        #expect(seen.count == 2, "both turns reached the model")
        #expect(controller.conversation.turns.last?.text == "Noted.")
        for transcript in seen {
            #expect(!transcript.contains { $0.text.contains(token) }, "the note reached the model")
        }
        #expect(!controller.conversation.turns.contains { $0.text.contains(token) })
    }

    @Test func aModelThatLeavesTheDeviceMakesNoDevicePromise() {
        let controller = ChatController(brand: brand, model: RemoteModel(), names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(controller.privacyPlace == .mayLeaveDevice)
        #expect(!FirstConversation.presence(controller.privacyPlace).contains("this device"))
        #expect(controller.conversation.turns.first?.text.contains("stays") == false)
        let local = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(local.privacyPlace == .onDevice)
    }

    @Test func savingSaysOnlyWhatIsTrueForThePlace() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmth-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store, place: .mayLeaveDevice)
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.status == "Saved.")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theSavedNoteSceneRenders(scheme: ColorScheme) throws {
        let model = ShowcaseScene.savedNoteMemory(place: .onDevice)
        #expect(model.status == MemoryWords.saved(.onDevice))
        #expect(model.notes.count == 1)
        // The screen still shows the note and its Forget everything, but the
        // scratch file is gone, so nothing is left behind and the empty
        // scene stays empty.
        #expect(model.hasStoredFile)
        #expect(!model.store.hasStoredFile)
        #expect(ShowcaseScene.emptyMemory().notes().isEmpty)
        let renderer = ImageRenderer(content: ShowcaseScene.memorySaved.view(brand: brand)
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 852))
        #expect(try #require(renderer.cgImage).width > 0)
    }
}
#endif
