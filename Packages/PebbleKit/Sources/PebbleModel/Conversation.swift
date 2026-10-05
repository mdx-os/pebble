import Foundation
import PebbleCore

public enum ConversationError: Error, Equatable, Sendable {
    /// The person line was empty.
    case blank
    /// The model returned an empty reply.
    case emptyReply
    /// A reply was asked for before the person had spoken.
    case missingPerson
}

/// The turns so far, and how a new line is added.
public struct Conversation: Sendable, Equatable {
    public private(set) var turns: [ChatTurn]

    public init(turns: [ChatTurn]) {
        self.turns = turns
    }

    public static func firstRun(for brand: Brand) -> Conversation {
        Conversation(turns: [
            ChatTurn(
                id: FirstConversation.openingID,
                speaker: .agent,
                text: FirstConversation.opening(for: brand)
            ),
        ])
    }

    public var isWaitingForPerson: Bool {
        !turns.contains(where: { $0.speaker == .person })
    }

    /// Adds the person's line. Does not call the model.
    public func appendingPerson(_ text: String, id: UUID = UUID()) throws -> Conversation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationError.blank }
        var next = self
        next.turns.append(ChatTurn(id: id, speaker: .person, text: trimmed))
        return next
    }

    /// Asks `model` to answer the turns so far and appends that reply.
    public func appendingReply(from model: any ModelClient, id: UUID = UUID()) async throws -> Conversation {
        guard turns.last?.speaker == .person else { throw ConversationError.missingPerson }
        let reply = try await model.reply(to: turns)
        let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ConversationError.emptyReply }
        var next = self
        next.turns.append(ChatTurn(id: id, speaker: .agent, text: cleaned))
        return next
    }

    /// Appends the person's line and the model's reply.
    public func sending(
        _ text: String,
        with model: any ModelClient,
        personID: UUID = UUID(),
        agentID: UUID = UUID()
    ) async throws -> Conversation {
        let withPerson = try appendingPerson(text, id: personID)
        return try await withPerson.appendingReply(from: model, id: agentID)
    }
}
