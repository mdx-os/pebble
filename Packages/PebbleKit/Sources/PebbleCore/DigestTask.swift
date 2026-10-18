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
        write(week, now: now).text
    }

    /// A digest as written: its words, the notes with a line in it in the
    /// order of their lines, and the notes its last line counts.
    package struct Written: Equatable, Sendable {
        package let text: String
        package let quoted: [UUID]
        package let more: [UUID]

        package init(text: String, quoted: [UUID], more: [UUID]) {
            self.text = text
            self.quoted = quoted
            self.more = more
        }
    }

    /// The same as `digest(of:now:)`, saying which note each line is from.
    package static func write(_ week: [MemoryNote], now: Date) -> Written {
        var lines = [DigestWords.heading + "."]
        var quoted: [UUID] = []
        var rest = week.filter { !tidy($0.text).isEmpty }
        while let note = rest.first {
            let line = line(for: note)
            let more = rest.count - 1 > 0 ? "\n" + DigestWords.andMore(rest.count - 1) : ""
            let next = (lines + [line]).joined(separator: "\n")
            guard (next + more).count <= MemoryStore.maxLength, (next + more).utf8.count <= MemoryStore.maxBytes else { break }
            lines.append(line)
            quoted.append(note.id)
            rest.removeFirst()
        }
        if !rest.isEmpty { lines.append(DigestWords.andMore(rest.count)) }
        return Written(text: lines.joined(separator: "\n"), quoted: quoted, more: rest.map(\.id))
    }

    /// A note's line in a digest, shortened, ending with where it came from.
    package static func line(for note: MemoryNote) -> String {
        let text = tidy(note.text)
        return "• " + (text.count > lineLimit ? String(text.prefix(lineLimit)) + "..." : text)
            + " (\(note.source.label))"
    }

    /// What taking notes out of a kept digest leaves.
    package enum Dropped: Equatable, Sendable {
        /// The digest without those notes: their lines gone, or the count
        /// lowered. Never longer than it was.
        case edited(Written)
        /// No line would be left, so the digest goes too.
        case emptied
        /// The digest never quoted or counted any of them.
        case notThere
        /// The digest isn't as it was written, as when the person changed
        /// it, so nothing is taken out: it is theirs.
        case cantTell
    }

    /// Takes the notes in `gone` out of `written`, the digest whose words
    /// are now `text`. Only takes words away: nothing new is added, so
    /// nothing is kept that the person didn't say yes to.
    ///
    /// `lines` holds the line each quoted note must have, where it is
    /// known. A line is taken out only once every line is checked: each
    /// known one word for word, and one not known, as for a note gone
    /// before its words were read, only by where it sits and only for a
    /// note in `gone`. Anything else means the person changed the digest,
    /// so it is left as they made it.
    package static func dropping(_ gone: Set<UUID>, from text: String, as written: Written,
                                 lines expected: [UUID: String]) -> Dropped {
        let quoted = written.quoted, more = written.more
        guard !gone.isDisjoint(with: quoted + more) else { return .notThere }
        var lines = text.components(separatedBy: "\n")
        guard lines.count == 1 + quoted.count + (more.isEmpty ? 0 : 1),
              lines.first == DigestWords.heading + ".",
              more.isEmpty || lines.last == DigestWords.andMore(more.count) else { return .cantTell }
        for (index, id) in quoted.enumerated() {
            let line = lines[index + 1]
            if let want = expected[id] {
                guard line == want else { return .cantTell }
            } else {
                guard gone.contains(id), line.hasPrefix("• ") else { return .cantTell }
            }
        }
        let keptQuoted = quoted.filter { !gone.contains($0) }
        let keptMore = more.filter { !gone.contains($0) }
        guard !keptQuoted.isEmpty else { return .emptied }
        for index in quoted.indices.reversed() where gone.contains(quoted[index]) { lines.remove(at: index + 1) }
        if !more.isEmpty { lines.removeLast() }
        if !keptMore.isEmpty { lines.append(DigestWords.andMore(keptMore.count)) }
        return .edited(Written(text: lines.joined(separator: "\n"), quoted: keptQuoted, more: keptMore))
    }

    /// For a digest whose lines aren't known, as one whose task was let
    /// go: true when it may still hold the note's words. It leans to yes:
    /// case and spacing are ignored, and a line counts when its first
    /// words are the note's, or the note's first words are in it, so a
    /// line changed a little is still found.
    package static func mayQuote(_ note: MemoryNote, in text: String) -> Bool {
        let words = fold(note.text)
        guard !words.isEmpty else { return false }
        let digest = fold(text)
        if digest.contains(String(words.prefix(lineLimit))) { return true }
        if words.count >= nearMatch, digest.contains(String(words.prefix(nearMatch))) { return true }
        return text.components(separatedBy: "\n").contains { line in
            var body = fold(line)
            if body.hasPrefix("•") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return body.count >= nearMatch && words.contains(String(body.prefix(nearMatch)))
        }
    }

    /// How many characters at the start of a line make a match.
    static let nearMatch = 20

    private static func fold(_ text: String) -> String {
        tidy(text).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
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
    /// The same digest was kept before, so it isn't kept twice.
    public static let alreadyKept = "This digest is already in your notes, so I didn't keep it twice."
    public static let tooLongToKeep = "Sorry, the digest came out too long for one note, so nothing was saved."
    public static let emptyDigest = "Sorry, the digest came out empty, so nothing was saved."
    /// A kept digest that still quotes a note the person has forgotten,
    /// as when they changed the digest themselves. Its words are hidden
    /// here, and the line says why.
    public static let hiddenQuote = "Your weekly digest is in your notes. I'm not showing it here, because it quotes a note you removed."
    /// A kept digest while the notes can't be opened, as on a locked device.
    public static let notesLocked = "Your weekly digest is in your notes. I can't open them just now to show it here."
    /// Forgetting a note whose words are still in a kept digest.
    public static let stillInDigest = "I forgot that note, but its words are still in your weekly digest. You can change or remove the digest here too."
    /// Changing a note whose earlier words are still in a kept digest.
    public static let earlierWordsInDigest = "I changed that note, but your weekly digest still has its earlier words. You can change or remove the digest here too."
    /// A digest not yet kept whose notes changed or went while it was
    /// being written or waiting for a yes. The yes was for other words.
    public static let noteChanged = "One of the notes I was tidying changed, so I stopped. Nothing was kept."
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
