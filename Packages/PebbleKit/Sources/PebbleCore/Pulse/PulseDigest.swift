import Foundation

/// The file the morning run writes. Cards may be empty until a later step fills them.
public struct PulseDigest: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Equatable, Codable {
            case new
            case changed
            case unchanged
            case failed
            case skipped
        }

        public var sourceID: String
        public var title: String
        public var url: URL?
        public var status: Status
        /// Repo-relative snapshot path when a snapshot exists.
        public var snapshotPath: String?
        /// Diff or new text for a real change. Empty when nothing changed.
        /// A short reason for a failure or a skip.
        public var detail: String

        public init(
            sourceID: String,
            title: String,
            url: URL?,
            status: Status,
            snapshotPath: String?,
            detail: String
        ) {
            self.sourceID = sourceID
            self.title = title
            self.url = url
            self.status = status
            self.snapshotPath = snapshotPath
            self.detail = detail
        }

        public var isChange: Bool {
            status == .new || status == .changed
        }
    }

    public static let previewLineLimit = 40
    public static let modelInputCharacterLimit = 8_000

    public var generatedAt: Date
    public var entries: [Entry]
    public var cards: [StealCard]

    public init(generatedAt: Date, entries: [Entry], cards: [StealCard]) {
        self.generatedAt = generatedAt
        self.entries = entries
        self.cards = cards
    }

    /// Text a later model step may read. Unchanged, failed, and skipped sources are left out.
    public var modelInput: String {
        entries.compactMap { entry -> String? in
            guard entry.isChange else { return nil }
            let body = Self.bounded(entry.detail, limit: Self.modelInputCharacterLimit)
            return "### \(entry.title)\n\n\(body)"
        }.joined(separator: "\n\n")
    }

    public func markdown() -> String {
        let changed = entries.filter(\.isChange)
        let unchanged = entries.filter { $0.status == .unchanged }
        let skipped = entries.filter { $0.status == .skipped }
        let failed = entries.filter { $0.status == .failed }

        var lines: [String] = []
        lines.append("# Pulse")
        lines.append("")
        lines.append("Generated: \(PulseTime.stamp(generatedAt))")
        lines.append("")
        lines.append("Changes worth reading: \(changed.count)")
        lines.append("Unchanged: \(unchanged.count)")
        lines.append("Skipped: \(skipped.count)")
        lines.append("Failed: \(failed.count)")
        lines.append("")

        if !changed.isEmpty {
            lines.append("## Changes")
            lines.append("")
            for entry in changed {
                lines.append("### \(entry.title)")
                lines.append("")
                lines.append("Status: \(entry.status.rawValue)")
                if let url = entry.url {
                    lines.append("Source: \(url.absoluteString)")
                }
                if let path = entry.snapshotPath {
                    lines.append("Snapshot: \(path)")
                }
                lines.append("")
                let preview = Self.preview(entry.detail)
                if !preview.isEmpty {
                    lines.append(preview)
                    lines.append("")
                }
            }
        }

        if !unchanged.isEmpty {
            lines.append("## Unchanged")
            lines.append("")
            for entry in unchanged {
                lines.append("- \(entry.title)")
            }
            lines.append("")
        }

        if !skipped.isEmpty {
            lines.append("## Skipped")
            lines.append("")
            for entry in skipped {
                lines.append("### \(entry.title)")
                lines.append("")
                lines.append(entry.detail)
                lines.append("")
            }
        }

        if !failed.isEmpty {
            lines.append("## Failed")
            lines.append("")
            for entry in failed {
                lines.append("### \(entry.title)")
                lines.append("")
                lines.append(entry.detail)
                lines.append("")
            }
        }

        lines.append("## Steal cards")
        lines.append("")
        if cards.isEmpty {
            lines.append(
                "None yet. Cards are written from the changes above. Each card names a pattern to copy, not a brand and not code."
            )
        } else {
            for card in cards {
                lines.append(card.markdown())
                lines.append("")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func preview(_ text: String) -> String {
        let all = LineDiff.lines(of: text)
        if all.count <= previewLineLimit {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = all.prefix(previewLineLimit).joined(separator: "\n")
        return head + "\n[truncated]"
    }

    public static func bounded(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n[truncated]"
    }
}

public enum PulseTime {
    public static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func day(_ date: Date, addingDays: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let shifted = calendar.date(byAdding: .day, value: addingDays, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
