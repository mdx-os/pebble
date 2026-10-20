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
    var identifier = Composer.chatIdentifier
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
    /// The window this composer is in. See `TalkWindow`.
    @Environment(\.talkWindow) private var window
    @State private var slidAway = false

    /// The chat's composer and Today's, by their identifiers.
    static let chatIdentifier = "composer"
    static let todayIdentifier = "todayComposer"

    /// Whose the capture is: this composer in this window. The capture is
    /// one for the whole app, so the identifier alone, the same in every
    /// window, would let one window's composer show, send or cancel
    /// another's.
    private var owner: String { TalkWindow.owner(of: identifier, in: window) }

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
            if let voice, voice.belongs(to: owner) {
                TalkLine(voice: voice, owner: owner, slidAway: slidAway)
                    .transition(.opacity)
            }
            bar
        }
        .onAppear {
            if scenePhase == .active { voice?.requests.cameForward(TalkWindow.token(window)) }
            answerShortcut()
        }
        .onChange(of: voice?.requests.waiting) { answerShortcut() }
        .onChange(of: keyboardSends) { answerShortcut() }
        .onChange(of: voice?.phase) { _, phase in voiceChanged(phase) }
        // A line about the microphone goes once the person types instead,
        // and a change the capture didn't make ends listening, as typing does.
        .onChange(of: draft) { _, new in
            if let voice, voice.belongs(to: owner), case .unavailable = voice.phase { voice.settle() }
            voice?.edited(owner: owner, to: new)
        }
        .onChange(of: scenePhase) { _, phase in
            // The window in front last is the one the Talk shortcut opens in.
            switch phase {
            case .active:
                voice?.requests.cameForward(TalkWindow.token(window))
                answerShortcut()
            case .background:
                voice?.requests.wentAway(TalkWindow.token(window))
                voice?.cancel(owner: owner)
            default: break
            }
        }
        .onDisappear { voice?.cancel(owner: owner) }
    }

    private var listeningHere: Bool {
        voice?.isActive(for: owner) ?? false
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
                        Self.addLine(to: $draft, voice: voice, owner: owner)
                        return .handled
                    }
                    send(draft)
                    return .handled
                }
                #endif
            if let voice {
                TalkButton(voice: voice, owner: owner, start: { listen(voice, $0) }, slidAway: $slidAway)
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
        let owner = owner
        Task {
            await voice.begin(mode, owner: owner, draft: draft.wrappedValue,
                              write: { draft.wrappedValue = $0 }, send: send)
        }
    }

    /// Takes the Talk shortcut, when it is waiting and this composer is the
    /// one in front, in an active window: the one that came forward last,
    /// as the system brings one forward when the shortcut opens the app.
    private func answerShortcut() {
        guard let voice, keyboardSends, scenePhase == .active, voice.requests.waiting != nil else { return }
        let draft = $draft
        let send = self.send
        let owner = owner
        let window = TalkWindow.token(window)
        Task {
            await voice.answerShortcut(owner: owner, in: window, draft: draft.wrappedValue,
                                       write: { draft.wrappedValue = $0 }, send: send)
        }
    }

    /// Says what happened to VoiceOver, and lets a "nothing sent" line go
    /// after a moment. Never anything while listening, so nothing is
    /// spoken into the microphone, and focus is never moved.
    private func voiceChanged(_ phase: VoiceCapture.Phase?) {
        guard let voice, voice.belongs(to: owner), let phase else { return }
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

    private var text: Binding<String> {
        Self.typing(into: $draft, voice: voice, owner: owner, shiftIsDown: { Self.shiftIsDown }, send: send)
    }

    /// The draft, with a lone Return read as Send. On iPad the field types
    /// Return and Shift Return alike as a line break, so the Shift key is
    /// checked here. See `ComposerReturn`. Typing while listening ends it
    /// first, so the words typed stay and the capture never writes over them.
    static func typing(into draft: Binding<String>, voice: VoiceCapture?, owner: String,
                       shiftIsDown: @escaping () -> Bool, send: @escaping (String) -> Void) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue },
            set: { new in
                voice?.edited(owner: owner, to: new)
                if !shiftIsDown(), let line = ComposerReturn.textToSend(old: draft.wrappedValue, new: new) {
                    draft.wrappedValue = line
                    send(line)
                } else {
                    draft.wrappedValue = new
                }
            }
        )
    }

    /// Shift Return on the Mac. The break goes at the end, where the cursor
    /// almost always is while writing, and like typing it ends listening here.
    static func addLine(to draft: Binding<String>, voice: VoiceCapture?, owner: String) {
        let new = draft.wrappedValue + "\n"
        voice?.edited(owner: owner, to: new)
        draft.wrappedValue = new
    }
}

/// One window's composers, as the one voice capture tells them apart. The
/// app can show several windows on iPad, each with its own Today and chat
/// composer under the same identifiers, so an owner is the window's token
/// with the composer's identifier.
enum TalkWindow {
    /// The capture owner of the composer `identifier` in `window`. With no
    /// window, as for a lone composer in the showcase or a test, just the
    /// identifier.
    static func owner(of identifier: String, in window: UUID?) -> String {
        guard let window else { return identifier }
        return window.uuidString + "." + identifier
    }

    /// The window as `TalkRequests` knows it, to send the Talk shortcut to
    /// the one in front.
    static func token(_ window: UUID?) -> String {
        window?.uuidString ?? ""
    }
}

extension EnvironmentValues {
    /// The window the views are in, by Today's token for it. Set once per
    /// window by the home screen.
    @Entry var talkWindow: UUID?
}

extension VoiceCapture {
    /// The chat's draft changed from outside its field in `window`, as a
    /// suggestion fills it. Both of the window's composers share that
    /// draft, so listening in either ends at once, before a word heard
    /// next could write over the fill. Another window's capture goes on.
    func draftFilled(_ text: String, in window: UUID?) {
        for identifier in [Composer.chatIdentifier, Composer.todayIdentifier] {
            edited(owner: TalkWindow.owner(of: identifier, in: window), to: text)
        }
    }
}
#endif
