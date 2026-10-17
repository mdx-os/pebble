/// The places a person can go once the first run is done. On a wide screen
/// they sit in a sidebar; on a narrow one, the chat is home and the memory
/// opens over it.
public enum HomeSection: String, CaseIterable, Hashable, Sendable {
    case chat, memory

    public var title: String {
        switch self {
        case .chat: HomeWords.chatTitle
        case .memory: MemoryWords.title
        }
    }

    public var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .memory: "heart.text.square"
        }
    }
}

/// Words for the home screen, its menus and its keyboard shortcuts.
public enum HomeWords {
    public static let chatTitle = "Chat"
    public static let newChatTitle = "New chat"
    public static let goMenuTitle = "Go"
    public static let shortcutsTitle = "Keyboard shortcuts"
    public static let sendShortcut = "Send"
    public static let newLineShortcut = "Start a new line"
    public static let sendFromAnywhereShortcut = "Send while editing"
    public static let closeShortcut = "Close"
    public static let newChatQuestion = "Start a new chat?"
    public static let newChatDetail = "This conversation isn't kept, so it will be gone."
    public static let newChatConfirm = "Start new chat"
    public static let cancelTitle = "Keep this chat"

    /// Keys spelled out for VoiceOver, which reads the Command glyph as
    /// "place of interest sign".
    public static func spoken(_ keys: String) -> String {
        keys.replacingOccurrences(of: "⌘", with: "Command")
            .replacingOccurrences(of: "Esc", with: "Escape")
    }

    /// What each shortcut does, in the order the help screen lists them.
    /// Keys are written the way Apple's menus write them.
    public static let shortcuts: [(keys: String, action: String)] = [
        ("Return", sendShortcut),
        ("Shift Return", newLineShortcut),
        ("⌘ Return", sendFromAnywhereShortcut),
        ("⌘ N", newChatTitle),
        ("⌘ 1", chatTitle),
        ("⌘ 2", MemoryWords.title),
        ("⌘ /", shortcutsTitle),
        ("Esc", closeShortcut),
    ]
}

/// When starting a new chat should ask first. Chats aren't kept yet, so a
/// new one drops the current conversation; once the person has said
/// anything, or has words waiting to go, that needs a yes.
public enum NewChatRule {
    public static func asksFirst(personHasSpoken: Bool, draft: String, pendingLine: String?) -> Bool {
        personHasSpoken
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(pendingLine ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the Return key means in the chat composer.
///
/// Return sends and Shift Return starts a new line. A software keyboard has
/// no Shift Return, and a multi-line field types a plain Return as a line
/// break, so the composer looks at each edit: one bare line break typed on
/// its own is read as Send.
public enum ComposerReturn {
    /// The text to send when `new` is `old` with a single line break typed
    /// into it, or nil when the edit was anything else (typing, pasting,
    /// deleting, or a line break the person asked for).
    public static func textToSend(old: String, new: String) -> String? {
        if let typed = loneBreak(old: old, new: new) { return typed }
        return breakAfterAutocorrect(old: old, new: new)
    }

    /// A single line break typed into otherwise unchanged text.
    private static func loneBreak(old: String, new: String) -> String? {
        guard new.count == old.count + 1 else { return nil }
        var o = old.startIndex
        var n = new.startIndex
        while o < old.endIndex, old[o] == new[n] {
            o = old.index(after: o)
            n = new.index(after: n)
        }
        guard new[n] == "\n" || new[n] == "\r\n" else { return nil }
        guard old[o...] == new[new.index(after: n)...] else { return nil }
        return old
    }

    /// Return pressed with a correction pending: the keyboard swaps the last
    /// word and adds the line break in one edit. Only the last word may
    /// change, and the break must be at the very end, so pasted text and
    /// edits elsewhere stay edits.
    private static func breakAfterAutocorrect(old: String, new: String) -> String? {
        guard new.hasSuffix("\n"), !old.hasSuffix("\n") else { return nil }
        let body = String(new.dropLast())
        guard body != old, !body.isEmpty else { return nil }
        let shared = zip(old, body).prefix { $0 == $1 }.count
        let oldTail = old.dropFirst(shared)
        let newTail = body.dropFirst(shared)
        // The changed part sits inside the last word of what was there.
        let lastWordStart = old.lastIndex(where: { $0.isWhitespace }).map { old.distance(from: old.startIndex, to: $0) + 1 } ?? 0
        guard shared >= lastWordStart, !oldTail.isEmpty else { return nil }
        guard !newTail.dropLast(newTail.last == " " ? 1 : 0).contains(where: { $0.isWhitespace }) else { return nil }
        return body
    }
}
