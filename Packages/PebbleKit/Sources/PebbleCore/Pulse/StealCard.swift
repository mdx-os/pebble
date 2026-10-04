import Foundation

/// One idea worth taking from a real change.
///
/// `what` says what the change is. `pattern` is the behavior to copy. It names
/// a behavior, not a brand and not code. `complaint` is the user problem it
/// solves. A privacy fit of 0 means adapt the idea or reject it.
public struct StealCard: Sendable, Equatable, Codable, Identifiable {
    public enum Effort: String, Sendable, Equatable, Codable, CaseIterable {
        case small
        case medium
        case large
    }

    public var id: String
    public var what: String
    public var sourceID: String
    public var sourceTitle: String
    public var sourceURL: URL?
    public var complaint: String
    public var pattern: String
    public var effort: Effort
    public var fit: PrincipleFit

    public init(
        id: String,
        what: String,
        sourceID: String,
        sourceTitle: String,
        sourceURL: URL?,
        complaint: String,
        pattern: String,
        effort: Effort,
        fit: PrincipleFit
    ) throws {
        let fields = [
            ("id", id),
            ("what", what),
            ("source", sourceID),
            ("source title", sourceTitle),
            ("complaint", complaint),
            ("pattern", pattern),
        ]
        for (name, value) in fields {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PulseError(message: "A steal card needs a \(name).")
            }
        }
        self.id = id
        self.what = what
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.complaint = complaint
        self.pattern = pattern
        self.effort = effort
        self.fit = fit
    }

    public func markdown() -> String {
        var lines = [
            "### \(what)",
            "",
            "Source: \(sourceTitle) (\(sourceID))",
        ]
        if let sourceURL {
            lines.append("Link: \(sourceURL.absoluteString)")
        }
        lines.append("Complaint: \(complaint)")
        lines.append("Pattern: \(pattern)")
        lines.append("Effort: \(effort.rawValue)")
        lines.append("Privacy: \(fit.label(for: fit.privacy))")
        lines.append("Local first: \(fit.label(for: fit.localFirst))")
        lines.append("Open weights: \(fit.label(for: fit.openWeights))")
        return lines.joined(separator: "\n")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            what: try container.decode(String.self, forKey: .what),
            sourceID: try container.decode(String.self, forKey: .sourceID),
            sourceTitle: try container.decode(String.self, forKey: .sourceTitle),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            complaint: try container.decode(String.self, forKey: .complaint),
            pattern: try container.decode(String.self, forKey: .pattern),
            effort: try container.decode(Effort.self, forKey: .effort),
            fit: try container.decode(PrincipleFit.self, forKey: .fit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(what, forKey: .what)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceTitle, forKey: .sourceTitle)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(complaint, forKey: .complaint)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(effort, forKey: .effort)
        try container.encode(fit, forKey: .fit)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case what
        case sourceID
        case sourceTitle
        case sourceURL
        case complaint
        case pattern
        case effort
        case fit
    }
}
