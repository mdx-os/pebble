import Foundation

/// What `Redactor` left of a piece of text, and what it took out.
public struct Redaction: Sendable, Equatable {
    /// The kinds of personal detail the redactor hides, in the order it
    /// claims them when two overlap.
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case privateWord, email, card, phone, address, name

        /// What the detail becomes in the text that leaves the device.
        public var mask: String {
            switch self {
            case .privateWord: "[private]"
            case .email: "[email]"
            case .card: "[card number]"
            case .phone: "[phone number]"
            case .address: "[address]"
            case .name: "[name]"
            }
        }

        /// How the preview counts it: "2 names", "1 phone number".
        public func counted(_ count: Int) -> String {
            let one: String
            let many: String
            switch self {
            case .privateWord: (one, many) = ("private word", "private words")
            case .email: (one, many) = ("email", "emails")
            case .card: (one, many) = ("card number", "card numbers")
            case .phone: (one, many) = ("phone number", "phone numbers")
            case .address: (one, many) = ("address", "addresses")
            case .name: (one, many) = ("name", "names")
            }
            return "\(count) \(count == 1 ? one : many)"
        }
    }

    public let text: String
    /// How many of each kind were hidden.
    public let hidden: [Kind: Int]

    public init(text: String, hidden: [Kind: Int] = [:]) {
        self.text = text
        self.hidden = hidden
    }

    public var isUnchanged: Bool { hidden.isEmpty }
}

/// Strips personal details from text on this device, before anything is
/// sent to a cloud model.
///
/// It hides names the person's notes mention, emails, phone numbers, street
/// addresses and postal codes, card-like numbers, and every word or phrase
/// the person marked private. Each becomes a mask such as `[name]`, so the
/// sentence still reads. It favors hiding too much over missing something,
/// but ordinary words, times, prices and short numbers stay as they are.
public struct Redactor: Sendable, Equatable {
    /// Names to hide, matched as whole words in any case.
    public let names: [String]
    /// Words and phrases the person marked private, matched in any case.
    public let privateWords: [String]

    public init(names: [String] = [], privateWords: [String] = []) {
        self.names = Self.tidy(names)
        self.privateWords = Self.tidy(privateWords)
    }

    /// Hides the names found in `notes` and the words the person marked
    /// private. The notes themselves are only read here, on this device.
    public init(memory notes: [MemoryNote], privateWords: [String] = []) {
        self.init(names: Self.names(in: notes), privateWords: privateWords)
    }

    public func redact(_ text: String) -> Redaction {
        let source = text as NSString
        var claimed: [(range: NSRange, kind: Redaction.Kind)] = []
        for kind in Redaction.Kind.allCases {
            for range in matches(of: kind, in: text) {
                // The first kind to claim a stretch of text keeps it.
                guard !claimed.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                claimed.append((range, kind))
            }
        }
        guard !claimed.isEmpty else { return Redaction(text: text) }
        claimed.sort { $0.range.location < $1.range.location }
        var out = ""
        var cursor = 0
        var hidden: [Redaction.Kind: Int] = [:]
        for (range, kind) in claimed {
            out += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += kind.mask
            cursor = range.location + range.length
            hidden[kind, default: 0] += 1
        }
        out += source.substring(from: cursor)
        return Redaction(text: out, hidden: hidden)
    }

    // MARK: Finding each kind

    private func matches(of kind: Redaction.Kind, in text: String) -> [NSRange] {
        switch kind {
        case .privateWord: return Self.wholeWords(privateWords, in: text)
        // "Sam's" becomes "[name]'s", so the sentence still reads.
        case .name: return Self.wholeWords(names, in: text)
        case .email: return Self.find(Self.email, in: text)
        case .card: return Self.find(Self.card, in: text)
        case .phone: return Self.find(Self.phone, in: text)
        case .address: return Self.find(Self.street, in: text).filter { Self.isStreet($0, in: text) }
            + Self.find(Self.postalCode, in: text)
        }
    }

    private static let email = regex(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
    /// 13 to 19 digits, as card numbers are, with spaces or dashes between.
    /// A comma or full stop after it is punctuation, unless a digit follows.
    private static let card = regex(#"(?<!\d)(?<!\d[.,])\d(?:[ \-]?\d){12,18}(?!\d)(?![.,]\d)"#)
    /// Ten digit numbers with or without separators and a leading 1, numbers
    /// starting with a plus and a country code, and seven digit local numbers
    /// written with a dash or dot.
    private static let phone = regex(
        #"(?<![\w.])(?:\+\d{1,3}[ .\-]?(?:\(\d{1,4}\)[ .\-]?)?\d{1,4}(?:[ .\-]?\d{2,4}){2,4}"#
        + #"|(?:1[ .\-]?)?(?:\(\d{3}\)[ .\-]?|\d{3}[ .\-]?)\d{3}[ .\-]?\d{4}"#
        + #"|\d{3}[.\-]\d{4})(?![\w])"#
    )
    /// A house number, one to four words, and a street word.
    private static let street = regex(
        #"\b\d{1,6}[A-Za-z]?\s+((?:[A-Za-z][A-Za-z'.\-]*\s+){1,4})"#
        + #"(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Place|Pl"#
        + #"|Terrace|Crescent|Cres|Parkway|Pkwy|Circle|Highway|Hwy|Square|Sq)\b"#
        + #"(?:,?\s*(?:Apt|Apartment|Unit|Suite|#)\.?\s*\w+)?"#,
        caseInsensitive: true
    )
    /// Canadian and British style postal codes, like M5V 2T6 or SW1A 1AA.
    private static let postalCode = regex(#"\b(?:[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})\b"#)

    /// Words that make "5 blocks down the road" a distance, not an address.
    private static let notStreetWords: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "this", "that", "down", "up",
        "along", "on", "off", "to", "from", "of", "at", "in", "by", "past", "near", "more", "or", "and",
        "block", "blocks", "mile", "miles", "km", "minutes", "min", "steps", "times", "other", "different",
    ]

    private static func isStreet(_ range: NSRange, in text: String) -> Bool {
        guard let match = street.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return false }
        let words = (text as NSString).substring(with: match.range(at: 1))
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        return !words.contains(where: notStreetWords.contains)
    }

    // MARK: Names in notes

    /// Capitalized words in the notes that read as names: anywhere but the
    /// start of a sentence, or at the start when followed by 's. Months,
    /// days and other words that are capitalized anyway are left alone.
    public static func names(in notes: [MemoryNote]) -> [String] {
        var found: [String] = []
        for note in notes {
            let words = tokens(note.text)
            for (index, word) in words.enumerated() {
                let bare = word.text.replacingOccurrences(of: "\u{2019}", with: "'")
                let possessive = bare.hasSuffix("'s")
                let name = possessive ? String(bare.dropLast(2)) : bare
                guard looksLikeName(name) else { continue }
                let startsSentence = index == 0 || words[index - 1].endsSentence
                guard !startsSentence || possessive else { continue }
                if !found.contains(name) { found.append(name) }
            }
        }
        return found
    }

    private static func looksLikeName(_ word: String) -> Bool {
        guard word.count >= 2, let first = word.first, first.isUppercase else { return false }
        guard word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "-" }) else { return false }
        return !capitalizedAnyway.contains(word.lowercased())
    }

    private static let capitalizedAnyway: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thurs", "fri", "sat", "sun",
        "today", "tomorrow", "tonight", "yesterday", "christmas", "easter", "halloween",
        "thanksgiving", "i", "im", "ive", "calendar", "mom", "dad", "mum", "the", "and",
    ]

    private struct Token { let text: String; let endsSentence: Bool }

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let endsSentence = raw.last.map { ".!?:;".contains($0) } ?? false
            let trimmed = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'\u{2019}-")))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}()"))
            return trimmed.isEmpty ? nil : Token(text: trimmed, endsSentence: endsSentence)
        }
    }

    // MARK: Matching

    private static func tidy(_ words: [String]) -> [String] {
        var seen: [String] = []
        for word in words {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(where: { $0.lowercased() == clean.lowercased() }) else { continue }
            seen.append(clean)
        }
        return seen
    }

    /// Whole word matches in any case. Longer words go first, so a private
    /// "lemon cake" wins over a private "lemon".
    private static func wholeWords(_ words: [String], in text: String) -> [NSRange] {
        let sorted = words.sorted { $0.count > $1.count }
        var ranges: [NSRange] = []
        for word in sorted {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
            for range in find(regex(pattern, caseInsensitive: true), in: text)
            where !ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func find(_ expression: NSRegularExpression, in text: String) -> [NSRange] {
        expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are fixed or escaped, so they always compile.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
