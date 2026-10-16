import Foundation
import PebbleCore

/// On-device starter model. It gives every starter job a real first result
/// (a morning plan, a detail said back, a next step) without any network,
/// and is honest that it is a small helper. See `ModelClient` for the MLX
/// and Ollama adapters.
public struct LocalStubModel: ModelClient {
    public init() {}

    public var runsOnDevice: Bool { true }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        try Self.answer(to: transcript)
    }

    /// Synchronous so previews and tests can build a transcript instantly.
    public static func answer(to transcript: [ChatTurn]) throws -> String {
        let people = transcript.filter { $0.speaker == .person }
        guard let last = people.last else { throw ModelClientError.noPersonTurn }
        if needsCare(last.text) { return care }
        if let job = job(matching: last.text) {
            return openers[job.id] ?? fallback
        }
        if people.count >= 2, let job = job(matching: people[people.count - 2].text) {
            return result(for: job.id, from: last.text)
        }
        return fallback
    }

    private static func job(matching text: String) -> StarterJob? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FirstConversation.jobs.first { job in
            job.prompt.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
    }

    private static func result(for jobID: String, from text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch jobID {
        case "morning": return morningPlan(from: clean)
        case "remember": return "Here's what I heard: \"\(clean)\". If that's right, add it in What I remember and I'll keep it on this device."
        case "talk": return "That sounds like a lot to carry. Here's one small next step: write down the part you can act on today, and leave the rest for later. Want to tell me what that part is?"
        default: return fallback
        }
    }

    /// Splits what the person listed into steps and gives each a start time.
    /// Times are a simple 8:00 start in 30 minute steps; a real model can do better.
    package static func morningPlan(from text: String) -> String {
        let all = planItems(from: text)
        let steps = Array(all.prefix(maxPlanItems))
        guard !steps.isEmpty else { return morningReask }
        var lines = ["Here's a calm start, beginning at 8:00. Move anything that doesn't fit."]
        for (index, step) in steps.enumerated() {
            let minutes = 8 * 60 + index * 30
            lines.append("\(minutes / 60):\(String(format: "%02d", minutes % 60))  \(step)")
        }
        if all.count > steps.count {
            lines.append("I kept the first \(maxPlanItems) so the morning stays light. Tell me what else and I'll fit it in.")
        }
        lines.append("Start with the first one. The rest gets easier after that.")
        return lines.joined(separator: "\n")
    }

    package static let maxPlanItems = 6

    package static func planItems(from text: String) -> [String] {
        var parts = [text]
        // Commas, semicolons and new lines only, so "mac and cheese" stays whole.
        for separator in ["\n", ",", ";"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let items = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return items
    }

    package static let fallback = "Thanks for telling me. I'm a small helper that runs only on this device, so I can't do everything yet. I'm good at morning plans, saying a detail back, and talking things through. Want to start with one of those?"

    package static let morningReask = "I didn't catch any steps there. Try a few things separated by commas, like gym, email Ana, groceries."

    package static let care = "I'm really glad you told me. I'm a small helper and I can't keep you safe on my own. If you might act on this, please call or text 988 now, or your local emergency number, and reach someone you trust."

    private static let careWords = [
        "kill myself", "suicide", "suicidal", "end my life", "hurt myself", "self harm",
        "self-harm", "want to die", "don't want to be here", "dont want to be here",
    ]

    /// A small, fixed check. It favors caring too often over missing it.
    package static func needsCare(_ text: String) -> Bool {
        let lower = text.lowercased()
        return careWords.contains { lower.contains($0) }
    }

    private static let openers: [String: String] = [
        "morning": "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep.",
        "talk": "I'm here. Tell me what's going on, and what you want to be true when we're done.",
        "remember": "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.",
    ]
}
