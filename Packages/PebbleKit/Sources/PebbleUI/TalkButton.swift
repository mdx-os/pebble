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
                .onEnded { value in letGo(at: value.translation) })
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
                slidAway = press.moved(to: moved)
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

    /// The gesture's own end: the finger lifted, this far from where it came down.
    private func letGo(at translation: CGSize) {
        slidAway = false
        press.lifted(voice, owner: owner, at: translation)
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
    /// Whether the finger, where it was last seen, would cancel. Only for
    /// the line above the composer: a lift works it out again from where
    /// the finger lifted, which can be past the last place seen.
    private(set) var showsCancel = false

    /// How far a finger slides before letting go cancels, in points.
    static let slideToCancel: CGFloat = 70

    /// Whether a finger this far from where it came down cancels.
    static func cancels(at translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > slideToCancel
    }

    /// The finger came down: listening starts, unless it is on already.
    /// `start` claims the capture before it returns (`Composer.listen`),
    /// so a lift or a lost touch right after still finds it.
    func down(_ voice: VoiceCapture, start: (VoiceCapture.Mode) -> Void) {
        guard !isDown else { return }
        isDown = true
        showsCancel = false
        guard !voice.isActive else { return }
        start(.hold)
    }

    /// The finger moved while down. Returns whether letting go here would
    /// cancel, for the line above the composer.
    func moved(to translation: CGSize) -> Bool {
        showsCancel = isDown && Self.cancels(at: translation)
        return showsCancel
    }

    /// The gesture ended as it should, with the finger lifted this far
    /// from where it came down: sends, unless it slid away.
    func lifted(_ voice: VoiceCapture, owner: String, at translation: CGSize) {
        guard isDown else { return }
        isDown = false
        let slidAway = Self.cancels(at: translation)
        showsCancel = false
        guard voice.belongs(to: owner) else { return }
        switch voice.mode {
        case .hold:
            if slidAway || voice.phase == .asking {
                // Lifted before listening began, as before the start has
                // run: it ends here, at once, so nothing starts after.
                voice.cancel(owner: owner)
            } else {
                Task { await voice.release(owner: owner) }
            }
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
        showsCancel = false
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
