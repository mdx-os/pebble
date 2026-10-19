import PebbleCore
#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import GameController
#endif

/// The line a person writes to the agent, in the chat and on Today. Both use
/// this one field, so Return, Shift Return and Command Return mean the same
/// thing everywhere, and both send through `ChatController.send`.
struct Composer: View {
    @Binding var draft: String
    /// True while a reply is on its way. The field stays open, so a
    /// keyboard never loses its place; sending waits until the reply is in.
    let isBusy: Bool
    /// Whether Command Return sends from here. Off while a question waits
    /// for its answer, and on a composer another screen is covering.
    let keyboardSends: Bool
    var identifier = "composer"
    var lines: ClosedRange<Int> = 1...6
    /// What VoiceOver adds after the field's name, when sending does more
    /// than the placeholder says.
    var hint: String?
    /// Where the chat moves the cursor, as when a suggestion fills the field.
    var focus: FocusState<Bool>.Binding?
    let send: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    /// Talking instead of typing, where the app offers it. Without one in
    /// the environment, as on the Mac for now, there is no microphone.
    @Environment(VoiceCapture.self) private var voice: VoiceCapture?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var slidAway = false

    /// The placeholder, in `Theme.secondaryText` on the field, a pair
    /// `Theme.textPairs` holds to 4.5 to 1.
    static var placeholder: Text {
        Text(FirstConversation.composerPlaceholder).foregroundStyle(Theme.secondaryText)
    }

    private var canSend: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let voice, voice.owner == identifier {
                TalkLine(voice: voice, slidAway: slidAway)
                    .transition(.opacity)
            }
            bar
        }
        .onAppear { answerShortcut() }
        .onChange(of: voice?.requests.waiting) { answerShortcut() }
        .onChange(of: keyboardSends) { answerShortcut() }
        .onChange(of: voice?.phase) { _, phase in voiceChanged(phase) }
        // A line about the microphone goes once the person types instead.
        .onChange(of: draft) {
            if let voice, voice.owner == identifier, case .unavailable = voice.phase { voice.settle() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { voice?.cancel(owner: identifier) }
        }
        .onDisappear { voice?.cancel(owner: identifier) }
    }

    private var listeningHere: Bool {
        guard let voice else { return false }
        return voice.owner == identifier && voice.isActive
    }

    @ViewBuilder
    private var bar: some View {
        let bar = RoundedRectangle(cornerRadius: ChatStyle.composerCorner, style: .continuous)
        HStack(alignment: .bottom, spacing: Theme.Space.xxs) {
            // Return sends and Shift Return starts a new line.
            // The system placeholder gray is too faint to read, so the
            // placeholder is drawn in the quieter words color.
            field
                .textFieldStyle(.plain)
                .lineLimit(lines)
                .submitLabel(.send)
                .accessibilityIdentifier(identifier)
                .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
                // Keyboards are reported a moment after first asking, so ask early.
                .onAppear { _ = Self.shiftIsDown }
                .padding(.leading, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
                // One send path per platform: the draft binding reads a lone
                // Return as Send on iOS, and onKeyPress handles it on the Mac.
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        // The break goes at the end, where the cursor almost
                        // always is while writing.
                        draft += "\n"
                        return .handled
                    }
                    send(draft)
                    return .handled
                }
                #endif
            if let voice {
                TalkButton(voice: voice, owner: identifier, start: { listen(voice, $0) }, slidAway: $slidAway)
            }
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .accessibilityLabel(FirstConversation.sendTitle)
            }
            .buttonStyle(SendButtonStyle())
            .keyboardShortcut(keyboardSends ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .disabled(!canSend || listeningHere)
        }
        .padding(Theme.Space.xxs)
        // A floating bar on a soft material, tinted like a field so the
        // words and placeholder sit on the pair `Theme.textPairs` checks.
        // Reduce Transparency makes the material solid.
        .background(.regularMaterial, in: bar)
        .background(Color.primary.opacity(Theme.fieldTint), in: bar)
        // An edge that reads at 3 to 1, so the field can be found.
        // No shadow: on iPad one here drew a keyboard focus ring around the
        // sidebar's chosen row on launch, over the fill the dark
        // screenshots check.
        .overlay(bar.stroke(Theme.fieldEdge, lineWidth: 1))
    }

    /// Starts listening here: what is written stays in front of the words
    /// heard, which show in the field as they come, and a send goes the
    /// way a typed one does.
    private func listen(_ voice: VoiceCapture, _ mode: VoiceCapture.Mode) {
        let draft = $draft
        let send = self.send
        let owner = identifier
        Task {
            await voice.begin(mode, owner: owner, draft: draft.wrappedValue,
                              write: { draft.wrappedValue = $0 }, send: send)
        }
    }

    /// Takes the Talk shortcut, when it is waiting and this composer is the
    /// one in front.
    private func answerShortcut() {
        guard let voice, keyboardSends, voice.requests.waiting != nil else { return }
        let draft = $draft
        let send = self.send
        let owner = identifier
        Task {
            await voice.answerShortcut(owner: owner, draft: draft.wrappedValue,
                                       write: { draft.wrappedValue = $0 }, send: send)
        }
    }

    /// Says what happened to VoiceOver, and lets a "nothing sent" line go
    /// after a moment. Never anything while listening, so nothing is
    /// spoken into the microphone, and focus is never moved.
    private func voiceChanged(_ phase: VoiceCapture.Phase?) {
        guard let voice, voice.owner == identifier, let phase else { return }
        if voiceOver, let line = TalkLine.spoken(phase) {
            AccessibilityNotification.Announcement(line).post()
        }
        if phase == .cancelled {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if voice.phase == .cancelled { voice.settle() }
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let field = TextField(text: text, prompt: Self.placeholder, axis: .vertical) {
            Text(FirstConversation.composerPlaceholder)
        }
        if let focus {
            field.focused(focus)
        } else {
            field
        }
    }

    /// True while Shift is held on a hardware keyboard.
    private static var shiftIsDown: Bool {
        #if os(iOS)
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keys.button(forKeyCode: .leftShift)?.isPressed == true
            || keys.button(forKeyCode: .rightShift)?.isPressed == true
        #else
        false
        #endif
    }

    /// The draft, with a lone Return read as Send. On iPad the field types
    /// Return and Shift Return alike as a line break, so the Shift key is
    /// checked here. See `ComposerReturn`.
    private var text: Binding<String> {
        Binding(
            get: { draft },
            set: { new in
                if !Self.shiftIsDown, let line = ComposerReturn.textToSend(old: draft, new: new) {
                    draft = line
                    send(line)
                } else {
                    draft = new
                }
            }
        )
    }
}
#endif
