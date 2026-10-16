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
    public static let hello = "Hi there."
    public static let helloDetail = "I'm here to help with the everyday things. Everything you tell me stays on this device."
    public static let beginTitle = "Let's begin"
    public static let nameQuestion = "What would you like to call me?"
    public static let nameDetail = "Pick any name. You can change it later."
    public static let lookQuestion = "How should I look?"
    public static let lookDetail = "Choose a look that feels right."
    public static let ideasDetail = "Tap one, or just start talking."
    public static let justChatTitle = "I'll start on my own"
    public static func step(_ number: Int, of total: Int) -> String { "Step \(number) of \(total)" }
    public static func greeting(named name: String) -> String { "Nice to meet you. I'm \(name)." }
}

/// Words for the confirmation sheet.
public enum ConfirmationWords {
    public static let heading = "Before I do this"
    public static let toLabel = "To"
    public static let fromLabel = "From"
    public static let whatLabel = "What"
    public static let whereLabel = "Where"
    public static let priceLabel = "Price"
    public static let expired = "That question timed out, so I didn't do it. Ask me again when you're ready."
    public static let promise = "I only do this once, exactly as shown. Anything different and I'll ask again."
}
