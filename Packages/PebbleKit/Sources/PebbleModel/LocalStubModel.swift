import Foundation
import PebbleCore

/// On-device starter model. It gives every starter job a real first result
/// (a morning plan, a detail said back, a next step) without any network,
/// and is honest that it is a small helper. See `ModelClient` for the MLX
/// and Ollama adapters.
public struct LocalStubModel: ModelClient {
    public init() {}

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        try Self.answer(to: transcript)
    }

    /// Synchronous so previews and tests can build a transcript instantly.
    public static func answer(to transcript: [ChatTurn]) throws -> String {
        let people = transcript.filter { $0.speaker == .person }
        guard let last = people.last else { throw ModelClientError.noPersonTurn }
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
    package static func morningPlan(from text: String) -> String {
        let steps = planItems(from: text)
        guard !steps.isEmpty else { return fallback }
        var lines = ["Here's a calm start, beginning at 8:00. Move anything that doesn't fit."]
        for (index, step) in steps.enumerated() {
            let minutes = 8 * 60 + index * 30
            lines.append("\(minutes / 60):\(String(format: "%02d", minutes % 60))  \(step)")
        }
        lines.append("Start with the first one. The rest gets easier after that.")
        return lines.joined(separator: "\n")
    }

    package static let maxPlanItems = 6

    package static func planItems(from text: String) -> [String] {
        var parts = [text]
        for separator in ["\n", ",", ";", " and ", " then "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let items = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return Array(items.prefix(maxPlanItems))
    }

    package static let fallback = "I'm a small helper that runs only on this device, so I'm best at morning plans, saying a detail back, and talking things through. Pick one of those and I'll get you a result."

    private static let openers: [String: String] = [
        "morning": "Tell me what's on for the morning, separated by commas. I'll turn it into a short plan you can keep.",
        "talk": "I'm here. Tell me what's going on, and what you want to be true when we're done.",
        "remember": "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.",
    ]
}
