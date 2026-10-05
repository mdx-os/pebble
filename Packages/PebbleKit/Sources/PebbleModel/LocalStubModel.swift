import Foundation
import PebbleCore

/// On-device placeholder. Warm, fixed replies so the chat works before a
/// real model is plugged in. See `ModelClient` for the MLX and Ollama adapters.
public struct LocalStubModel: ModelClient {
    public init() {}

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard let person = transcript.last(where: { $0.speaker == .person }) else {
            throw ModelClientError.noPersonTurn
        }
        return Self.text(for: person.text)
    }

    private static func text(for personText: String) -> String {
        let trimmed = personText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let job = FirstConversation.jobs.first(where: { job in
            job.prompt.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }), let reply = repliesByJobID[job.id] {
            return reply
        }
        return fallback
    }

    private static let fallback = "I'm with you. Say a little more about what you need, and I'll answer from this device."

    private static let repliesByJobID: [String: String] = [
        "morning": "Tell me the one thing that would make the morning feel settled. I'll turn it into a short list you can keep.",
        "talk": "I'm here. Tell me what's going on, and what you want to be true when we're done.",
        "remember": "Tell me the detail in your own words. I'll say it back so you can check I heard it. It stays on this device.",
    ]
}
