import Foundation
import PebbleCore

public enum ConversationError: Error, Equatable, Sendable {
    /// The person line was empty.
    case blank
    /// The model returned an empty reply.
    case emptyReply
    /// A reply was asked for before the person had spoken.
    case missingPerson
    /// The opening promised words stay on this device, but the model does not run here.
    case leavesDevice
}

/// The turns so far, and how a new line is added.
public struct Conversation: Sendable, Equatable {
    public private(set) var turns: [ChatTurn]
    /// Whether the opening may promise that words stay on this device.
    public let place: PrivacyPlace

    public init(turns: [ChatTurn], place: PrivacyPlace = .mayLeaveDevice) {
        self.turns = turns
        self.place = place
    }

    public static func firstRun(named name: String, place: PrivacyPlace = .mayLeaveDevice) -> Conversation {
        Conversation(turns: [
            ChatTurn(
                id: FirstConversation.openingID,
                speaker: .agent,
                text: FirstConversation.opening(named: name, place: place)
            ),
        ], place: place)
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
                text: FirstConversation.opening(named: name.text, place: place)
            )
        }
        return Conversation(turns: turns, place: place)
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

    /// Adds a line the agent says on this device without asking a model,
    /// such as an offer to look into something.
    public func appendingAgent(_ text: String, id: UUID = UUID()) throws -> Conversation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationError.blank }
        var next = self
        next.turns.append(ChatTurn(id: id, speaker: .agent, text: trimmed))
        return next
    }

    /// The conversation without the turn `id`, as when the person chose not
    /// to send it. Later requests then never carry those words.
    public func removingTurn(_ id: UUID) -> Conversation {
        var next = self
        next.turns.removeAll { $0.id == id }
        return next
    }

    /// Asks `model` to answer the turns so far and appends that reply.
    /// Words of crisis get a caring reply before any device check, so a
    /// remote model never blocks 988.
    public func appendingReply(from model: any ModelClient, id: UUID = UUID()) async throws -> Conversation {
        guard turns.last?.speaker == .person else { throw ConversationError.missingPerson }
        let reply: String
        if let care = CareCheck.reply(after: turns) {
            reply = care
        } else {
            if place.staysOnDevice && !model.privacyPlace.staysOnDevice { throw ConversationError.leavesDevice }
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
