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
/// The agent's name comes from `Brand`. A person may choose another name
/// later. This name is the agent, not someone in their contacts.
public enum FirstConversation {
    public static let openingID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!

    public static let presence = "Here with you, on this device."
    public static let composerPlaceholder = "Say what's on your mind"
    public static let sendTitle = "Send"
    public static let thinking = "One moment."
    public static let couldNotAnswer = "I couldn't answer that just now. Try once more."

    public static func opening(for brand: Brand) -> String {
        "Hi, I'm \(brand.name). Pick a place to start, or tell me what's on your mind."
    }

    public static func initial(for brand: Brand) -> String {
        let trimmed = brand.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
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
