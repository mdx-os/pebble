import Foundation

/// A first job the agent offers, in the person's own words.
public struct StarterJob: Identifiable, Sendable, Equatable {
    public let id: String
    /// Short label on the choice.
    public let title: String
    /// The line sent when the person picks this job.
    public let prompt: String

    public init(id: String, title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

/// Words for the first conversation.
///
/// The product name lives on `Brand`. The name in the chat is the agent's
/// display name, chosen on this device. That name is the agent, not a person
/// in the user's contacts.
public enum FirstConversation {
    public static let openingID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!

    public static let presence = "Here with you, on this device."
    public static let composerPlaceholder = "Say what's on your mind"
    public static let sendTitle = "Send"
    public static let thinking = "One moment."
    public static let couldNotAnswer = "I couldn't answer that just now. Try once more."

    public static let nameInvitation = "You get to name me."
    public static let giveNameTitle = "Give me a name"
    public static let changeNameTitle = "Call me something else"
    public static let namePlaceholder = "A name for me"
    public static let confirmNameTitle = "That's my name"
    public static let cancelNameTitle = "Never mind"
    public static let needsAName = "I need a name to go by."
    public static let nameTooLong = "That's a little long for a name."

    public static func opening(named name: String) -> String {
        "Hi, I'm \(name). Pick a place to start, or tell me what's on your mind."
    }

    public static let jobs: [StarterJob] = [
        StarterJob(
            id: "morning",
            title: "Plan my morning",
            prompt: "Help me plan my morning."
        ),
        StarterJob(
            id: "talk",
            title: "Talk something through",
            prompt: "Help me talk something through."
        ),
        StarterJob(
            id: "remember",
            title: "Remember a detail",
            prompt: "Help me remember a detail."
        ),
    ]
}
