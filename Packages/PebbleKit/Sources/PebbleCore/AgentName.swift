import Foundation

/// The name a person chose for their agent.
///
/// This is the agent's display name. It is not a contact, and it is not the
/// product name in `Brand`. A saved choice lives on the device under
/// `storageKey`.
public struct AgentName: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        case accepted(AgentName)
        case needsAName
        case tooLong
    }

    /// UserDefaults key. The value is only the agent's display name.
    public static let storageKey = "pebble.agent.displayName"

    public static let maxLength = 40

    public let text: String

    /// Shown only when neither a saved name nor the product name is usable.
    fileprivate static let unnamedMark = AgentName(text: "?")

    private init(text: String) {
        self.text = text
    }

    public var initial: String {
        guard let first = text.first else { return "?" }
        return String(first).uppercased()
    }

    /// Collapses whitespace. An empty line needs a name. A very long line is refused.
    public static func decide(_ proposed: String) -> Decision {
        let text = proposed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty {
            return .needsAName
        }
        if text.count > maxLength {
            return .tooLong
        }
        return .accepted(AgentName(text: text))
    }
}

/// The product name and the name the person has saved, kept apart.
public struct AgentProfile: Sendable, Equatable {
    public let brand: Brand
    /// Nil until the person saves a name on this device.
    public let chosen: AgentName?

    public init(brand: Brand, stored: String?) {
        self.brand = brand
        if let stored, case .accepted(let name) = AgentName.decide(stored) {
            self.chosen = name
        } else {
            self.chosen = nil
        }
    }

    public init(brand: Brand, chosen: AgentName) {
        self.brand = brand
        self.chosen = chosen
    }

    /// A saved name wins. Otherwise the product name is only a starting point
    /// and is not written to the store.
    public var displayName: AgentName {
        if let chosen {
            return chosen
        }
        if case .accepted(let name) = AgentName.decide(brand.name) {
            return name
        }
        return AgentName.unnamedMark
    }

    public var hasChosenName: Bool {
        chosen != nil
    }
}

/// The rename control on the first conversation.
public struct AgentRenameState: Sendable, Equatable {
    public private(set) var profile: AgentProfile
    public private(set) var isOpen: Bool
    public private(set) var draft: String
    public private(set) var hint: String?

    public init(profile: AgentProfile) {
        self.profile = profile
        self.isOpen = false
        self.draft = ""
        self.hint = nil
    }

    public var renameTitle: String {
        profile.hasChosenName ? FirstConversation.changeNameTitle : FirstConversation.giveNameTitle
    }

    /// The invitation shows until the person has saved a name.
    public var showsInvitation: Bool {
        !profile.hasChosenName && !isOpen
    }

    public mutating func begin() {
        draft = profile.hasChosenName ? profile.displayName.text : ""
        hint = nil
        isOpen = true
    }

    public mutating func cancel() {
        draft = ""
        hint = nil
        isOpen = false
    }

    public mutating func setDraft(_ text: String) {
        draft = text
        hint = nil
    }

    /// Returns the accepted name. Does not write to the store.
    public mutating func confirm() -> AgentName? {
        switch AgentName.decide(draft) {
        case .accepted(let name):
            profile = AgentProfile(brand: profile.brand, chosen: name)
            draft = ""
            hint = nil
            isOpen = false
            return name
        case .needsAName:
            hint = FirstConversation.needsAName
            return nil
        case .tooLong:
            hint = FirstConversation.nameTooLong
            return nil
        }
    }
}

/// On-device storage for the agent's display name.
///
/// Implementations keep the name out of contacts.
public protocol AgentNameStoring: Sendable {
    func loadDisplayName() -> String?
    func saveDisplayName(_ name: String)
}

/// The name saved in `UserDefaults` on this device.
public struct UserDefaultsAgentNameStore: AgentNameStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadDisplayName() -> String? {
        defaults.string(forKey: AgentName.storageKey)
    }

    public func saveDisplayName(_ name: String) {
        defaults.set(name, forKey: AgentName.storageKey)
    }
}

/// A stand-in store for tests and screenshots.
public final class InMemoryAgentNameStore: AgentNameStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init(stored: String? = nil) {
        self.stored = stored
    }

    public func loadDisplayName() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func saveDisplayName(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = name
    }
}
