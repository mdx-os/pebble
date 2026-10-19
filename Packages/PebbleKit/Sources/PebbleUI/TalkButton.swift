import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The microphone beside the composer's send button. Hold to talk, let go
/// to send, slide away to cancel. With VoiceOver, a double tap starts
/// listening and another sends, with Don't send among its actions.
struct TalkButton: View {
    let voice: VoiceCapture
    /// The composer this button belongs to, by its identifier.
    let owner: String
    /// Starts listening for this composer, in the given mode.
    let start: (VoiceCapture.Mode) -> Void
    @GestureState private var touch: CGSize?
    @Binding var slidAway: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = ChatStyle.sendSize

    /// How far a finger slides before letting go cancels, in points.
    static let slideToCancel: CGFloat = 70

    private var listeningHere: Bool { voice.owner == owner && voice.isActive }

    var body: some View {
        Image(systemName: listeningHere ? "waveform" : "mic")
            .font(Theme.TypeScale.body.weight(.semibold))
            .foregroundStyle(listeningHere ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.accentSymbol))
            .frame(width: size, height: size)
            .background(listeningHere ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), in: Circle())
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).updating($touch) { value, state, _ in
                state = value.translation
            })
            .onChange(of: touch == nil) { _, lifted in
                lifted ? letGo() : press()
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
                    Button(VoiceWords.dontSendTitle) { voice.cancel() }
                }
            }
            .haptic(.listening, trigger: voice.phase == .listening && voice.owner == owner, when: { $0 })
    }

    private func press() {
        slidAway = false
        guard !voice.isActive else { return }
        start(.hold)
    }

    private func letGo() {
        guard voice.owner == owner else { return }
        let cancels = slidAway
        slidAway = false
        switch voice.mode {
        case .hold:
            if cancels { voice.cancel() } else { Task { await voice.release() } }
        case .tap:
            // Tap mode began without a finger, so lifting one is the tap that sends.
            if voice.phase == .listening { Task { await voice.release() } }
        }
    }

    /// VoiceOver's double tap: start, or send.
    private func tap() {
        if voice.phase == .listening, voice.owner == owner {
            Task { await voice.release() }
        } else if !voice.isActive {
            start(.tap)
        }
    }
}

/// The calm line above the composer while it listens, and the honest one
/// after, when listening couldn't start or nothing was sent.
struct TalkLine: View {
    let voice: VoiceCapture
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
                        Button(VoiceWords.dontSendTitle) { voice.cancel() }
                            .buttonStyle(SoftButtonStyle(neutral: true))
                            .accessibilityIdentifier("talkDontSend")
                        Button(VoiceWords.sendTitle) { Task { await voice.release() } }
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
