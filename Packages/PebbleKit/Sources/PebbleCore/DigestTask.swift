import Foundation

/// The one built-in task: the past week's notes, tidied into a short
/// digest the person can keep as a note.
public enum DigestTask {
    public static let title = "Tidy my notes into a short weekly digest"
    public static let request = TaskRequest(title: title)

    /// "I didn't ..." for the save.
    public static let saveTodo = "keep the digest in your notes"
    package static let todos = ["read your notes", "write the digest", saveTodo]

    /// The longest line a note gets in the digest.
    static let lineLimit = 90

    /// Where the digest goes, as the question names it.
    public static let notes = Recipient(id: "notes:what-i-remember", displayName: DigestWords.yourNotes,
                                        handle: MemoryWords.title)

    /// The question: keep exactly this text as a new note.
    public static func keep(_ digest: String) -> ProposedAction {
        ProposedAction(kind: .save, recipient: notes, details: digest)
    }

    /// Notes from the last seven days, oldest first, leaving out earlier
    /// digests. A digest is a note the agent kept that starts with the
    /// heading; one the person typed with the same words stays in.
    package static func thisWeek(_ all: [MemoryNote], now: Date) -> [MemoryNote] {
        let since = now.addingTimeInterval(-7 * 86_400)
        return all.filter { $0.savedAt >= since && $0.savedAt <= now && !isDigest($0) }
    }

    /// True for a digest kept by this task.
    package static func isDigest(_ note: MemoryNote) -> Bool {
        note.source == .inferred && note.text.hasPrefix(DigestWords.heading)
    }

    /// A short digest, no longer than a note may be: a heading, then one
    /// line per note, each shortened and ending with where the note came
    /// from, and a count of any left out. Hidden characters are taken out,
    /// so the question shows exactly what is kept.
    package static func digest(of week: [MemoryNote], now: Date) -> String {
        var lines = [DigestWords.heading + "."]
        var left = week.count
        for note in week {
            let text = tidy(note.text)
            guard !text.isEmpty else { left -= 1; continue }
            let line = "• " + (text.count > lineLimit ? String(text.prefix(lineLimit)) + "..." : text)
                + " (\(note.source.label))"
            let more = left - 1 > 0 ? "\n" + DigestWords.andMore(left - 1) : ""
            let next = (lines + [line]).joined(separator: "\n")
            guard (next + more).count <= MemoryStore.maxLength, (next + more).utf8.count <= MemoryStore.maxBytes else { break }
            lines.append(line)
            left -= 1
        }
        if left > 0 { lines.append(DigestWords.andMore(left)) }
        return lines.joined(separator: "\n")
    }

    private static func tidy(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            let p = scalar.properties
            return p.generalCategory != .format && p.generalCategory != .control && !p.isDefaultIgnorableCodePoint
                && scalar.value != 0x2800 && scalar.value != 0x3164
        }))
        .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        .joined(separator: " ")
    }
}

/// Words for the digest task and for Today's offer of it.
public enum DigestWords {
    public static let offerHeading = "Something I can do"
    public static let offerDetail = "I read only your notes, and I ask you first before I keep anything."
    public static let startTitle = "Start"
    public static let startHint = "Starts it. I'll ask you before I keep anything."
    public static let reading = "Reading your notes"
    public static let picking = "Picking out this week's notes"
    public static let writing = "Writing a short digest"
    public static let askLine = "Your digest is ready. I'll wait for your yes before I keep it in your notes."
    public static let saving = "Keeping the digest in your notes"
    public static let done = "Your weekly digest is in your notes."
    /// A kept digest the person has since removed from their notes. The
    /// card no longer shows its words.
    public static let removed = "I kept a weekly digest, and you've since removed it from your notes."
    public static let nothingThisWeek = "There were no notes from this week to tidy, so I didn't write a digest."
    public static let couldNotRead = "Sorry, I couldn't read your notes just now, so I stopped. Nothing was changed."
    public static let couldNotSave = "Sorry, I couldn't keep the digest in your notes just now. Nothing was saved."
    public static let cantSteer = "Thanks. I can't change how I tidy this one yet, so I'm going on as I was."
    public static let cantDoThatYet = "Sorry, I can't do that one yet."
    /// A task that was going when the app closed. It is never called done.
    public static let stoppedWhenClosed = "I stopped when the app closed, so I didn't finish this."
    /// Who the question names as the place the digest goes.
    public static let yourNotes = "Your notes"
    /// The digest's first line, also how an earlier digest is told apart.
    public static let heading = "This week in your notes"
    public static func andMore(_ count: Int) -> String {
        count == 1 ? "And 1 more note." : "And \(count) more notes."
    }
}
