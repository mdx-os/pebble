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
    let send: (String) -> Void

    /// The placeholder, in `Theme.secondaryText` on the field, a pair
    /// `Theme.textPairs` holds to 4.5 to 1.
    static var placeholder: Text {
        Text(FirstConversation.composerPlaceholder).foregroundStyle(Theme.secondaryText)
    }

    private var canSend: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Return sends and Shift Return starts a new line.
            // The system placeholder gray is too faint to read, so the
            // placeholder is drawn in the quieter words color.
            TextField(text: text, prompt: Self.placeholder, axis: .vertical) {
                Text(FirstConversation.composerPlaceholder)
            }
                .textFieldStyle(.plain)
                .lineLimit(lines)
                .submitLabel(.send)
                .accessibilityIdentifier(identifier)
                .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
                // Keyboards are reported a moment after first asking, so ask early.
                .onAppear { _ = Self.shiftIsDown }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(Theme.fieldTint), in: RoundedRectangle(cornerRadius: 14))
                // An edge that reads at 3 to 1, so the field can be found.
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.fieldEdge, lineWidth: 1))
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
            Button(FirstConversation.sendTitle) {
                send(draft)
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(keyboardSends ? KeyboardShortcut(.return, modifiers: .command) : nil)
            .disabled(!canSend)
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
