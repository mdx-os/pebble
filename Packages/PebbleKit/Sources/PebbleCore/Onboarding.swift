import Foundation

/// How often the agent speaks up on its own.
///
/// Proactivity only ever means speaking up. It never means acting: sending,
/// buying or sharing always goes through `AskFirst`.
public enum Proactivity: String, CaseIterable, Codable, Sendable {
    /// Only answers when spoken to.
    case quiet
    /// Checks in now and then with something useful.
    case checkIn
    /// Offers ideas drawn from what the person has shared.
    case suggest

    /// The gentlest choice until the person picks one.
    public static let startingPoint: Proactivity = .quiet

    public static let storageKey = "pebble.agent.proactivity"

    /// Choices the app can honor today. A choice joins this list only when
    /// something actually behaves that way.
    public static let offered: [Proactivity] = [.quiet]

    public var isOffered: Bool { Self.offered.contains(self) }

    public var title: String {
        switch self {
        case .quiet: "Wait until you ask"
        case .checkIn: "Check in now and then"
        case .suggest: "Speak up with ideas"
        }
    }

    public var detail: String {
        switch self {
        case .quiet: "I'll only talk when you start."
        case .checkIn: "Once in a while I'll bring you something useful."
        case .suggest: "When something you've shared gives me an idea, I'll say so."
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
    public static let welcome = "Hi. Before we start, one quick choice."
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

    /// The proactivity step appears only when there is a real choice to make.
    static var afterName: OnboardingStep { Proactivity.offered.count > 1 ? .proactivity : .starters }

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
            step = Self.afterName
            return true
        case .needsAName:
            hint = FirstConversation.needsAName
        case .tooLong:
            hint = FirstConversation.nameTooLong
        }
        return false
    }

    public mutating func chooseProactivity(_ choice: Proactivity) {
        guard step == .proactivity, choice.isOffered else { return }
        proactivity = choice
        step = .starters
    }

    /// Leave the current step as it is and move on.
    public mutating func skip() {
        hint = nil
        switch step {
        case .name: step = Self.afterName
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

/// First run choices kept on this device.
public protocol OnboardingStoring: Sendable {
    func loadProactivity() -> Proactivity
    func saveProactivity(_ choice: Proactivity)
    /// True once the first run has been finished or skipped through.
    func hasFinished() -> Bool
    func markFinished()
    /// Forget the proactivity choice and the finished flag. The name lives
    /// in `AgentNameStoring`; use `OnboardingFlow.reset(store:names:)` to
    /// start over completely.
    func reset()
}

public enum OnboardingStorageKeys {
    public static let finished = "pebble.onboarding.finished"
}

/// Saves first run choices in UserDefaults.
public struct UserDefaultsOnboardingStore: OnboardingStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadProactivity() -> Proactivity {
        defaults.string(forKey: Proactivity.storageKey)
            .flatMap(Proactivity.init(rawValue:))
            .flatMap { $0.isOffered ? $0 : nil } ?? .startingPoint
    }

    /// Only choices the app honors are ever stored.
    public func saveProactivity(_ choice: Proactivity) {
        guard choice.isOffered else { return }
        defaults.set(choice.rawValue, forKey: Proactivity.storageKey)
    }

    public func hasFinished() -> Bool { defaults.bool(forKey: OnboardingStorageKeys.finished) }
    public func markFinished() { defaults.set(true, forKey: OnboardingStorageKeys.finished) }

    public func reset() {
        defaults.removeObject(forKey: OnboardingStorageKeys.finished)
        defaults.removeObject(forKey: Proactivity.storageKey)
    }
}

/// A stand in store for tests and screenshots.
public final class InMemoryOnboardingStore: OnboardingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var proactivity: Proactivity
    private var finished: Bool

    public init(proactivity: Proactivity = .startingPoint, finished: Bool = false) {
        self.proactivity = proactivity
        self.finished = finished
    }

    public func loadProactivity() -> Proactivity {
        lock.lock(); defer { lock.unlock() }
        return proactivity.isOffered ? proactivity : .startingPoint
    }
    public func saveProactivity(_ choice: Proactivity) {
        guard choice.isOffered else { return }
        lock.lock(); proactivity = choice; lock.unlock()
    }
    public func hasFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    public func markFinished() { lock.lock(); finished = true; lock.unlock() }
    public func reset() { lock.lock(); finished = false; proactivity = .startingPoint; lock.unlock() }
}

extension OnboardingFlow {
    /// Save the outcome once the flow is done: the chosen name, the
    /// proactivity choice and the finished flag. Does nothing before that.
    public func save(to store: OnboardingStoring, names: AgentNameStoring) {
        guard step == .done else { return }
        if let name { names.saveDisplayName(name.text) }
        store.saveProactivity(proactivity)
        store.markFinished()
    }

    /// Start over as if the app were new: the name, the proactivity choice
    /// and the finished flag are all forgotten.
    public static func reset(store: OnboardingStoring, names: AgentNameStoring) {
        names.clearDisplayName()
        store.reset()
    }

    /// True when the first run should show. Someone who already named their
    /// agent before the first run existed is not asked again.
    public static func isNeeded(store: OnboardingStoring, names: AgentNameStoring) -> Bool {
        !store.hasFinished() && names.loadDisplayName() == nil
    }
}
