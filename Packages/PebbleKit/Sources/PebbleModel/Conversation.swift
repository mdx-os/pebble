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
    /// Whether the opening may promise that words stay on this device.
    public let onDevice: Bool

    public init(turns: [ChatTurn], onDevice: Bool = false) {
        self.turns = turns
        self.onDevice = onDevice
    }

    public static func firstRun(named name: String, onDevice: Bool = false) -> Conversation {
        Conversation(turns: [
            ChatTurn(
                id: FirstConversation.openingID,
                speaker: .agent,
                text: FirstConversation.opening(named: name, onDevice: onDevice)
            ),
        ], onDevice: onDevice)
    }

    /// Rewrites the opening line when the person has not spoken yet.
    /// Lines already said stay as they were.
    public func renamingAgent(to name: AgentName) -> Conversation {
        guard isWaitingForPerson else { return self }
        let turns = self.turns.map { turn in
            guard turn.id == FirstConversation.openingID, turn.speaker == .agent else { return turn }
            return ChatTurn(
                id: turn.id,
                speaker: .agent,
                text: FirstConversation.opening(named: name.text, onDevice: onDevice)
            )
        }
        return Conversation(turns: turns, onDevice: onDevice)
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
        let reply: String
        if let care = CareCheck.reply(after: turns) {
            reply = care
        } else {
            reply = try await model.reply(to: CareCheck.redacted(turns))
        }
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
