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

        /// What VoiceOver says for the mask, so "[name]" is heard as
        /// "hidden name", not as brackets.
        public var spoken: String {
            switch self {
            case .privateWord: "hidden private word"
            case .email: "hidden email"
            case .card: "hidden card number"
            case .phone: "hidden phone number"
            case .address: "hidden address"
            case .name: "hidden name"
            }
        }

        /// `text` with every mask replaced by its spoken words.
        public static func spoken(_ text: String) -> String {
            allCases.reduce(text) { $0.replacingOccurrences(of: $1.mask, with: $1.spoken) }
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
/// It is a best effort, not a guarantee: the preview the person reads
/// before anything is sent is the real safeguard.
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
            + Self.find(Self.nationalPhone, in: text).filter { (10...11).contains(Self.digits(in: $0, of: text)) }
        case .address: return Self.find(Self.street, in: text).filter { Self.isStreet($0, in: text) }
            + Self.find(Self.streetNameAfter, in: text)
            + Self.find(Self.postalCode, in: text).filter { !Self.readsAsWords($0, in: text) }
            + Self.find(Self.zip, in: text)
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
    /// Numbers written the way most countries outside North America write
    /// them at home, starting with 0: 020 7946 0958, 07700 900123,
    /// 01 23 45 67 89. Only 10 or 11 digits count, so dates stay.
    private static let nationalPhone = regex(#"(?<![\w.+])\(?0\d{1,4}\)?(?:[ .\-]?\d{2,4}){1,5}(?![\w])"#)
    /// A house number, one to four words, and a street word.
    private static let street = regex(
        #"\b\d{1,6}[A-Za-z]?\s+((?:[A-Za-z][A-Za-z'’.\-]*\s+){1,4})"#
        + #"(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Place|Pl"#
        + #"|Terrace|Crescent|Cres|Parkway|Pkwy|Circle|Highway|Hwy|Square|Sq)\b"#
        + #"(?:,?\s*(?:Apt|Apartment|Unit|Suite|#)\.?\s*\w+)?"#,
        caseInsensitive: true
    )
    /// A house number and a street word that comes before the name, as in
    /// 1 Avenue of the Americas or 12 Rue de la Paix. The name is capitalized.
    private static let streetNameAfter = regex(
        #"\b\d{1,6}[A-Za-z]?\s+(?i:Avenue|Ave|Boulevard|Blvd|Rue|Calle|Avenida|Via)\.?"#
        + #"\s+(?:(?:of|the|de|la|le|del|des|du)\s+){0,3}\p{Lu}[\p{L}'’\-]*(?:\s+\p{Lu}[\p{L}'’\-]*){0,2}"#
    )
    /// Canadian and British style postal codes, like M5V 2T6 or SW1A 1AA, in
    /// any case.
    private static let postalCode = regex(
        #"\b(?:[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})\b"#,
        caseInsensitive: true
    )
    /// US ZIP+4 codes, and five digit ZIP codes after a state, like NY 10001.
    private static let zip = regex(
        #"\b(?:(?:AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH"#
        + #"|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY),?\s+\d{5}(?:-\d{4})?|\d{5}-\d{4})\b"#
    )

    /// Words that make "5 blocks down the road" a distance, not an address.
    private static let distanceWords: Set<String> = [
        "block", "blocks", "mile", "miles", "km", "minutes", "min", "steps", "times", "hours", "doors",
    ]
    /// Words that never begin a street's name: "3 of the main roads".
    private static let notStreetStarts: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "this", "that", "down", "up",
        "along", "on", "off", "to", "from", "of", "at", "in", "by", "past", "near", "more", "or", "and",
        "other", "different",
    ]

    /// "1 Lord of the Isles Road" is a street; "5 blocks down the road" and
    /// "3 of the main roads" are not.
    private static func isStreet(_ range: NSRange, in text: String) -> Bool {
        guard let match = street.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return false }
        let words = (text as NSString).substring(with: match.range(at: 1))
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        guard let first = words.first, !notStreetStarts.contains(first) else { return false }
        return !words.contains(where: distanceWords.contains)
    }

    /// "b4 1pm" and "a1 2nd" are words and times, not postal codes. Codes
    /// written in capitals always count.
    private static func readsAsWords(_ range: NSRange, in text: String) -> Bool {
        let found = (text as NSString).substring(with: range)
        guard found == found.lowercased() else { return false }
        return ["st", "nd", "rd", "th", "am", "pm"].contains { found.hasSuffix($0) }
    }

    private static func digits(in range: NSRange, of text: String) -> Int {
        (text as NSString).substring(with: range).filter(\.isNumber).count
    }

    // MARK: Names in notes

    /// Words in the notes that read as names:
    /// - a capitalized word anywhere but the start of a sentence,
    /// - at the start, when followed by 's or by words like "is" and
    ///   "loves" ("Priya is my sister.", "Sam loves lemon cake."),
    /// - any word, even in lowercase, right after "my sister", "our friend"
    ///   and the like, or after "named".
    /// Names like O'Brien, McDonald, DeShawn and Anne-Marie count. Months,
    /// days and other words that are capitalized anyway are left alone.
    public static func names(in notes: [MemoryNote]) -> [String] {
        var found: [String] = []
        func add(_ name: String) {
            if !found.contains(where: { $0.lowercased() == name.lowercased() }) { found.append(name) }
        }
        for note in notes {
            let words = tokens(note.text)
            for (index, word) in words.enumerated() {
                var name = word.text
                var possessive = false
                if name.hasSuffix("'s") {
                    name = String(name.dropLast(2))
                    possessive = true
                } else if name.hasSuffix("'") {
                    name = String(name.dropLast())
                    possessive = true
                }
                guard !name.isEmpty else { continue }
                let previous = index > 0 ? words[index - 1] : nil
                if let previous, !previous.endsSentence, followsRelation(words, at: index), isWordLike(name),
                   !notNames.contains(name.lowercased()) {
                    add(name)
                    continue
                }
                guard looksLikeName(name) else { continue }
                let startsSentence = previous?.endsSentence ?? true
                if !startsSentence || possessive {
                    add(name)
                } else if !word.endsSentence, index + 1 < words.count,
                          nameFollowers.contains(words[index + 1].text.lowercased()),
                          !notNames.contains(name.lowercased()) {
                    add(name)
                }
            }
        }
        return found
    }

    /// True when the word at `index` follows "my sister", "her friend",
    /// "named" and the like.
    private static func followsRelation(_ words: [Token], at index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = words[index - 1].text.lowercased()
        if previous == "named" { return true }
        guard index > 1, relations.contains(previous), !words[index - 2].endsSentence else { return false }
        return owners.contains(words[index - 2].text.lowercased())
    }

    private static let owners: Set<String> = ["my", "our", "your", "his", "her", "their"]

    private static let relations: Set<String> = [
        "sister", "brother", "wife", "husband", "partner", "boyfriend", "girlfriend", "fiance", "fiancee",
        "son", "daughter", "aunt", "uncle", "cousin", "niece", "nephew", "grandma", "grandpa",
        "grandmother", "grandfather", "friend", "bestie", "boss", "coworker", "colleague", "roommate",
        "neighbor", "neighbour", "stepson", "stepdaughter", "stepmom", "stepdad",
    ]

    /// Words that, after a name at the start of a sentence, show it is the
    /// one doing or being something.
    private static let nameFollowers: Set<String> = [
        "is", "was", "and", "loves", "likes", "lives", "works", "has", "had", "hates", "prefers", "wants",
        "needs", "said", "says", "will", "can", "can't", "won't", "doesn't", "isn't", "wasn't", "just",
        "always", "never", "also", "really", "plays", "goes", "gets", "turns", "turned", "studies",
        "moved", "started", "texted", "called", "asked", "told", "teaches", "drives", "takes", "eats",
        "drinks", "owes", "visits", "joined", "left", "got", "went", "came", "comes",
    ]

    /// Words that are never taken as names, even where a name could be.
    private static let notNames: Set<String> = capitalizedAnyway.union([
        "is", "was", "and", "or", "but", "so", "also", "just", "really", "always", "never", "too", "who",
        "has", "had", "have", "loves", "likes", "lives", "works", "said", "says", "will", "can", "from",
        "at", "in", "on", "to", "for", "with", "of", "a", "an", "my", "our", "your", "his", "her", "their",
        "its", "it", "that", "this", "these", "those", "there", "here", "he", "she", "they", "we", "you",
        "me", "him", "them", "us", "what", "when", "where", "why", "how", "every", "each", "all",
        "everyone", "someone", "somebody", "nobody", "group", "chat", "dinner", "lunch", "breakfast",
        "meeting", "appointment", "party", "birthday", "anniversary", "dentist", "doctor", "gym", "work",
        "school", "class", "practice", "flight", "trip", "rent", "car", "house", "home", "coffee", "tea",
        "it's", "that's", "there's", "he's", "she's", "who's", "what's", "let's",
    ])

    /// Each part after the first starts with a capital, an apostrophe or a
    /// hyphen, so the pattern never has two ways to read the same word.
    private static let nameShape = regex(#"^\p{Lu}\p{Ll}*(?:(?:['\-]\p{Lu}?|\p{Lu})\p{Ll}+)*$"#)

    /// Sam, O'Brien, McDonald, DeShawn, Anne-Marie. Not NASA, not "I'm".
    private static func looksLikeName(_ word: String) -> Bool {
        guard word.count >= 2, word.contains(where: \.isLowercase) else { return false }
        guard nameShape.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil
        else { return false }
        return !capitalizedAnyway.contains(word.lowercased())
    }

    /// Letters, with an apostrophe or hyphen inside: "priya", "o'brien".
    private static func isWordLike(_ word: String) -> Bool {
        word.count >= 2 && word.first?.isLetter == true && word.last?.isLetter == true
            && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
    }

    private static let capitalizedAnyway: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thurs", "fri", "sat", "sun",
        "today", "tomorrow", "tonight", "yesterday", "christmas", "easter", "halloween",
        "thanksgiving", "i", "im", "ive", "i'm", "i've", "i'll", "i'd", "calendar", "mom", "dad", "mum",
        "the", "and",
    ]

    private struct Token { let text: String; let endsSentence: Bool }

    /// Words with surrounding punctuation trimmed and every apostrophe made
    /// straight, so "Sam’s" and "Sam's" read the same.
    private static func tokens(_ text: String) -> [Token] {
        straightApostrophes(text).split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let endsSentence = raw.last.map { ".!?:;".contains($0) } ?? false
            let trimmed = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}()"))
            let word = trimmed.hasPrefix("'") ? String(trimmed.dropFirst()) : trimmed
            return word.isEmpty ? nil : Token(text: word, endsSentence: endsSentence)
        }
    }

    // MARK: Matching

    private static let apostrophes = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    private static func straightApostrophes(_ text: String) -> String {
        apostrophes.reduce(text) { $0.replacingOccurrences(of: $1, with: "'") }
    }

    private static func tidy(_ words: [String]) -> [String] {
        var seen: [String] = []
        for word in words {
            let clean = straightApostrophes(word).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(where: { $0.lowercased() == clean.lowercased() }) else { continue }
            seen.append(clean)
        }
        return seen
    }

    /// Whole word matches in any case, with straight and curly apostrophes
    /// alike. Longer words go first, so a private "lemon cake" wins over a
    /// private "lemon".
    private static func wholeWords(_ words: [String], in text: String) -> [NSRange] {
        let sorted = words.sorted { $0.count > $1.count }
        var ranges: [NSRange] = []
        for word in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: word)
                .replacingOccurrences(of: "'", with: "['\u{2019}\u{2018}\u{02BC}]")
            let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
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
