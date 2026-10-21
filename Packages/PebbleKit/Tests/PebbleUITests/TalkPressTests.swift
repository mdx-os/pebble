#if canImport(SwiftUI)
import Foundation
import PebbleCore
import SwiftUI
import Testing
@testable import PebbleUI

/// A finger on the microphone: only the gesture's own end sends, and a
/// touch the system takes sends nothing.
@MainActor
struct TalkPressTests {
    /// Hears what the test says, and counts how listening stopped.
    final class CountingListener: SpeechListening {
        let access = SpeechAccess.allowed
        let hearsOnDevice = true
        var heard: (@MainActor (String) -> Void)?
        private(set) var starts = 0
        private(set) var finishes = 0
        private(set) var cancels = 0
        func askForAccess() async -> SpeechAccess { access }
        func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                   ended: @escaping @MainActor () -> Void) throws {
            starts += 1
            self.heard = heard
        }
        func finish() async -> String? {
            finishes += 1
            return nil
        }
        func cancel() {
            cancels += 1
        }
    }

    /// The composer's draft and what it sent.
    final class Draft {
        var text: String
        var sent: [String] = []
        init(_ text: String) { self.text = text }
    }

    let listener = CountingListener()
    let voice: VoiceCapture
    let draft = Draft("Before")
    let press = TalkPress()

    init() {
        voice = VoiceCapture(listener: listener, requests: TalkRequests())
    }

    /// The composer's own start, as its microphone calls it.
    @discardableResult
    func start(_ mode: VoiceCapture.Mode) -> Task<Void, Never>? {
        let draft = draft
        return Composer.listen(voice, mode, owner: "composer",
                               draft: Binding(get: { draft.text }, set: { draft.text = $0 }),
                               send: { draft.sent.append($0); draft.text = "" })
    }

    /// The finger comes down and the words are heard.
    func holdAndSay(_ words: String) async throws {
        press.down(voice) { _ = start($0) }
        try #require(await until { voice.phase == .listening })
        listener.heard?(words)
        #expect(draft.text == "Before " + words)
    }

    /// What ends a hold before its start has run: the finger lifting, the
    /// system taking the touch, or the composer going away, as the app
    /// going to the background does too.
    enum EarlyEnd: CaseIterable {
        case lifted, touchTaken, composerGone
    }

    /// The start runs in a task after the touch. Whatever ends the hold
    /// before that task runs ends it there and then, and the task starts
    /// nothing: the microphone never turns on with nobody holding.
    @Test(arguments: EarlyEnd.allCases)
    func aHoldEndedBeforeItsStartRunsNeverListens(_ end: EarlyEnd) async throws {
        var started: Task<Void, Never>?
        press.down(voice) { started = start($0) }
        #expect(voice.isActive(for: "composer"), "claimed before the task runs")
        switch end {
        case .lifted: press.lifted(voice, owner: "composer", at: .zero)
        case .touchTaken: press.reset(voice, owner: "composer")
        case .composerGone: voice.cancel(owner: "composer")
        }
        #expect(voice.phase == .idle, "ended at once, quietly, as nothing had begun")
        try #require(started != nil)
        await started?.value
        await settle()
        #expect(listener.starts == 0, "nothing starts after the hold has ended")
        #expect(voice.phase == .idle)
        #expect(!voice.isActive)
        #expect(draft.text == "Before")
        #expect(draft.sent.isEmpty)
    }

    /// A sheet covers the composer while it listens by tap, as from the
    /// Talk shortcut or VoiceOver: listening ends, what was heard stays in
    /// the draft, and nothing is sent.
    @Test func aSheetOverTheComposerEndsListeningAndKeepsTheWords() async throws {
        start(.tap)
        try #require(await until { voice.phase == .listening })
        listener.heard?("call Sam")
        Composer.keyboardSendsChanged(to: true, voice: voice, owner: "composer")
        Composer.keyboardSendsChanged(to: false, voice: voice, owner: "other")
        #expect(voice.phase == .listening, "only this composer, and only when covered")
        Composer.keyboardSendsChanged(to: false, voice: voice, owner: "composer")
        #expect(voice.phase == .idle)
        #expect(!voice.isActive)
        #expect(listener.cancels == 1, "the microphone stops")
        #expect(draft.text == "Before call Sam")
        listener.heard?("call Sam about lunch")
        await voice.release(owner: "composer")
        await settle()
        #expect(draft.text == "Before call Sam")
        #expect(draft.sent.isEmpty)
        #expect(listener.finishes == 0)
    }

    @Test func aCancelledTouchWithWordsSendsNothingAndPutsTheDraftBack() async throws {
        try await holdAndSay("call Sam")
        // A call comes in: the touch is cancelled, and the gesture never ends.
        press.reset(voice, owner: "composer")
        #expect(voice.phase == .cancelled)
        #expect(!voice.isActive)
        #expect(listener.cancels == 1, "the microphone stops")
        #expect(listener.finishes == 0)
        #expect(draft.text == "Before")
        await settle()
        #expect(draft.sent.isEmpty)
    }

    @Test func theGesturesOwnEndSendsOnceAndItsResetAfterDoesNothing() async throws {
        try await holdAndSay("call Sam")
        press.lifted(voice, owner: "composer", at: .zero)
        press.reset(voice, owner: "composer")
        #expect(await until { draft.sent == ["Before call Sam"] })
        #expect(listener.cancels == 0)
        await settle()
        #expect(draft.sent == ["Before call Sam"])
    }

    @Test func slidAwayTheEndSendsNothing() async throws {
        try await holdAndSay("call Sam")
        press.lifted(voice, owner: "composer", at: CGSize(width: 0, height: -200))
        press.reset(voice, owner: "composer")
        #expect(voice.phase == .cancelled)
        #expect(draft.text == "Before")
        await settle()
        #expect(draft.sent.isEmpty)
    }

    /// The last place the finger was seen is inside the line, but it slid
    /// past it as it lifted: the lift's own place cancels.
    @Test func aSlidePastTheLineAsTheFingerLiftsSendsNothing() async throws {
        try await holdAndSay("call Sam")
        let inside = CGSize(width: 0, height: -(TalkPress.slideToCancel - 10))
        let outside = CGSize(width: 0, height: -(TalkPress.slideToCancel + 10))
        #expect(!press.moved(to: inside), "the line still says let go to send")
        press.lifted(voice, owner: "composer", at: outside)
        press.reset(voice, owner: "composer")
        #expect(voice.phase == .cancelled)
        #expect(draft.text == "Before")
        await settle()
        #expect(draft.sent.isEmpty)
        #expect(listener.finishes == 0)
    }

    /// The reverse: last seen past the line, then back inside as it lifted.
    /// The lift's own place sends.
    @Test func aSlideBackInsideTheLineAsTheFingerLiftsSends() async throws {
        try await holdAndSay("call Sam")
        let inside = CGSize(width: TalkPress.slideToCancel - 10, height: 0)
        let outside = CGSize(width: TalkPress.slideToCancel + 10, height: 0)
        #expect(press.moved(to: outside), "the line says let go to cancel")
        press.lifted(voice, owner: "composer", at: inside)
        press.reset(voice, owner: "composer")
        #expect(await until { draft.sent == ["Before call Sam"] })
        #expect(listener.cancels == 0)
        #expect(!press.showsCancel)
    }

    /// Holds the system's question open until the test answers it.
    final class AskingListener: SpeechListening {
        private(set) var access = SpeechAccess.notAsked
        let hearsOnDevice = true
        private(set) var starts = 0
        private var answer: CheckedContinuation<SpeechAccess, Never>?
        var isAsking: Bool { answer != nil }
        func askForAccess() async -> SpeechAccess {
            await withCheckedContinuation { answer = $0 }
        }
        /// The person says yes, after the touch has gone.
        func allow() {
            access = .allowed
            answer?.resume(returning: .allowed)
            answer = nil
        }
        func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                   ended: @escaping @MainActor () -> Void) throws {
            starts += 1
        }
        func finish() async -> String? { "call Sam" }
        func cancel() {}
    }

    /// The system's question takes the touch, then the person allows it.
    /// The reset ends it there and then, quietly as nothing had begun, so
    /// the late yes never listens and nothing is sent, held or tapped.
    @Test(arguments: [VoiceCapture.Mode.hold, .tap])
    func aTouchTakenWhileAskedNeverListensOnALateYes(_ mode: VoiceCapture.Mode) async throws {
        let listener = AskingListener()
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let draft = draft
        let begin = { (mode: VoiceCapture.Mode) in
            Task {
                await voice.begin(mode, owner: "composer", draft: draft.text, write: { draft.text = $0 },
                                  send: { draft.sent.append($0); draft.text = "" })
            }
        }
        var started: Task<Void, Never>?
        if mode == .tap {
            // Tapped, or the Talk shortcut, then a finger lands while it asks.
            started = begin(.tap)
            try #require(await until { listener.isAsking })
        }
        press.down(voice) { started = begin($0) }
        try #require(await until { listener.isAsking })
        #expect(voice.phase == .asking)
        press.reset(voice, owner: "composer")
        #expect(voice.phase == .idle, "ended at once, not once the question is answered, and with no line")
        #expect(!voice.isActive)
        listener.allow()
        await started?.value
        #expect(listener.starts == 0, "a late yes never starts listening")
        #expect(voice.phase == .idle)
        await voice.release()
        await settle()
        #expect(draft.sent.isEmpty)
        #expect(draft.text == "Before")
    }

    /// Lets every task already started run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Waits, with a generous limit, until `condition` holds.
    func until(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(60))
        while !condition() {
            if ContinuousClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}
#endif
