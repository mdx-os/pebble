import Foundation

/// Turns the competitor-watch digest text into idea cards.
///
/// The only input is `modelInput`. Snapshots, pages, and ratings that never
/// reached that text cannot become a card.
public enum IdeaDraft {
    public static func cards(from modelInput: String) -> [IdeaCard] {
        sections(in: modelInput).compactMap(card(from:))
    }

    private struct Section {
        var id: String
        var name: String
        var url: String
        var body: String
    }

    private static func card(from section: Section) -> IdeaCard? {
        let lines = substantiveLines(in: section.body)
        guard !lines.isEmpty else { return nil }
        guard let url = URL(string: section.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let summary = clip(lines.joined(separator: " "), limit: 500)
        guard !summary.isEmpty else { return nil }
        let pattern = patternWorthTaking(from: summary)
        return IdeaCard(
            id: stableID(source: section.id, summary: summary),
            title: title(from: summary),
            summary: summary,
            sourceName: section.name,
            sourceURL: url,
            complaint: complaint(from: lines),
            pattern: pattern,
            effort: effort(for: summary),
            fit: fit(for: summary)
        )
    }

    /// Added lines from a diff, or the note text from a first snapshot.
    /// Version labels, dates, and screenshot URLs are not the idea.
    private static func substantiveLines(in body: String) -> [String] {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let isDiff = lines.contains { line in
            line.hasPrefix("@@") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
        }
        var kept: [String] = []
        for line in lines {
            let text: String
            if isDiff {
                guard line.hasPrefix("+"), !line.hasPrefix("+++") else { continue }
                text = String(line.dropFirst())
            } else {
                text = line
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isMetadata(trimmed) || isURL(trimmed) { continue }
            if !trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { continue }
            kept.append(trimmed)
        }
        return kept
    }

    private static func isMetadata(_ line: String) -> Bool {
        let lower = line.lowercased()
        let prefixes = [
            "name:", "seller:", "version:", "released:", "screenshots:",
            "headline:", "published:", "source:", "url:",
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private static func isURL(_ line: String) -> Bool {
        line.hasPrefix("http://") || line.hasPrefix("https://")
    }

    private static func complaint(from lines: [String]) -> String {
        let pattern = #"\b(crash(?:es|ed)?|bugs?|cannot|can't|fails|failed|failure|errors?|slow|stuck|waiting|broken)\b"#
        for line in lines {
            if line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return clip(line, limit: 240)
            }
        }
        return "The source does not say what problem this answers."
    }

    /// The behavior, with product names removed.
    private static func patternWorthTaking(from summary: String) -> String {
        let brands = #"\b(?:muse|grok|chatgpt|openai|meta|codex|releasebot|whatsapp|instagram)\b"#
        var text = summary
        if let regex = try? NSRegularExpression(pattern: brands, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:-")))
        if text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            return clip(text, limit: 500)
        }
        return "A behavior described in the source."
    }

    private static func effort(for summary: String) -> IdeaEffort {
        if summary.count < 280 { return .small }
        if summary.count < 1_200 { return .medium }
        return .large
    }

    private static func fit(for summary: String) -> IdeaFit {
        let lower = summary.lowercased()
        let personal = ["email", "calendar", "health", "finance", "contacts", "photos", "messages"]
        let mentionsPersonal = personal.contains { lower.contains($0) }
        let connects = lower.contains("link your") || lower.contains("connect your") || lower.contains("upload")
        let leavesDevice = lower.contains("cloud data storage")
            || lower.contains("on our servers")
            || lower.contains("requires cloud")
            || (connects && mentionsPersonal)
        let cloudOnly = lower.contains("requires cloud")
            || lower.contains("cloud only")
            || lower.contains("cloud data storage")
        let closed = lower.contains("proprietary model") || lower.contains("closed model")
        let open = lower.contains("open weight") || lower.contains("open-weight")
        return IdeaFit(
            privacy: leavesDevice ? 0 : 2,
            localFirst: cloudOnly ? 0 : 2,
            openWeights: closed ? 0 : (open ? 3 : 2)
        )
    }

    private static func title(from summary: String) -> String {
        let sentence = summary.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? summary
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 72 { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 72)
        var cut = String(trimmed[..<end])
        if let space = cut.lastIndex(of: " "), space != cut.startIndex {
            cut = String(cut[..<space])
        }
        return cut
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func stableID(source: String, summary: String) -> String {
        var hash: UInt32 = 5381
        for byte in Data((source + "\n" + summary).utf8) {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        return "\(source)-\(String(hash, radix: 16, uppercase: false))"
    }

    private static func sections(in modelInput: String) -> [Section] {
        let lines = modelInput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [Section] = []
        var index = 0
        while index < lines.count {
            guard isHeader(lines, at: index) else {
                index += 1
                continue
            }
            let id = value(lines[index], label: "source: ")
            let name = value(lines[index + 1], label: "name: ")
            let url = value(lines[index + 2], label: "url: ")
            index += 3
            if index < lines.count, lines[index].isEmpty { index += 1 }
            var body: [String] = []
            while index < lines.count, !isHeader(lines, at: index) {
                body.append(lines[index])
                index += 1
            }
            sections.append(Section(id: id, name: name, url: url, body: body.joined(separator: "\n")))
        }
        return sections
    }

    private static func isHeader(_ lines: [String], at index: Int) -> Bool {
        guard index + 2 < lines.count else { return false }
        return lines[index].hasPrefix("source: ")
            && lines[index + 1].hasPrefix("name: ")
            && lines[index + 2].hasPrefix("url: ")
    }

    private static func value(_ line: String, label: String) -> String {
        String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
}
