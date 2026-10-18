#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SourceScan
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

/// Counts the replies asked for.
private actor Tries {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// Fails its first reply and answers every one after, each once the gate opens.
private struct FailsOnceModel: ModelClient {
    let gate: Gate
    let tries = Tries()
    var runsOnDevice: Bool { true }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        await gate.wait()
        if await tries.next() == 1 { throw ModelClientError.noPersonTurn }
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

/// Answers a continuation once, with whichever side finishes first, and
/// stops the backstop when the reply wins.
@MainActor
private final class FirstOf {
    var done: CheckedContinuation<Bool, Never>?
    var backstop: Task<Void, Never>?

    func finish(_ finished: Bool) {
        guard let done else { return }
        self.done = nil
        backstop?.cancel()
        done.resume(returning: finished)
    }
}

/// A model that does not run here, like a cloud model would.
private struct RemoteModel: ModelClient {
    func reply(to transcript: [ChatTurn]) async throws -> String { "From afar." }
}

@MainActor
struct WarmthTests {
    let brand = Brand(name: "Nova")

    /// Waits for the reply on its way to finish. No polling: it returns
    /// exactly when the reply task does. The deadline is only a backstop, far
    /// past any real reply, so a gate left shut fails the test instead of
    /// hanging CI.
    private func settle(_ controller: ChatController, deadline: Duration = .seconds(60),
                        sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let reply = controller.replyTask else { return }
        // Awaiting a task's value can't be cancelled, so the two race to
        // answer one continuation rather than sharing a task group, which
        // would wait on the stuck reply anyway.
        let race = FirstOf()
        let finished = await withCheckedContinuation { done in
            race.done = done
            race.backstop = Task { @MainActor in
                try? await Task.sleep(for: deadline)
                race.finish(false)
            }
            Task { @MainActor in
                await reply.value
                race.finish(true)
            }
        }
        #expect(finished, "the reply never finished; is a gate still shut?", sourceLocation: sourceLocation)
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
    /// sheet, and is read exactly once when the sheet goes. The test takes
    /// the same steps the chat does: the turn lands, then the cover lifts,
    /// then the screen comes and goes again.
    @Test func aReplyThatLandsWhileCoveredIsReadOnceWhenUncovered() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        var spoken: [String] = []
        let covered = covers(usesSidebar: true, section: .chat, showsShortcuts: true)
        #expect(covered)
        controller.submit("Plan my day")
        #expect(ChatView.replyLanded(in: controller, covered: covered) == nil, "the person's own line")
        await gate.release()
        await settle(controller)
        let reply = try #require(controller.conversation.turns.last)
        #expect(reply.speaker == .agent)
        // Lands under the sheet: quiet, and kept.
        if let line = ChatView.replyLanded(in: controller, covered: covered) { spoken.append(line) }
        #expect(spoken.isEmpty)
        #expect(controller.unheardReply == reply.text)
        // The sheet goes: read once.
        if case .reply(let line) = ChatView.arrival(for: controller, covered: false) { spoken.append(line) }
        // Covered again and uncovered, or the chat coming back: never again.
        #expect(ChatView.arrival(for: controller, covered: true) == .nothing)
        if case .reply(let line) = ChatView.arrival(for: controller, covered: false) { spoken.append(line) }
        #expect(spoken == [reply.text])
    }

    /// With nothing over the chat, the reply is read as it lands and never
    /// again when a sheet later comes and goes.
    @Test func aReplyReadAsItLandsIsNotReadAgainOnUncover() async throws {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        controller.submit("Help me plan my morning.")
        await settle(controller)
        let reply = try #require(controller.conversation.turns.last)
        #expect(ChatView.replyLanded(in: controller, covered: false) == reply.text)
        #expect(controller.unheardReply == nil)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
    }

    /// A reply still on its way when the sheet goes gets its "thinking".
    @Test func aReplyStillComingWhenUncoveredGetsItsThinking() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        #expect(ChatView.arrival(for: controller, covered: true) == .nothing)
        #expect(ChatView.arrival(for: controller, covered: false) == .thinking)
        await gate.release()
        await settle(controller)
    }

    // MARK: Sent from Today

    /// A line sent from Today fails after the person went back to Today.
    /// The words come back into Today's composer, and the failure shows
    /// right above it, so the line never reappears unexplained. It is
    /// spoken only while Today is in front.
    @Test func aFailedReplySentFromTodayIsExplainedOnToday() async throws {
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
        // Behind the chat or a sheet, Today keeps quiet and leaves it waiting.
        #expect(TodayComposer.spokenFailure(controller, inFront: false) == nil)
        #expect(TodayComposer.spokenFailure(controller, inFront: true) == FirstConversation.couldNotAnswer)
        // Read once: neither Today again nor the chat reads it a second time.
        #expect(TodayComposer.spokenFailure(controller, inFront: true) == nil)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
        // Still shown, though: heard is not the same as gone.
        #expect(today.failure == FirstConversation.couldNotAnswer)
        try smokeRender(today.frame(width: 393))
    }

    // MARK: Spoken once, never dropped

    /// What VoiceOver hears, played the way the screens play it: each
    /// change the chat or Today sees, in order, and every line posted.
    @MainActor
    private final class Ear {
        var heard: [String] = []
        func chat(_ arrival: ChatView.Arrival) {
            switch arrival {
            case .reply(let line), .failure(let line): heard.append(line)
            case .thinking, .nothing: break
            }
        }
        func post(_ line: String?) { if let line { heard.append(line) } }
    }

    /// Covered, a reply lands, then the cover lifts: exactly one
    /// announcement, whichever order the chat sees the two changes in.
    @Test(arguments: [false, true])
    func coveredThenALandingReplyThenUncoveredIsReadExactlyOnce(turnSeenAfterUncover: Bool) async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        let ear = Ear()
        controller.submit("Plan my day")
        ear.post(ChatView.replyLanded(in: controller, covered: false))
        // A sheet comes over the chat; the reply lands under it.
        ear.chat(ChatView.arrival(for: controller, covered: true))
        await gate.release()
        await settle(controller)
        let reply = try #require(controller.conversation.turns.last)
        #expect(reply.speaker == .agent)
        if turnSeenAfterUncover {
            // The chat sees the cover lift first, then the turn count.
            ear.chat(ChatView.arrival(for: controller, covered: false))
            ear.post(ChatView.replyLanded(in: controller, covered: false))
        } else {
            ear.post(ChatView.replyLanded(in: controller, covered: true))
            #expect(ear.heard.isEmpty, "nothing over the sheet")
            #expect(controller.unheardReply == reply.text, "kept while covered, never cleared")
            ear.chat(ChatView.arrival(for: controller, covered: false))
        }
        // The screen comes and goes again, and another sheet comes and goes.
        ear.chat(ChatView.arrival(for: controller, covered: false))
        ear.chat(ChatView.arrival(for: controller, covered: true))
        ear.chat(ChatView.arrival(for: controller, covered: false))
        #expect(ear.heard == [reply.text])
    }

    /// Covered the whole time a reply lands, any number of looks while
    /// covered never use it up, so it is never silently dropped.
    @Test func aReplyUnderASheetIsNeverDroppedWhileCovered() async throws {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: .zero)
        controller.submit("Help me plan my morning.")
        await settle(controller)
        let reply = try #require(controller.conversation.turns.last?.text)
        for _ in 0..<3 {
            #expect(ChatView.replyLanded(in: controller, covered: true) == nil)
            #expect(ChatView.arrival(for: controller, covered: true) == .nothing)
            #expect(controller.unheardReply == reply)
        }
        #expect(ChatView.arrival(for: controller, covered: false) == .reply(reply))
    }

    /// A failure line that lands under a sheet is read once the sheet goes,
    /// once, by the chat; Today, coming back later, has nothing left to say.
    @Test func aFailureUnderASheetIsReadOnceWhenUncovered() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        let ear = Ear()
        controller.draft = "Plan my day"
        controller.submit(controller.draft)
        await gate.release()
        await settle(controller)
        #expect(controller.failure == FirstConversation.couldNotAnswer)
        ear.post(ChatView.failureLanded(in: controller, covered: true))
        #expect(ear.heard.isEmpty)
        #expect(controller.unheardFailure == FirstConversation.couldNotAnswer)
        ear.chat(ChatView.arrival(for: controller, covered: false))
        ear.chat(ChatView.arrival(for: controller, covered: false))
        ear.post(TodayComposer.spokenFailure(controller, inFront: true))
        #expect(ear.heard == [FirstConversation.couldNotAnswer])
    }

    /// A failure that lands while Today is behind the chat on a narrow
    /// window, with the chat itself covered, is read by Today when it comes
    /// back in front, once.
    @Test func aFailureWhileTodayIsBehindIsReadWhenTodayIsInFront() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        let ear = Ear()
        HomeView.sendsFromToday("Plan my day", chat: controller)
        await gate.release()
        await settle(controller)
        ear.post(TodayComposer.spokenFailure(controller, inFront: false))
        ear.post(ChatView.failureLanded(in: controller, covered: true))
        #expect(ear.heard.isEmpty)
        // Back on Today, in front.
        ear.post(TodayComposer.spokenFailure(controller, inFront: true))
        ear.post(TodayComposer.spokenFailure(controller, inFront: true))
        ear.chat(ChatView.arrival(for: controller, covered: false))
        #expect(ear.heard == [FirstConversation.couldNotAnswer])
    }

    /// A failure line cleared before anyone could hear it is never read
    /// later: it is no longer true.
    @Test func aFailureClearedBeforeItIsHeardIsNotReadLater() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.draft = "Plan my day"
        controller.submit(controller.draft)
        await gate.release()
        await settle(controller)
        controller.draft = ""
        #expect(controller.failure == nil)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
        #expect(TodayComposer.spokenFailure(controller, inFront: true) == nil)
    }

    // MARK: A failed reply, then sending again

    /// A failed reply keeps the person's line in the chat, and a newer
    /// draft is left exactly as it was.
    @Test func aFailedReplyKeepsTheTurnAndTheDraft() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        let before = controller.conversation.turns.count
        controller.submit("Plan my day")
        controller.draft = "And my evening"
        await gate.release()
        await settle(controller)
        #expect(controller.conversation.turns.count == before + 1)
        let kept = try #require(controller.conversation.turns.last)
        #expect(kept.speaker == .person && kept.text == "Plan my day")
        #expect(controller.draft == "And my evening")
    }

    /// The words came back into an empty composer. Sending them again asks
    /// again for the same line; the chat never shows it twice.
    @Test func sendingTheRestoredWordsAgainDoesNotDuplicateTheLine() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.draft = "Plan my day"
        controller.submit(controller.draft)
        await gate.release()
        await settle(controller)
        #expect(controller.draft == "Plan my day")
        let turns = controller.conversation.turns.count
        #expect(controller.send(controller.draft))
        #expect(controller.draft.isEmpty)
        #expect(controller.isReplying)
        #expect(controller.conversation.turns.count == turns)
        #expect(controller.conversation.turns.filter { $0.text == "Plan my day" }.count == 1)
        await settle(controller)
        #expect(controller.conversation.turns.filter { $0.text == "Plan my day" }.count == 1)
        // A different line after a failure is a new line, as always.
        #expect(controller.send("Plan my week"))
        await settle(controller)
        #expect(controller.conversation.turns.filter { $0.speaker == .person }.map(\.text) == ["Plan my day", "Plan my week"])
    }

    /// Only a line no reply took is asked again. The same words said again
    /// after an answer are a new line, and so are words cleared by hand and
    /// typed again after a failure, since the line is still unanswered.
    @Test func onlyAnUnansweredLineIsAskedAgain() async throws {
        let gate = Gate()
        await gate.release()
        let answered = ChatController(brand: brand, model: GatedModel(gate: gate),
                                      names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(answered.send("Thanks"))
        await settle(answered)
        // Its last line is the agent's, so the same words are new.
        #expect(answered.send("Thanks"))
        await settle(answered)
        #expect(answered.conversation.turns.filter { $0.speaker == .person }.map(\.text) == ["Thanks", "Thanks"])

        // A person line left last without a failure, as a future flow might
        // leave one, is not a retry either.
        let quiet = ChatController(brand: brand, model: GatedModel(gate: gate),
                                   names: InMemoryAgentNameStore(), replyBeat: .zero)
        quiet.conversation = try quiet.conversation.appendingPerson("Hello")
        #expect(quiet.send("Hello"))
        await settle(quiet)
        #expect(quiet.conversation.turns.filter { $0.speaker == .person }.map(\.text) == ["Hello", "Hello"])

        // A stopped reply leaves its line unanswered, so it is asked again.
        let held = Gate()
        let stopped = ChatController(brand: brand, model: GatedModel(gate: held),
                                     names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(stopped.send("Plan my day"))
        stopped.stopReplying()
        await held.release()
        await settle(stopped)
        #expect(stopped.send("Plan my day"))
        await settle(stopped)
        #expect(stopped.conversation.turns.filter { $0.speaker == .person }.map(\.text) == ["Plan my day"])

        // After a failure, words cleared and typed again still ask again.
        let flaky = ChatController(brand: brand, model: FailsOnceModel(gate: gate),
                                   names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(flaky.send("Plan my day"))
        await settle(flaky)
        flaky.draft = ""
        #expect(flaky.failure == nil)
        #expect(flaky.send("Plan my day"))
        await settle(flaky)
        #expect(flaky.conversation.turns.filter { $0.speaker == .person }.map(\.text) == ["Plan my day"])
        #expect(flaky.conversation.turns.last?.text == "Here's a plan")
    }

    /// Sending again from Today after a failure doesn't duplicate it either.
    @Test func resendingFromTodayDoesNotDuplicateTheLine() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: FailsOnceModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        await gate.release()
        // A failed reply leaves the line unanswered, last, and the words back.
        #expect(HomeView.sendsFromToday("Plan my day", chat: controller))
        await settle(controller)
        #expect(controller.failure == FirstConversation.couldNotAnswer)
        #expect(controller.draft == "Plan my day")
        #expect(HomeView.sendsFromToday(controller.draft, chat: controller))
        await settle(controller)
        #expect(controller.conversation.turns.filter { $0.text == "Plan my day" }.count == 1)
        #expect(controller.conversation.turns.last?.text == "Here's a plan")
    }

    // MARK: The tap for a send

    /// Every send by hand is felt, from Today or the chat alike, and a new
    /// chat starting at zero is not.
    @Test func everySendByHandIsFelt() async {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        #expect(!SendTap.plays(controller.sentCount), "nothing sent yet")
        HomeView.sendsFromToday("Help me plan my morning.", chat: controller)
        #expect(controller.sentCount == 1 && SendTap.plays(controller.sentCount))
        await settle(controller)
        controller.send("gym, groceries")
        #expect(controller.sentCount == 2 && SendTap.plays(controller.sentCount))
        await settle(controller)
        // The first run's own line is no press, so no tap.
        let first = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(), replyBeat: .zero)
        first.submit("Help me plan my morning.", byHand: false)
        #expect(first.sentCount == 0 && !SendTap.plays(first.sentCount))
        await settle(first)
        // And it is felt only on a phone.
        #expect(Haptic.sent.feedback(on: .phone) != nil)
        #expect(Haptic.sent.feedback(on: .pad) == nil)
    }

    /// The tap is played once, around Today and the chat both, so a send
    /// from Today is felt even though Today leaves as it sends, and never
    /// felt twice. No screen plays a send tap of its own.
    @Test func theSendTapWrapsBothScreens() throws {
        let sources = try ContrastGuardTests.screenSources()
        var sendTaps: [(file: String, call: SwiftSource.Call)] = []
        for file in sources {
            for call in SwiftSource(file.text).calls(named: ["haptic"]) where call.arguments.hasPrefix(".sent") {
                sendTaps.append((file.name, call))
            }
        }
        #expect(sendTaps.count == 1, "one send tap, not one per screen")
        #expect(sendTaps.first?.file == "PebbleUI/HomeView.swift")
        #expect(sendTaps.first?.call.arguments.contains("chat.sentCount") == true)

        let home = SwiftSource(try #require(sources.first { $0.name == "PebbleUI/HomeView.swift" }?.text))
        let applied = home.calls(named: ["SendTap"])
        #expect(applied.count == 1, "applied in one place")
        let tap = try #require(applied.first).offset
        // After both layouts, Today's and the chat's, in the same Group,
        // and before the first run, which has no chat yet.
        let split = try #require(home.calls(named: ["HomeSplit"]).first).offset
        let stack = try #require(home.calls(named: ["stack"]).first).offset
        let onboarding = try #require(home.calls(named: ["OnboardingView"]).first).offset
        #expect(split < tap && stack < tap && tap < onboarding)
    }

    /// "What you wrote is still here" goes once the person clears the words
    /// by hand, on Today and in the chat alike. Editing them keeps it.
    @Test func theFailureLineGoesWhenTheRestoredWordsAreCleared() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        let today = TodayComposer(chat: controller, inFront: true, send: { _ in })
        controller.draft = "Plan my day"
        #expect(HomeView.sendsFromToday(controller.draft, chat: controller))
        await gate.release()
        await settle(controller)
        #expect(today.failure == FirstConversation.couldNotAnswer)
        controller.draft = "Plan my week"
        #expect(today.failure == FirstConversation.couldNotAnswer)
        controller.draft = "  "
        #expect(today.failure == nil)
        #expect(controller.failure == nil)
    }

    /// The kept draft line points at the bubble, which stays true whatever
    /// the draft holds, so clearing the draft leaves it.
    @Test func theKeptDraftLineStaysWhenTheDraftIsCleared() async {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate, fails: true),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        controller.draft = "Something else"
        await gate.release()
        await settle(controller)
        #expect(controller.failure == FirstConversation.couldNotAnswerKeptDraft)
        controller.draft = ""
        #expect(controller.failure == FirstConversation.couldNotAnswerKeptDraft)
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

    /// Sent from Today, the chat opens, and the person goes back to Today
    /// before the reply lands. The reply is kept in the chat, but opening
    /// the chat again later reads nothing: it would be a surprise, out of
    /// its moment. A new line after that is heard as usual. Coming back
    /// before the reply lands is different: it lands in front of them, so
    /// VoiceOver hears it as a sighted person sees it.
    @Test("Left the chat, reply landed, chat reopened: silence; reopened before it landed: heard")
    func leftTheChatReplyLandedChatReopened() async throws {
        let gate = Gate()
        let controller = ChatController(brand: brand, model: GatedModel(gate: gate),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        HomeView.sendsFromToday("Plan my day", chat: controller)
        #expect(ChatView.arrival(for: controller, covered: false) == .thinking, "the chat opens on it")
        ChatView.left(controller)
        await gate.release()
        await settle(controller)
        #expect(controller.conversation.turns.last?.text == "Here's a plan", "the reply is kept")
        #expect(controller.unheardReply == nil)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing, "reopened: silence")
        #expect(ChatView.replyLanded(in: controller, covered: false) == nil)
        // A reply that had landed unheard, under a sheet, goes the same way.
        controller.submit("And tomorrow")
        await gate.release()
        await settle(controller)
        #expect(controller.unheardReply != nil, "heard as usual after a new send")
        ChatView.left(controller)
        #expect(ChatView.arrival(for: controller, covered: false) == .nothing)
        // Left while waiting, but back before the reply lands: it lands in
        // front of them, so it is heard, as it is seen.
        HomeView.sendsFromToday("And the weekend", chat: controller)
        ChatView.left(controller)
        ChatView.cameBack(controller)
        #expect(ChatView.arrival(for: controller, covered: false) == .thinking, "reopened while it thinks")
        await gate.release()
        await settle(controller)
        #expect(ChatView.replyLanded(in: controller, covered: false) == "Here's a plan", "heard as it lands")
        #expect(ChatView.replyLanded(in: controller, covered: false) == nil, "and only once")
        // And the chat really does this as it goes off screen and comes back.
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/ChatView.swift"),
                              encoding: .utf8)
        let code = String(SwiftSource(text).code)
        #expect(code.range(of: #"\.onDisappear\s*\{[^}]*Self\.left\(controller\)"#, options: .regularExpression) != nil)
        #expect(code.range(of: #"\.onAppear\s*\{[^}]*Self\.cameBack\(controller\)\s*speak\("#,
                           options: .regularExpression) != nil, "comes back before it speaks")
    }

    /// A reply a chat on screen saw land is never read again on arrival.
    @Test func aReplySeenLandingIsNotReadAgain() async {
        let controller = ChatController(brand: brand, model: LocalStubModel(),
                                        names: InMemoryAgentNameStore(), replyBeat: .zero)
        controller.submit("Plan my day")
        await settle(controller)
        #expect(ChatView.replyLanded(in: controller, covered: false) != nil)
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

    @Test("Smoke: the thinking dots draw", arguments: [true, false], [ColorScheme.light, .dark])
    func smokeTheThinkingDots(reduceMotion: Bool, scheme: ColorScheme) throws {
        try smokeRender(ThinkingDots(stillOverride: reduceMotion).environment(\.colorScheme, scheme))
    }

    @Test("Smoke: the empty states draw",
          arguments: [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)], [ColorScheme.light, .dark])
    func smokeEmptyStates(size: CGSize, scheme: ColorScheme) throws {
        for scene in [ShowcaseScene.memoryEmpty, .newChat, .thinking] {
            try smokeRender(scene.view(brand: brand)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height))
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

    @Test("Smoke: the dots draw with Increase Contrast", arguments: [ColorScheme.light, .dark])
    func smokeTheDotsWithIncreasedContrast(scheme: ColorScheme) throws {
        try smokeRender(ThinkingDots(stillOverride: true)
            .environment(\.colorScheme, scheme)
            .environment(\._colorSchemeContrast, .increased))
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

    /// What the scene holds is checked; the drawing is a smoke check.
    @Test(arguments: [ColorScheme.light, .dark])
    func theSavedNoteSceneHoldsOneSavedNote(scheme: ColorScheme) throws {
        let model = ShowcaseScene.savedNoteMemory(place: .onDevice)
        #expect(model.status == MemoryWords.saved(.onDevice))
        #expect(model.notes.count == 1)
        // The screen still shows the note and its Forget everything, but the
        // scratch file is gone, so nothing is left behind and the empty
        // scene stays empty.
        #expect(model.hasStoredFile)
        #expect(!model.store.hasStoredFile)
        #expect(ShowcaseScene.emptyMemory().notes().isEmpty)
        try smokeRender(ShowcaseScene.memorySaved.view(brand: brand)
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 852))
    }
}
#endif
