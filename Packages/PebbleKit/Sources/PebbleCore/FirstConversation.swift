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
    /// Read out once by VoiceOver while a reply is on its way.
    public static let thinking = "Thinking it over."
    public static let couldNotAnswer = "Sorry, I couldn't finish a reply just now. What you wrote is still here, so you can send it again when you're ready."
    /// Above the starter choices in a new chat.
    public static let startersHeading = "A few places to start"

    public static let nameInvitation = "You can give me any name you like."
    public static let giveNameTitle = "Give me a name"
    public static let changeNameTitle = "Call me something else"
    public static let namePlaceholder = "A name for me"
    public static let confirmNameTitle = "That's my name"
    public static let cancelNameTitle = "Never mind"
    public static let needsAName = "Type a name first. Any name works."
    public static let nameTooLong = "That's a little long. Try a name of \(AgentName.maxLength) letters or fewer."

    /// Only promise that words stay here when the model really runs here.
    public static func opening(named name: String, onDevice: Bool = false) -> String {
        onDevice
            ? "Hi, I'm \(name). I'm glad you're here. I run on this device, so what you tell me stays here. Pick a place to start, or tell me what's on your mind."
            : "Hi, I'm \(name). I'm glad you're here. Pick a place to start, or tell me what's on your mind."
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
