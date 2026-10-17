import Foundation

/// How the agent's character looks. Purely visual; it never changes behavior.
public enum AgentLook: String, CaseIterable, Codable, Sendable {
    case sunrise
    case meadow
    case tide
    case dusk

    public static let startingPoint: AgentLook = .sunrise
    public static let storageKey = "pebble.agent.look"

    /// Spoken by VoiceOver and shown under each choice.
    public var title: String {
        switch self {
        case .sunrise: "Sunrise"
        case .meadow: "Meadow"
        case .tide: "Tide"
        case .dusk: "Dusk"
        }
    }

    public static func load(from defaults: UserDefaults) -> AgentLook {
        defaults.string(forKey: storageKey).flatMap(AgentLook.init(rawValue:)) ?? startingPoint
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

/// Words for the guided first run screens.
public enum FirstRunWords {
    public static let hello = "Hi there. I'm glad you're here."
    public static let helloDetail = "I'm here to help with everyday things, big and small. Everything you tell me stays on this device."
    public static let beginTitle = "Let's begin"
    public static let nameQuestion = "What would you like to call me?"
    public static let nameDetail = "Pick any name you like. You can change it later."
    public static let lookQuestion = "How should I look?"
    public static let lookDetail = "Pick the one that feels most like a friend."
    public static let ideasDetail = "Tap one to start together, or just say hello."
    public static let justChatTitle = "I'll start on my own"
    public static func step(_ number: Int, of total: Int) -> String { "Step \(number) of \(total)" }
    public static func greeting(named name: String) -> String { "Nice to meet you. I'm \(name)." }
}

/// Words for the confirmation sheet.
public enum ConfirmationWords {
    public static let heading = "Checking with you first"
    public static let toLabel = "To"
    public static let fromLabel = "From"
    public static let whatLabel = "What"
    public static let whereLabel = "Where"
    public static let priceLabel = "Price"
    public static let expired = "That question timed out, so I didn't do anything. Ask me again whenever you're ready."
    public static let closeTitle = "Close"
    public static let promise = "If you say yes, I'll do this once, exactly as shown. If anything changes, I'll ask you again."}
