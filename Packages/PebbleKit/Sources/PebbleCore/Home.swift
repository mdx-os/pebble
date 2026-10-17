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
}
