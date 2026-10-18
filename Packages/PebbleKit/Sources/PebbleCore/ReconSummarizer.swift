import Foundation

/// Turns what was read into a `ReconSummary`. Whatever it does, the summary
/// it returns keeps the rule: every point names at least one of `sources`.
public protocol ReconSummarizer: Sendable {
    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary
    /// True when it may send what was read off this device, after the
    /// person's yes in the preview.
    var mayLeaveDevice: Bool { get }
}

extension ReconSummarizer {
    public var mayLeaveDevice: Bool { false }
}

/// How a summary's work says the person's yes to sending what it read was
/// given and is being used. `ReconRunner` sets `heard` around each summary;
/// a model that sends calls it once the preview got Send and the request is
/// about to go, and never before. Outside a summary's work it is nil, so a
/// chat's send marks nothing.
public enum CloudYes {
    @TaskLocal public static var heard: (@Sendable () -> Void)?
}

/// Puts a summary together on this device, from the sources' own sentences.
///
/// It never writes a claim of its own. Each point is a sentence one source
/// says, and another source is listed beside it only when it says much the
/// same thing and repeats every date, price and number in it. When two sources give
/// different dates or prices for the same thing, the point says so plainly
/// and names both. The overview only says what was read.
public struct LocalReconSummarizer: ReconSummarizer {
    public init() {}

    public func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }

    private struct Line {
        let source: ReconSource
        let order: Int
        let text: String
        /// Its words, less the topic's.
        let words: Set<String>
        /// Its words, the topic's included.
        let allWords: Set<String>
        let values: [ReconText.Value]
        let score: Int
    }

    private struct Draft {
        var lead: Line
        var backing: [Line] = []
        var conflicts: [Line] = []
    }

    public func summary(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date,
                        note: String? = nil) -> ReconSummary {
        let topic = ReconText.keywords(task.topic)
        var lines: [Line] = []
        for source in sources {
            for (order, sentence) in ReconText.sentences(source.text).enumerated() {
                let words = ReconText.keywords(sentence)
                guard words.count >= 3 else { continue }
                let values = ReconText.values(in: sentence)
                let score = words.intersection(topic).count * 2 + (order == 0 ? 1 : 0) + (values.isEmpty ? 0 : 1)
                lines.append(Line(source: source, order: order, text: sentence, words: words.subtracting(topic),
                                  allWords: words, values: values, score: score))
            }
        }
        // The most useful lines first; between equals, the newer source.
        lines.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.source.published != b.source.published { return a.source.published > b.source.published }
            return a.order < b.order
        }
        var drafts: [Draft] = []
        for line in lines {
            if let index = drafts.firstIndex(where: { Self.conflicts($0.lead, line) }) {
                drafts[index].conflicts.append(line)
            } else if let index = drafts.firstIndex(where: { Self.backs($0.lead, line) }) {
                if drafts[index].lead.source.id != line.source.id { drafts[index].backing.append(line) }
            } else if drafts.count < ReconSummary.maxPoints {
                drafts.append(Draft(lead: line))
            }
        }
        // Disagreements first, then points more than one source gives, and
        // points resting only on a page more than a year old last.
        let ranked = drafts.enumerated().sorted { a, b in
            func rank(_ d: Draft) -> (Int, Int, Int) {
                let sides = [d.lead] + d.conflicts + d.backing
                let oldOnly = sides.allSatisfy { $0.source.isOld(at: gatheredAt) }
                return (d.conflicts.isEmpty ? 1 : 0, oldOnly ? 1 : 0, -sides.count)
            }
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        let points = ranked.enumerated().map { index, draft in point(draft, index: index) }
        let backedTwice = points.filter { $0.sourceIDs.count > 1 && $0.disagreement == nil }.count
        let overview = ReconWords.overview(
            topic: task.topic, sources: sources.count, backedTwice: backedTwice,
            disagreements: points.filter { $0.disagreement != nil }.count,
            old: sources.filter { $0.isOld(at: gatheredAt) }.count)
        return ReconSummary(id: id, topic: task.topic, overview: overview, points: points, sources: sources,
                            gatheredAt: gatheredAt, madeOnDevice: true, note: note)
    }

    private func point(_ draft: Draft, index: Int) -> ReconPoint {
        guard !draft.conflicts.isEmpty else {
            return ReconPoint(id: "point:\(index)", text: draft.lead.text,
                              sourceIDs: [draft.lead.source.id] + draft.backing.map(\.source.id))
        }
        // The point leads with the newest page, and says what each side says.
        let sides = ([draft.lead] + draft.conflicts).sorted { $0.source.published > $1.source.published }
        let newest = sides[0]
        var said: [(publisher: String, says: String)] = []
        for side in sides {
            let value = Self.firstDiffering(side, from: sides.filter { $0.source.id != side.source.id })
            guard let value, !said.contains(where: { $0.publisher == side.source.publisher && $0.says == value }) else { continue }
            said.append((side.source.publisher, value))
        }
        let publishers = Set(said.map(\.publisher))
        let disagreement = ReconDisagreement(
            text: ReconWords.disagreement(said, newest: publishers.count > 1 ? newest.source.publisher : nil),
            sourceIDs: sides.map(\.source.id))
        // The point's words are the newest page's, so only it, and sources
        // that say the same, stand behind them. The other side is named in
        // the disagreement, never as backing what it contradicts.
        let backing = newest.source.id == draft.lead.source.id ? draft.backing : []
        let agreeing = sides.dropFirst().filter { Self.backs(newest, $0) }
        return ReconPoint(id: "point:\(index)", text: newest.text,
                          sourceIDs: [newest.source.id] + (backing + agreeing).map(\.source.id),
                          disagreement: disagreement)
    }

    /// Says much the same thing, and repeats every date, price and number
    /// the point gives, so it is listed only beside what it really says.
    private static func backs(_ lead: Line, _ line: Line) -> Bool {
        let shared = lead.words.intersection(line.words).count
        let smaller = max(1, min(lead.words.count, line.words.count))
        guard shared >= 3 || (shared >= 2 && Double(shared) / Double(smaller) >= 0.5) else { return false }
        return Set(lead.values).isSubset(of: Set(line.values))
    }

    /// About the same thing, from another source, with a different date or price.
    private static func conflicts(_ lead: Line, _ line: Line) -> Bool {
        guard lead.source.id != line.source.id, ReconText.differ(lead.values, line.values) else { return false }
        // The topic words count here: two lines about the pool reopening
        // share little else but the topic itself.
        return lead.allWords.intersection(line.allWords).count >= 3
    }

    private static func firstDiffering(_ line: Line, from others: [Line]) -> String? {
        let theirs = Set(others.flatMap(\.values))
        return line.values.first { value in
            value.kind.canDisagree && !theirs.contains(value)
                && theirs.contains { $0.kind == value.kind }
        }?.text
    }
}

/// Small text tools for reading sources: sentences, the words that matter,
/// and the dates and prices in them.
public enum ReconText {
    public struct Value: Hashable, Sendable {
        public enum Kind: Sendable, Hashable {
            case date, money, number
            /// Two sources giving different dates or prices for the same
            /// thing disagree. Plain numbers are too loose to tell.
            var canDisagree: Bool { self != .number }
        }
        public let kind: Kind
        /// As written, such as "November 3".
        public let text: String
        /// For comparing, such as "november 3".
        let key: String

        public static func == (a: Value, b: Value) -> Bool { a.kind == b.kind && a.key == b.key }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(key)
        }
    }

    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                out.append(sentence)
            }
        }
        return out
    }

    /// The words that carry meaning, lowercased and with simple endings
    /// taken off, so "reopens" and "reopening" match. Numbers, months and
    /// money words are left to `values`.
    public static func keywords(_ text: String) -> Set<String> {
        let folded = text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        let raw = folded.split(whereSeparator: { !$0.isLetter && $0 != "'" })
        var out: Set<String> = []
        for piece in raw {
            var word = String(piece)
            if word.hasSuffix("'s") { word.removeLast(2) }
            word = word.replacingOccurrences(of: "'", with: "")
            guard word.count >= 3, !stopWords.contains(word), !valueWords.contains(word) else { continue }
            out.insert(stem(word))
        }
        return out
    }

    static func stem(_ word: String) -> String {
        var w = word
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        for ending in ["ing", "ed", "es", "s"] where w.hasSuffix(ending) && w.count - ending.count >= 3 {
            if ending == "es", !(w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("sses") || w.hasSuffix("xes")) {
                continue
            }
            if ending == "s", w.hasSuffix("ss") { break }
            w.removeLast(ending.count)
            break
        }
        return w
    }

    /// Dates such as "November 3", prices such as "6 dollars" or "$6", and
    /// other numbers, in the order they appear.
    public static func values(in text: String) -> [Value] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [(NSRange, Value)] = []
        func add(_ expression: NSRegularExpression, _ kind: Value.Kind) {
            for match in expression.matches(in: text, range: range) {
                guard !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }),
                      let r = Range(match.range, in: text) else { continue }
                let written = String(text[r])
                found.append((match.range, Value(kind: kind, text: written, key: key(written, kind: kind))))
            }
        }
        add(date, .date)
        add(money, .money)
        add(number, .number)
        return found.sorted { $0.0.location < $1.0.location }.map(\.1)
    }

    /// True when both name a date, or both a price, and none of one side's
    /// matches the other's.
    public static func differ(_ a: [Value], _ b: [Value]) -> Bool {
        for kind in [Value.Kind.date, .money] {
            let left = Set(a.filter { $0.kind == kind })
            let right = Set(b.filter { $0.kind == kind })
            if !left.isEmpty, !right.isEmpty, left.isDisjoint(with: right) { return true }
        }
        return false
    }

    private static func key(_ written: String, kind: Value.Kind) -> String {
        let lower = written.lowercased()
        switch kind {
        case .money:
            let digits = lower.filter { $0.isNumber || $0 == "." }
            return lower.contains("million") ? digits + "m" : digits
        case .date, .number:
            return lower.split(whereSeparator: { $0 == " " || $0 == "," }).joined(separator: " ")
        }
    }

    private static let months = "January|February|March|April|May|June|July|August|September|October|November|December"
    private static let date = try! NSRegularExpression(
        pattern: #"\b(?:"# + months + #")\s+\d{1,2}(?:,\s*\d{4})?\b"#)
    private static let money = try! NSRegularExpression(
        pattern: #"\$\s?\d+(?:[.,]\d+)?(?:\s+million)?|\b\d+(?:[.,]\d+)?(?:\s+million)?\s+dollars\b"#,
        options: [.caseInsensitive])
    private static let number = try! NSRegularExpression(pattern: #"\b\d+(?:[.:]\d+)?\b"#)

    private static let valueWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "dollar", "dollars", "million",
    ]

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "been", "being", "will", "with", "from", "that", "this",
        "these", "those", "its", "into", "onto", "than", "then", "but", "not", "after", "before", "about",
        "more", "most", "also", "has", "have", "had", "can", "could", "would", "should", "may", "might",
        "they", "them", "their", "there", "here", "what", "when", "which", "who", "whom", "how", "out",
        "same", "very", "just", "you", "your", "our", "ours", "his", "her", "she", "him", "each", "every",
        "all", "any", "some", "now", "new", "one", "two", "three", "over", "under", "again", "because",
        "while", "where", "why", "own", "such", "only", "both", "much", "many", "come", "comes", "stay",
        "stays", "look", "into", "find", "about", "lately", "happening", "change", "changed",
    ]
}
