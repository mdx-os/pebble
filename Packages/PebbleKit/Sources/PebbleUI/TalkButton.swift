import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The microphone beside the composer's send button. Hold to talk, let go
/// to send, slide away to cancel. With VoiceOver, a double tap starts
/// listening and another sends, with Don't send among its actions.
struct TalkButton: View {
    let voice: VoiceCapture
    /// The composer this button belongs to, in its window.
    let owner: String
    /// Starts listening for this composer, in the given mode.
    let start: (VoiceCapture.Mode) -> Void
    @GestureState private var touch: CGSize?
    @State private var press = TalkPress()
    @Binding var slidAway: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = ChatStyle.sendSize

    /// How far a finger slides before letting go cancels, in points.
    static let slideToCancel: CGFloat = 70

    private var listeningHere: Bool { voice.isActive(for: owner) }

    var body: some View {
        Image(systemName: listeningHere ? "waveform" : "mic")
            .font(Theme.TypeScale.body.weight(.semibold))
            .foregroundStyle(listeningHere ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.accentSymbol))
            .frame(width: size, height: size)
            .background(listeningHere ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), in: Circle())
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touch) { value, state, _ in
                    state = value.translation
                }
                .onEnded { _ in letGo() })
            .onChange(of: touch == nil) { _, gone in
                if gone {
                    // After the gesture's end this does nothing; with no end, the system took the touch.
                    press.reset(voice, owner: owner)
                } else {
                    slidAway = false
                    press.down(voice, start: start)
                }
            }
            .onChange(of: touch) { _, moved in
                guard let moved else { return }
                slidAway = hypot(moved.width, moved.height) > Self.slideToCancel
            }
            .accessibilityElement()
            .accessibilityLabel(listeningHere ? VoiceWords.sendTitle : VoiceWords.talkTitle)
            .accessibilityHint(listeningHere ? VoiceWords.tapToSend : VoiceWords.tapHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(owner + ".talk")
            .accessibilityAction { tap() }
            .accessibilityActions {
                if listeningHere {
                    Button(VoiceWords.dontSendTitle) { voice.cancel(owner: owner) }
                }
            }
            .haptic(.listening, trigger: voice.phase == .listening && voice.belongs(to: owner), when: { $0 })
    }

    /// The gesture's own end: the finger lifted.
    private func letGo() {
        let cancels = slidAway
        slidAway = false
        press.lifted(voice, owner: owner, slidAway: cancels)
    }

    /// VoiceOver's double tap: start, or send.
    private func tap() {
        TalkPress.tapped(voice, owner: owner, start: start)
    }
}

/// One finger on the microphone, from the touch down to its end.
///
/// Only the gesture's own end sends. When the system takes the touch, as
/// for a call coming in or its own question, the gesture is cancelled and
/// its state goes back with no end: then nothing is sent, the draft is as
/// it was and the microphone stops. A class, so the end and the reset see
/// each other at once.
@MainActor
final class TalkPress {
    private(set) var isDown = false

    /// The finger came down: listening starts, unless it is on already.
    func down(_ voice: VoiceCapture, start: (VoiceCapture.Mode) -> Void) {
        guard !isDown else { return }
        isDown = true
        guard !voice.isActive else { return }
        start(.hold)
    }

    /// The gesture ended as it should, with the finger lifted: sends,
    /// unless it slid away.
    func lifted(_ voice: VoiceCapture, owner: String, slidAway: Bool) {
        guard isDown else { return }
        isDown = false
        guard voice.belongs(to: owner) else { return }
        switch voice.mode {
        case .hold:
            if slidAway { voice.cancel(owner: owner) } else { Task { await voice.release(owner: owner) } }
        case .tap:
            // Tap mode began without a finger, so lifting one is the tap that sends.
            if voice.phase == .listening { Task { await voice.release(owner: owner) } }
        }
    }

    /// The gesture's state went back. After `lifted` there is nothing left
    /// to do; still down, the touch was cancelled, and nothing is sent.
    func reset(_ voice: VoiceCapture, owner: String) {
        guard isDown else { return }
        isDown = false
        guard voice.isActive(for: owner) else { return }
        // Cancelled at once, even while the system's question is open, so
        // a yes that comes later never starts listening or sends.
        voice.cancel(owner: owner)
    }

    /// VoiceOver's double tap on `owner`'s microphone: sends what it is
    /// listening to, or starts when nothing listens anywhere. Another
    /// composer's listening is never sent from here.
    static func tapped(_ voice: VoiceCapture, owner: String, start: (VoiceCapture.Mode) -> Void) {
        if voice.phase == .listening, voice.belongs(to: owner) {
            Task { await voice.release(owner: owner) }
        } else if !voice.isActive {
            start(.tap)
        }
    }
}

/// The calm line above the composer while it listens, and the honest one
/// after, when listening couldn't start or nothing was sent.
struct TalkLine: View {
    let voice: VoiceCapture
    /// The composer the line shows on. Its Send and Don't send act only on
    /// that composer's listening.
    let owner: String
    let slidAway: Bool

    var body: some View {
        switch voice.phase {
        case .listening:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    LiveDot()
                    Text(VoiceWords.listening)
                        .font(Theme.TypeScale.subheadline.weight(.medium))
                }
                if voice.mode == .tap {
                    Text(VoiceWords.tapToSend)
                        .font(Theme.TypeScale.footnote)
                        .foregroundStyle(Theme.secondaryText)
                    HStack(spacing: Theme.Space.s) {
                        Button(VoiceWords.dontSendTitle) { voice.cancel(owner: owner) }
                            .buttonStyle(SoftButtonStyle(neutral: true))
                            .accessibilityIdentifier("talkDontSend")
                        Button(VoiceWords.sendTitle) { Task { await voice.release(owner: owner) } }
                            .buttonStyle(SoftButtonStyle())
                            .accessibilityIdentifier("talkSend")
                    }
                } else {
                    Text(slidAway ? VoiceWords.letGoToCancel : VoiceWords.letGoToSend)
                        .font(Theme.TypeScale.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(.flat, radius: Theme.Radius.small)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("talkListening")
        case .sending:
            Text(VoiceWords.gettingLastWords)
                .font(Theme.TypeScale.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unavailable(let reason):
            GentleNotice(text: reason.line)
                .accessibilityIdentifier("talkUnavailable")
        case .cancelled:
            Text(VoiceWords.cancelled)
                .font(Theme.TypeScale.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle, .asking:
            EmptyView()
        }
    }

    /// What VoiceOver hears as the phase changes. Nothing while listening,
    /// so no voice is spoken into the microphone, and nothing that would
    /// move focus.
    static func spoken(_ phase: VoiceCapture.Phase) -> String? {
        switch phase {
        case .unavailable(let reason): reason.line
        case .cancelled: VoiceWords.cancelled
        default: nil
        }
    }
}
#endif
