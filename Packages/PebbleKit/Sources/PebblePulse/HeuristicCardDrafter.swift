import Foundation
import PebbleCore

/// Drafts one steal card per changed source from the change text alone.
///
/// Themes are fixed sentences. The pattern names a behavior, not a product
/// and not code. A privacy score of 0 means adapt the idea or reject it.
public struct HeuristicCardDrafter: CardDrafting {
    public let name = "local"

    public init() {}

    public func draft(modelInput: String) async -> [StealCard] {
        sections(in: modelInput).compactMap(card(from:))
    }

    private struct Section {
        var title: String
        var body: String
    }

    private struct Theme {
        var id: String
        var needles: [String]
        var what: String
        var complaint: String
        var pattern: String
        var effort: StealCard.Effort
        var privacy: Int
        var localFirst: Int
        var openWeights: Int
    }

    /// First match wins, so a money or cloud change is not scored as a harmless fix.
    private static let themes: [Theme] = [
        Theme(
            id: "money",
            needles: ["financial", "financ", "bank account", "checkout", "credit card"],
            what: "The agent is being pointed at a person's spending and accounts.",
            complaint: "People want help with money without handing every account to an app.",
            pattern: "Answer money questions from figures the person types or imports on purpose, and ask before anything is spent or shared.",
            effort: .large,
            privacy: 0,
            localFirst: 0,
            openWeights: 1
        ),
        Theme(
            id: "connected-apps",
            needles: ["favorite apps", "your apps", "connect your", "sign in to", "other apps"],
            what: "The agent can work in more of the apps a person already uses.",
            complaint: "The useful work already lives in other apps, and copying it across by hand is the tedious part.",
            pattern: "Let the person connect only the apps they pick, with a separate permission for each one, and keep that data on device unless they agree to send it.",
            effort: .large,
            privacy: 0,
            localFirst: 1,
            openWeights: 2
        ),
        Theme(
            id: "cloud-data",
            needles: ["virtual machine", "in the cloud", "secure vm", "someone else's computer"],
            what: "The agent and the person's data are described as living on someone else's computer.",
            complaint: "A personal agent that keeps a person's life on someone else's computer is not private.",
            pattern: "Run the agent on the person's own device, and require a separate check before anything leaves that device.",
            effort: .large,
            privacy: 0,
            localFirst: 0,
            openWeights: 1
        ),
        Theme(
            id: "closed-model",
            needles: ["gpt-", "grok-", "end of life", "model retirement"],
            what: "A closed model is being retired or swapped for another closed model.",
            complaint: "When the model behind a task changes, people cannot tell what ran, and they cannot keep the task on their own device.",
            pattern: "Keep the default on an open model on device. If a task must move to another model, show the person which model ran.",
            effort: .medium,
            privacy: 1,
            localFirst: 0,
            openWeights: 0
        ),
        Theme(
            id: "forget",
            needles: ["forget"],
            what: "The person can tell the agent to forget something it stored.",
            complaint: "The agent keeps a detail the person wanted deleted.",
            pattern: "Let the person name a memory and delete it, and keep personal content out of the permanent log so deletion is real.",
            effort: .medium,
            privacy: 2,
            localFirst: 2,
            openWeights: 2
        ),
        Theme(
            id: "approval",
            needles: ["approval", "sentinel", "asks before", "audit trail", "before it sends"],
            what: "Something must agree before the agent acts.",
            complaint: "The agent acts before the person has a chance to say no.",
            pattern: "Show the plan first, and require a separate check before the agent sends, spends, or leaves the device.",
            effort: .medium,
            privacy: 2,
            localFirst: 2,
            openWeights: 2
        ),
        Theme(
            id: "background",
            needles: ["ongoing", "between conversations", "after you close", "keeps working", "on a schedule"],
            what: "A task is meant to keep going between conversations.",
            complaint: "Long tasks die when the person closes the app.",
            pattern: "Let the person hand off a task once, keep it going on a schedule they can stop, and ask before it sends or spends.",
            effort: .medium,
            privacy: 1,
            localFirst: 1,
            openWeights: 2
        ),
        Theme(
            id: "delegate",
            needles: ["useful task", "hand it", "first task", "create your first"],
            what: "The person is told to hand over one real task and check the result.",
            complaint: "People can describe a task and still have to do every step themselves.",
            pattern: "Let the person hand over one real task, review the result, and stop the task before it counts as done.",
            effort: .medium,
            privacy: 1,
            localFirst: 1,
            openWeights: 2
        ),
        Theme(
            id: "bugfix",
            needles: ["bug fix", "bug fixes", "performance", "improvements"],
            what: "The latest note is a reliability fix.",
            complaint: "The same small failure keeps interrupting a task.",
            pattern: "Treat a repeated failure as something to fix, and tell the person when a task is stuck instead of leaving it quiet.",
            effort: .small,
            privacy: 2,
            localFirst: 2,
            openWeights: 2
        ),
    ]

    private static let brands = [
        "ChatGPT", "OpenAI", "WhatsApp", "Instagram", "Facebook", "Codex",
        "Grok Bot", "Grok", "Cursor", "Stripe", "xAI", "Muse", "Meta",
    ]

    private func card(from section: Section) -> StealCard? {
        let lines = contentLines(section.body)
        guard let lead = lead(in: lines) else { return nil }
        let theme = Self.themes.first { theme in
            theme.needles.contains { lead.lowercased().contains($0) }
        }
        let sourceID = field("source:", in: lines) ?? slug(section.title)
        let sourceURL = field("url:", in: lines).flatMap { URL(string: $0) }
        let complaint: String
        let pattern: String
        let effort: StealCard.Effort
        let privacy: Int
        let localFirst: Int
        let openWeights: Int
        let themeID: String
        let what: String
        if let theme {
            themeID = theme.id
            what = theme.what
            complaint = theme.complaint
            pattern = theme.pattern
            effort = theme.effort
            privacy = theme.privacy
            localFirst = theme.localFirst
            openWeights = theme.openWeights
        } else {
            themeID = "behavior"
            what = sentence(sanitize(lead))
            complaint = "The source names a change and not the problem it solves for a person."
            pattern = "Copy the behavior only where it can run on device, on an open model, with a clear permission."
            effort = what.count < 80 ? .small : .medium
            privacy = 1
            localFirst = 1
            openWeights = 1
        }
        guard !what.isEmpty else { return nil }
        guard let fit = try? PrincipleFit(privacy: privacy, localFirst: localFirst, openWeights: openWeights) else {
            return nil
        }
        return try? StealCard(
            id: "\(sourceID)-\(themeID)",
            what: clip(what, limit: 180),
            sourceID: sourceID,
            sourceTitle: section.title,
            sourceURL: sourceURL,
            complaint: complaint,
            pattern: pattern,
            effort: effort,
            fit: fit
        )
    }

    private func sections(in modelInput: String) -> [Section] {
        let trimmed = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var raw: [Section] = []
        var title = ""
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !text.isEmpty {
                raw.append(Section(title: title, body: text))
            }
            body = []
        }
        for line in trimmed.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                flush()
                title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()

        var merged: [Section] = []
        for section in raw {
            if isSourceBody(section.body) || merged.isEmpty {
                merged.append(section)
            } else {
                merged[merged.count - 1].body += "\n\(section.title)\n\(section.body)"
            }
        }
        return merged
    }

    private func isSourceBody(_ body: String) -> Bool {
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return false }
        if first.hasPrefix("source:") || first.hasPrefix("---") || first.hasPrefix("+++") || first.hasPrefix("@@") {
            return true
        }
        return lines.contains { $0.lowercased().hasPrefix("source:") }
    }

    private func contentLines(_ body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { raw in
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("@@") {
                return nil
            }
            if raw.hasPrefix("+") {
                return String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if raw.hasPrefix("-") {
                return nil
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    private func lead(in lines: [String]) -> String? {
        if let summary = lines.compactMap({ value($0, key: "summary:") }).first {
            return summary
        }
        let notes = lines.compactMap { value($0, key: "notes:") }
        if let specific = notes.first(where: { !isGeneric($0) }) {
            return specific
        }
        if let note = notes.first {
            return note
        }
        return lines.first { !isSkippable($0) && $0.count >= 40 }
    }

    private func value(_ line: String, key: String) -> String? {
        guard line.lowercased().hasPrefix(key) else { return nil }
        let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func field(_ key: String, in lines: [String]) -> String? {
        lines.compactMap { value($0, key: key) }.first
    }

    private func isGeneric(_ note: String) -> Bool {
        var text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("-") || text.hasPrefix("•") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let lower = text.lowercased()
        if lower.hasPrefix("bug fix") || lower.hasPrefix("overall app improvement") {
            return true
        }
        return [
            "bug fixes and improvements",
            "improvements",
            "app improvements.",
            "improvements to overall app performance.",
        ].contains(lower)
    }

    private func isSkippable(_ line: String) -> Bool {
        let lower = line.lowercased()
        let keys = [
            "source:", "title:", "kind:", "url:", "fetch:", "name:", "screenshots:",
            "version:", "released:", "count:", "description:", "product:", "posts fetched:",
            "cap:", "citations:",
        ]
        if keys.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.hasPrefix("[") || lower.hasPrefix("#") || lower.hasPrefix(">") { return true }
        if lower.contains("llms.txt") || lower.contains("documentation index") || lower.contains("changelog") {
            return true
        }
        if lower.hasPrefix("for every ") || lower.hasPrefix("for the complete") { return true }
        if lower == "download video" || lower == "by" { return true }
        return false
    }

    private func sanitize(_ text: String) -> String {
        var result = text
        for brand in Self.brands {
            result = result.replacingOccurrences(of: brand, with: " ", options: .caseInsensitive)
        }
        let words = result.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            let bare = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if bare.isEmpty { return false }
            if word.hasPrefix("-") { return false }
            return true
        }
        return words.joined(separator: " ")
    }

    private func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func clip(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        var clipped = String(text[..<end])
        if let space = clipped.lastIndex(of: " ") {
            clipped = String(clipped[..<space])
        }
        return clipped
    }

    private func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let joined = String(mapped)
        let parts = joined.split(separator: "-").map(String.init)
        return parts.isEmpty ? "change" : parts.joined(separator: "-")
    }
}
