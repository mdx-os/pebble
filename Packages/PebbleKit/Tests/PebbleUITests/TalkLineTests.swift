#if canImport(SwiftUI)
import Foundation
import PebbleCore
import SwiftUI
import Testing
@testable import PebbleUI

/// The microphone in the composer, and the line above it while it listens.
@MainActor
struct TalkLineTests {
    /// Hears whatever it is given and allows everything.
    final class StillListener: SpeechListening {
        let access = SpeechAccess.allowed
        var hearsOnDevice = true
        var heard: (@MainActor (String) -> Void)?
        func askForAccess() async -> SpeechAccess { access }
        func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                   ended: @escaping @MainActor () -> Void) throws {
            self.heard = heard
        }
        func finish() async -> String? { nil }
        func cancel() {}
    }

    /// VoiceOver hears what happened, and nothing while the microphone is
    /// on, so no voice is spoken into it.
    @Test func voiceOverHearsNothingWhileListening() {
        #expect(TalkLine.spoken(.listening) == nil)
        #expect(TalkLine.spoken(.asking) == nil)
        #expect(TalkLine.spoken(.sending) == nil)
        #expect(TalkLine.spoken(.idle) == nil)
        #expect(TalkLine.spoken(.cancelled) == VoiceWords.cancelled)
        for reason in [VoiceUnavailable.microphoneDeclined, .speechDeclined, .notOnDevice, .couldNotStart] {
            #expect(TalkLine.spoken(.unavailable(reason)) == reason.line)
        }
    }

    @Test("Smoke: the composer listening draws, in light and dark", arguments: [ColorScheme.light, .dark])
    func smokeTheComposerListening(scheme: ColorScheme) async throws {
        for mode in [VoiceCapture.Mode.hold, .tap] {
            let listener = StillListener()
            let voice = VoiceCapture(listener: listener, requests: TalkRequests())
            await voice.begin(mode, owner: "composer", draft: "", write: { _ in }, send: { _ in })
            listener.heard?("Remind me to call Sam")
            #expect(voice.phase == .listening)
            try smokeRender(Composer(draft: .constant("Remind me to call Sam"), isBusy: false, keyboardSends: true,
                                     send: { _ in })
                .environment(voice)
                .environment(\.colorScheme, scheme)
                .frame(width: 393))
        }
    }

    @Test("Smoke: an honest line about the microphone draws", arguments: [ColorScheme.light, .dark])
    func smokeTheUnavailableLine(scheme: ColorScheme) async throws {
        let listener = StillListener()
        listener.hearsOnDevice = false
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        await voice.begin(.hold, owner: "composer", draft: "", write: { _ in }, send: { _ in })
        #expect(voice.phase == .unavailable(.notOnDevice))
        try smokeRender(TalkLine(voice: voice, slidAway: false)
            .environment(\.colorScheme, scheme)
            .frame(width: 393))
    }
}
#endif
