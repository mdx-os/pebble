import Foundation

/// Turns fetched page text into something that can be diffed tomorrow.
///
/// Ratings and relative dates change even when the product did not, so they
/// are removed. Absolute dates, version numbers, and the words of a note stay.
public enum SnapshotText {
    public static let defaultLimit = 200_000

    public static func normalize(_ raw: String, limit: Int = defaultLimit) -> String {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{2014}", with: " - ")
            .replacingOccurrences(of: "\u{2013}", with: " - ")
            .replacingOccurrences(of: "\u{2012}", with: "-")

        let relative = compile(Self.relativeDatePatterns)
        let ratings = compile(Self.ratingPatterns)
        let volatile = compile(Self.volatileLinePatterns)

        var kept: [String] = []
        for line in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            if let cleaned = cleanLine(String(line), relative: relative, ratings: ratings, volatile: volatile) {
                kept.append(cleaned)
            }
        }
        while kept.last?.isEmpty == true {
            kept.removeLast()
        }
        var text = kept.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if text.count > limit {
            let end = text.index(text.startIndex, offsetBy: limit)
            text = String(text[..<end]) + "\n[truncated]"
        }
        return text
    }

    private static let relativeDatePatterns = [
        #"\b\d+\s*[smhdw]\s*ago\b"#,
        #"\b\d+\s+(?:seconds?|minutes?|hours?|hrs?|days?|weeks?|months?|years?)\s+ago\b"#,
        #"\b(?:an?|one)\s+(?:second|minute|hour|day|week|month|year)\s+ago\b"#,
        #"\byesterday\b"#,
        #"\bjust now\b"#,
        #"\blast\s+(?:night|week|month|year)\b"#,
    ]

    private static let ratingPatterns = [
        #"\b\d+(?:\.\d+)?\s*(?:out of\s*5|/\s*5)\b"#,
        #"\b\d[\d,]*(?:\.\d+)?\s*[kKmM]?\s+(?:ratings?|reviews?)\b"#,
        #"\brated\s+\d+(?:\.\d+)?\b"#,
        #"[\u{2605}\u{2606}\u{2B50}]{2,}"#,
    ]

    private static let volatileLinePatterns = [
        #"^\s*last updated\b.*$"#,
        #"^\s*\d[\d,]*\s+release notes\s*$"#,
        #"^\s*curated from\s+\d[\d,]*\s+sources\b.*$"#,
    ]

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }

    private static func cleanLine(
        _ line: String,
        relative: [NSRegularExpression],
        ratings: [NSRegularExpression],
        volatile: [NSRegularExpression]
    ) -> String? {
        let whole = NSRange(line.startIndex..<line.endIndex, in: line)
        if volatile.contains(where: { $0.firstMatch(in: line, range: whole) != nil }) {
            return nil
        }
        var text = line
        for pattern in relative + ratings {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        text = tidy(text)
        if text.range(of: #"^\d[\d,]*(?:\.\d+)?\s*[kKmM]?$"#, options: .regularExpression) != nil {
            return nil
        }
        let hasLetter = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let isCalendarDay = text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        if !hasLetter, !isCalendarDay {
            return nil
        }
        return text
    }

    private static func tidy(_ line: String) -> String {
        var text = line
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        let junk = CharacterSet(charactersIn: " \t|·•")
        while let scalar = text.unicodeScalars.last, junk.contains(scalar) {
            text.unicodeScalars.removeLast()
        }
        while let scalar = text.unicodeScalars.first, junk.contains(scalar) {
            text.unicodeScalars.removeFirst()
        }
        return text
    }
}
