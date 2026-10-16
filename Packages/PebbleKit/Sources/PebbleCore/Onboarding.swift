import Foundation

/// How often the agent speaks up on its own.
public enum Proactivity: String, CaseIterable, Codable, Sendable {
    /// Only answers when spoken to.
    case quiet
    /// Checks in now and then with something useful.
    case checkIn
    /// Offers ideas whenever it notices something.
    case suggest

    /// The gentlest choice until the person picks one.
    public static let startingPoint: Proactivity = .quiet

    public static let storageKey = "pebble.agent.proactivity"

    public var title: String {
        switch self {
        case .quiet: "Wait until I ask"
        case .checkIn: "Check in now and then"
        case .suggest: "Speak up with ideas"
        }
    }

    public var detail: String {
        switch self {
        case .quiet: "I'll only talk when you start."
        case .checkIn: "Once in a while I'll bring you something useful."
        case .suggest: "When I notice something that could help, I'll say so."
        }
    }
}

/// The steps of the first run, in order.
public enum OnboardingStep: Int, CaseIterable, Sendable, Comparable {
    case name
    case proactivity
    case starters
    case done

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Words for the first run.
public enum OnboardingWords {
    public static let welcome = "Hi. Before we start, a couple of quick choices."
    public static let proactivityQuestion = "How often should I speak up on my own?"
    public static let startersHeading = "Here are a few places to start."
    public static let continueTitle = "Continue"
    public static let skipTitle = "Skip for now"
}

/// The first run: name the agent, pick how proactive it is, then offer
/// starter ideas so the first chat never opens blank.
///
/// Every step can be skipped. A skipped name keeps the product name and a
/// skipped proactivity keeps `Proactivity.startingPoint`.
public struct OnboardingFlow: Sendable {
    public private(set) var step: OnboardingStep
    public private(set) var name: AgentName?
    public private(set) var proactivity: Proactivity
    public private(set) var hint: String?

    public init() {
        step = .name
        proactivity = .startingPoint
    }

    /// Ideas shown on the starters step. Never empty.
    public var starters: [StarterJob] { FirstConversation.jobs }

    /// Propose a name. Moves on only when the name is usable.
    @discardableResult
    public mutating func chooseName(_ proposed: String) -> Bool {
        guard step == .name else { return false }
        switch AgentName.decide(proposed) {
        case .accepted(let chosen):
            name = chosen
            hint = nil
            step = .proactivity
            return true
        case .needsAName:
            hint = FirstConversation.needsAName
        case .tooLong:
            hint = FirstConversation.nameTooLong
        }
        return false
    }

    public mutating func chooseProactivity(_ choice: Proactivity) {
        guard step == .proactivity else { return }
        proactivity = choice
        step = .starters
    }

    /// Leave the current step as it is and move on.
    public mutating func skip() {
        hint = nil
        switch step {
        case .name: step = .proactivity
        case .proactivity: step = .starters
        case .starters, .done: step = .done
        }
    }

    /// Pick a starter idea. Returns the line to send as the first message.
    public mutating func pickStarter(_ id: String) -> String? {
        guard step == .starters, let job = starters.first(where: { $0.id == id }) else { return nil }
        step = .done
        return job.prompt
    }
}

/// Saves the proactivity choice on this device.
public struct ProactivityStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Proactivity {
        defaults.string(forKey: Proactivity.storageKey).flatMap(Proactivity.init(rawValue:)) ?? .startingPoint
    }

    public func save(_ choice: Proactivity) {
        defaults.set(choice.rawValue, forKey: Proactivity.storageKey)
    }
}
