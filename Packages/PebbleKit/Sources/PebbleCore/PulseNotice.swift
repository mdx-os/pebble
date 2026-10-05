import Foundation

/// A short notice for a later notification step.
///
/// Written only when the digest has a real change: a source whose text
/// changed, an idea card, or model input. A quiet run deletes a notice
/// left behind by the previous run.
public enum PulseNotice {
    public static let markdownFilename = "notify.md"
    public static let summaryFilename = "summary.json"

    public static func hasRealChanges(_ digest: PulseDigest) -> Bool {
        if digest.observations.contains(where: { $0.outcome == .changed }) {
            return true
        }
        return !digest.modelInput.isEmpty || !digest.ideaCards.isEmpty
    }

    /// Writes `notify.md` and `summary.json` when `digest` has real changes.
    /// Removes both when it does not. Returns the markdown file when one was written.
    @discardableResult
    public static func write(_ digest: PulseDigest, to directory: URL) throws -> URL? {
        let markdownURL = directory.appendingPathComponent(markdownFilename)
        let summaryURL = directory.appendingPathComponent(summaryFilename)
        guard hasRealChanges(digest), let summary = PulseNoticeSummary(digest) else {
            try removeIfPresent(markdownURL)
            try removeIfPresent(summaryURL)
            return nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(markdown(for: digest).utf8).write(to: markdownURL, options: .atomic)
        try summary.json().write(to: summaryURL, options: .atomic)
        return markdownURL
    }

    public static func markdown(for digest: PulseDigest) -> String {
        guard hasRealChanges(digest) else { return "" }
        var lines: [String] = [
            "# Competitor watch",
            "",
            timestamp(digest.generatedAt),
            "",
            counts(digest),
            "",
        ]
        if !digest.ideaCards.isEmpty {
            lines.append("## Idea cards")
            lines.append("")
            for (index, card) in digest.ideaCards.enumerated() {
                if index > 0 { lines.append("") }
                lines.append(contentsOf: cardLines(card))
            }
            lines.append("")
        } else if !digest.modelInput.isEmpty {
            lines.append("## What changed")
            lines.append("")
            lines.append(excerpt(digest.modelInput))
            lines.append("")
        }
        let changed = digest.observations.filter { $0.outcome == .changed }
        if !changed.isEmpty {
            lines.append("## Changed sources")
            lines.append("")
            for observation in changed {
                lines.append("- \(observation.name) (\(observation.id)): \(observation.url)")
                if let detail = observation.detail, !detail.isEmpty {
                    lines.append("  \(detail)")
                }
            }
            lines.append("")
        }
        lines.append("Full digest: pulse/digest.json")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cardLines(_ card: IdeaCard) -> [String] {
        [
            "### \(oneLine(card.title))",
            "",
            "Source: \(oneLine(card.sourceName))",
            card.sourceURL.absoluteString,
            "",
            card.summary,
            "",
            card.complaint,
            "",
            "Pattern: \(card.pattern)",
            "Effort: \(card.effort.rawValue)",
            fitLine(card.fit),
        ]
    }

    private static func fitLine(_ fit: IdeaFit) -> String {
        let privacy = fit.privacy == 0
            ? "Privacy: 0. Adapt this idea or leave it."
            : "Privacy: \(fit.privacy)."
        return "\(privacy) Local models: \(fit.localFirst). Open weights: \(fit.openWeights)."
    }

    private static func counts(_ digest: PulseDigest) -> String {
        let sources = digest.observations.filter { $0.outcome == .changed }.count
        let sourceText = sources == 1 ? "1 source changed" : "\(sources) sources changed"
        let cards = digest.ideaCards.count
        let cardText: String
        if cards == 0 {
            cardText = "No idea cards"
        } else if cards == 1 {
            cardText = "1 idea card"
        } else {
            cardText = "\(cards) idea cards"
        }
        return "\(sourceText). \(cardText)."
    }

    private static func excerpt(_ text: String) -> String {
        let limit = 2_000
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n\nThe rest is in the full digest."
    }

    private static func oneLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Machine-readable companion to `build/pulse/notify.md`.
public struct PulseNoticeSummary: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var changedSourceCount: Int
    public var ideaCardCount: Int
    public var changedSources: [ChangedSource]
    public var ideaCards: [Card]

    public struct ChangedSource: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var url: String
        public var detail: String?

        public init(id: String, name: String, url: String, detail: String? = nil) {
            self.id = id
            self.name = name
            self.url = url
            self.detail = detail
        }
    }

    public struct Card: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var summary: String
        public var sourceName: String
        public var sourceURL: String
        public var complaint: String
        public var pattern: String
        public var effort: String
        public var privacy: Int
        public var localFirst: Int
        public var openWeights: Int

        public init(
            id: String,
            title: String,
            summary: String,
            sourceName: String,
            sourceURL: String,
            complaint: String,
            pattern: String,
            effort: String,
            privacy: Int,
            localFirst: Int,
            openWeights: Int
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.sourceName = sourceName
            self.sourceURL = sourceURL
            self.complaint = complaint
            self.pattern = pattern
            self.effort = effort
            self.privacy = privacy
            self.localFirst = localFirst
            self.openWeights = openWeights
        }
    }

    public init(
        generatedAt: Date,
        changedSourceCount: Int,
        ideaCardCount: Int,
        changedSources: [ChangedSource],
        ideaCards: [Card]
    ) {
        self.generatedAt = generatedAt
        self.changedSourceCount = changedSourceCount
        self.ideaCardCount = ideaCardCount
        self.changedSources = changedSources
        self.ideaCards = ideaCards
    }

    init?(_ digest: PulseDigest) {
        guard PulseNotice.hasRealChanges(digest) else { return nil }
        let changed = digest.observations.filter { $0.outcome == .changed }
        self.init(
            generatedAt: digest.generatedAt,
            changedSourceCount: changed.count,
            ideaCardCount: digest.ideaCards.count,
            changedSources: changed.map {
                ChangedSource(id: $0.id, name: $0.name, url: $0.url, detail: $0.detail)
            },
            ideaCards: digest.ideaCards.map {
                Card(
                    id: $0.id,
                    title: $0.title,
                    summary: $0.summary,
                    sourceName: $0.sourceName,
                    sourceURL: $0.sourceURL.absoluteString,
                    complaint: $0.complaint,
                    pattern: $0.pattern,
                    effort: $0.effort.rawValue,
                    privacy: $0.fit.privacy,
                    localFirst: $0.fit.localFirst,
                    openWeights: $0.fit.openWeights
                )
            }
        )
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> PulseNoticeSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PulseNoticeSummary.self, from: data)
    }
}
