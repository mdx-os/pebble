import Foundation

/// One line in a conversation between the person and their agent.
public struct ChatTurn: Identifiable, Sendable, Equatable {
    public enum Speaker: Sendable, Equatable {
        case agent
        case person
    }

    public let id: UUID
    public let speaker: Speaker
    public let text: String

    public init(id: UUID, speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}
