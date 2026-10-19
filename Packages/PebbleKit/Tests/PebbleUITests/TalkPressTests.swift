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
