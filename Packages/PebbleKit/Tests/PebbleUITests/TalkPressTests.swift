#if canImport(SwiftUI)
import Foundation
import PebbleCore
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
        private(set) var finishes = 0
        private(set) var cancels = 0
        func askForAccess() async -> SpeechAccess { access }
        func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                   ended: @escaping @MainActor () -> Void) throws {
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

    /// The finger comes down and the words are heard.
    func holdAndSay(_ words: String) async throws {
        let (voice, draft) = (voice, draft)
        press.down(voice) { mode in
            Task {
                await voice.begin(mode, owner: "composer", draft: draft.text, write: { draft.text = $0 },
                                  send: { draft.sent.append($0); draft.text = "" })
            }
        }
        try #require(await until { voice.phase == .listening })
        listener.heard?(words)
        #expect(draft.text == "Before " + words)
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
        press.lifted(voice, owner: "composer", slidAway: false)
        press.reset(voice, owner: "composer")
        #expect(await until { draft.sent == ["Before call Sam"] })
        #expect(listener.cancels == 0)
        await settle()
        #expect(draft.sent == ["Before call Sam"])
    }

    @Test func slidAwayTheEndSendsNothing() async throws {
        try await holdAndSay("call Sam")
        press.lifted(voice, owner: "composer", slidAway: true)
        press.reset(voice, owner: "composer")
        #expect(voice.phase == .cancelled)
        #expect(draft.text == "Before")
        await settle()
        #expect(draft.sent.isEmpty)
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
