import Foundation

/// The person's choices about help from a cloud model. Off until they turn
/// it on, and nothing is sent while it is off.
public struct CloudHelpSettings: Sendable, Equatable, Codable {
    public var isOn: Bool
    /// Words and phrases hidden from everything sent, on top of the names,
    /// emails, numbers and addresses `Redactor` always hides.
    public var privateWords: [String]

    public init(isOn: Bool = false, privateWords: [String] = []) {
        self.isOn = isOn
        self.privateWords = privateWords
    }

    /// Off, with nothing marked private.
    public static let off = CloudHelpSettings()

    public static let maxPrivateWords = 50
    public static let maxPrivateWordLength = 60

    /// Adds a private word unless it is blank, too long, or already there.
    /// Returns false when nothing was added.
    @discardableResult
    public mutating func addPrivateWord(_ proposed: String) -> Bool {
        let word = proposed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !word.isEmpty, word.count <= Self.maxPrivateWordLength,
              privateWords.count < Self.maxPrivateWords,
              !privateWords.contains(where: { $0.lowercased() == word.lowercased() }) else { return false }
        privateWords.append(word)
        return true
    }

    public mutating func removePrivateWord(_ word: String) {
        privateWords.removeAll { $0 == word }
    }
}

/// Where the cloud helper's settings are kept.
public protocol CloudHelpStoring: Sendable {
    func load() -> CloudHelpSettings
    func save(_ settings: CloudHelpSettings)
}

/// Keeps the settings in UserDefaults. Anything unreadable reads as off.
public struct UserDefaultsCloudHelpStore: CloudHelpStoring, @unchecked Sendable {
    public static let key = "pebble.cloudHelp"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CloudHelpSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(CloudHelpSettings.self, from: data) else { return .off }
        return settings
    }

    public func save(_ settings: CloudHelpSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Keeps the settings in memory, for tests and screenshots.
public final class InMemoryCloudHelpStore: CloudHelpStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: CloudHelpSettings

    public init(_ settings: CloudHelpSettings = .off) {
        self.settings = settings
    }

    public func load() -> CloudHelpSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: CloudHelpSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}

/// The address of the cloud helper.
///
/// It is set in `Config/Cloud.xcconfig` and reaches the app through the
/// `PebbleCloudEndpoint` Info.plist key. It is empty by default, and empty
/// means there is no cloud helper: the setting stays off and can't be
/// turned on.
public enum CloudEndpoint {
    public static let infoKey = "PebbleCloudEndpoint"

    /// The address, or nil when it is empty, still an unexpanded build
    /// setting, or not a secure web address.
    public static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("$("),
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func url(infoDictionary: [String: Any]?) -> URL? {
        url(from: infoDictionary?[infoKey] as? String)
    }
}

/// Words for the cloud helper: the setting, the question before turning it
/// on, and the preview of what leaves the device.
public enum CloudWords {
    public static let title = "Help from the cloud"
    public static let toggleTitle = "Use a cloud model"
    public static let offDetail = "Off. Everything I do stays on this device."
    public static let onDetail = "On for new chats. Before anything leaves this device, I show you exactly what goes, and you decide."
    public static let unavailable = "There's no cloud model set up for this device yet, so this stays off."
    public static let rowTitle = "Help from the cloud"
    public static let rowOff = "Off"
    public static let rowOn = "On"

    public static let askQuestion = "Turn on help from the cloud?"
    public static let askPoints: [String] = [
        "Your next new chat will use a bigger model on a computer somewhere else, not on this device.",
        "Before anything leaves, I show you exactly what goes. You can send it or keep it here.",
        "I take out names from your notes, emails, phone numbers, addresses, card numbers and your private words first.",
        "Your notes themselves never leave this device.",
        "If you tell me you might be in danger, I answer here and send nothing.",
        "You can turn this off anytime.",
    ]
    public static let askYes = "Turn it on"
    public static let askNo = "Not now"

    public static let privateTitle = "Words I always hide"
    public static let privateDetail = "Anything here is taken out before anything is sent."
    public static let privatePlaceholder = "A word or name to keep private"
    public static let privateAdd = "Hide this word"
    public static func privateRemove(_ word: String) -> String { "Stop hiding \(word)" }

    public static let previewTitle = "Here is exactly what leaves your device"
    public static let previewDetail = "I took out personal details first. Nothing else goes, and only once."
    public static func previewDestination(_ host: String) -> String { "Going to \(host)" }
    public static let previewNothingHidden = "I didn't find anything personal to take out."
    public static func previewHidden(_ parts: [String]) -> String {
        "Taken out: " + parts.joined(separator: ", ") + "."
    }
    public static let previewSend = "Send this"
    public static let previewCancel = "Don't send"

    /// After the person chose not to send.
    public static let notSent = "Okay, I didn't send it. What you wrote is still here."
    /// The setting was turned off while this chat was using the cloud.
    public static let turnedOff = "Help from the cloud is off now, so I didn't send that. Start a new chat and I'll answer on this device."
    /// The chat header when the model is not on this device.
    public static let presence = "Here with you."

    public static let all: [String] = [
        title, toggleTitle, offDetail, onDetail, unavailable, rowTitle, rowOff, rowOn,
        askQuestion, askYes, askNo, privateTitle, privateDetail, privatePlaceholder, privateAdd,
        privateRemove("Sam"), previewTitle, previewDetail, previewDestination("example.com"),
        previewNothingHidden, previewHidden(["1 name"]), previewSend, previewCancel,
        notSent, turnedOff, presence,
    ] + askPoints
}
