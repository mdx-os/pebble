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

    /// Why a private word can't be added.
    public enum Refusal: Sendable, Equatable {
        case blank, tooLong, full, alreadyThere
    }

    /// Adds a private word unless it is blank, too long, or already there.
    /// Returns false when nothing was added.
    @discardableResult
    public mutating func addPrivateWord(_ proposed: String) -> Bool {
        guard refusal(for: proposed) == nil else { return false }
        privateWords.append(Self.tidied(proposed))
        return true
    }

    /// Why `proposed` wouldn't be added, or nil when it would.
    public func refusal(for proposed: String) -> Refusal? {
        let word = Self.tidied(proposed)
        if word.isEmpty { return .blank }
        if privateWords.contains(where: { Self.same($0, word) }) { return .alreadyThere }
        if word.count > Self.maxPrivateWordLength { return .tooLong }
        if privateWords.count >= Self.maxPrivateWords { return .full }
        return nil
    }

    private static func tidied(_ proposed: String) -> String {
        proposed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    public mutating func removePrivateWord(_ word: String) {
        privateWords.removeAll { $0 == word }
    }

    /// "Sam's" and "sam’s" are the same word, and so are "Zoë" and "Zoe":
    /// folded as `Redactor` matches them, so a word it would already hide
    /// is never added twice.
    private static func same(_ a: String, _ b: String) -> Bool {
        func folded(_ s: String) -> String {
            ["\u{2019}", "\u{2018}", "\u{02BC}"].reduce(s) { $0.replacingOccurrences(of: $1, with: "'") }
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return folded(a) == folded(b)
    }
}

/// Where the cloud helper's settings are kept.
public protocol CloudHelpStoring: Sendable {
    /// The saved settings, read fresh. Nothing saved reads as off. Throws
    /// when they are saved but can't be read right now, so a caller can
    /// refuse to send rather than send without the private words.
    func load() throws -> CloudHelpSettings
    func save(_ settings: CloudHelpSettings) throws
    /// Erases everything saved, even when it can't be read.
    func erase() throws
}

extension CloudHelpStoring {
    /// The settings, or off when they can't be read.
    public func loadOrOff() -> CloudHelpSettings {
        (try? load()) ?? .off
    }
}

/// Keeps the settings in one file next to the notes: inside Application
/// Support, left out of backups, and locked with the device on iPhone and
/// iPad. The private words are the most sensitive words in the app, so they
/// get the same care as the notes. A restored or new device reads as off.
public final class CloudHelpFileStore: CloudHelpStoring, @unchecked Sendable {
    /// The private words can be opened only while the device is unlocked,
    /// as the notes can. Nothing that runs while locked reads them.
    public static let fileProtection: FileProtectionType = .complete

    public let fileURL: URL
    private let writer: ProtectedWriter
    private let lock = NSLock()

    public convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, writer: .disk)
    }

    package init(fileURL: URL, writer: ProtectedWriter) {
        self.fileURL = fileURL
        self.writer = writer
    }

    /// The store in the notes folder on this device.
    public static func onDevice(fileManager: FileManager = .default) throws -> CloudHelpFileStore {
        CloudHelpFileStore(fileURL: try MemoryStore.onDeviceFolder(fileManager: fileManager)
            .appendingPathComponent("cloud-help.json"))
    }

    var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    public func load() throws -> CloudHelpSettings {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .off }
        guard let data = try? Data(contentsOf: fileURL) else { throw MemoryStore.Unavailable() }
        guard let settings = try? JSONDecoder().decode(CloudHelpSettings.self, from: data) else {
            throw MemoryStore.Unreadable()
        }
        return settings
    }

    public func save(_ settings: CloudHelpSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        // Staged under one known name, then renamed over the real file, as
        // the notes are, so no copy is left anywhere else.
        try removeStaged()
        try writer.write(data, stagingURL, Self.fileProtection)
        guard rename(stagingURL.path, fileURL.path) == 0 else {
            try? removeStaged()
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func erase() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeStaged()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func removeStaged() throws {
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
    }
}

/// Keeps the settings in memory, for tests and screenshots.
public final class InMemoryCloudHelpStore: CloudHelpStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: CloudHelpSettings
    private var readable = true

    public init(_ settings: CloudHelpSettings = .off) {
        self.settings = settings
    }

    /// Makes `load` throw, as a locked or damaged file would.
    public func makeUnreadable(_ unreadable: Bool = true) {
        lock.withLock { readable = !unreadable }
    }

    public func load() throws -> CloudHelpSettings {
        lock.lock()
        defer { lock.unlock() }
        guard readable else { throw MemoryStore.Unavailable() }
        return settings
    }

    public func save(_ settings: CloudHelpSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
        readable = true
    }

    public func erase() throws {
        lock.lock()
        defer { lock.unlock() }
        settings = .off
        readable = true
    }
}

/// The address of the cloud helper.
///
/// It is set in `Config/Cloud.local.xcconfig`, which git ignores, and
/// reaches the app through the `PebbleCloudEndpoint` Info.plist key. It is
/// empty by default, and empty means there is no cloud helper: the setting
/// stays off and can't be turned on.
public enum CloudEndpoint {
    public static let infoKey = "PebbleCloudEndpoint"

    /// The address, or nil when it is empty, still an unexpanded build
    /// setting, or not a plain secure web address. A user name, password,
    /// query or fragment is refused, the usual places a key rides along.
    /// That is not a guarantee: a key put in the path, as in `/sk-abc`, still
    /// passes. Keys belong in `CloudAuth`, and whatever the address holds is
    /// shown in full in every preview.
    public static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("$("), !text.contains(where: { "?#@".contains($0) }),
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
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
    /// The setting while it is off. The device promise follows `place`, the
    /// same flag as every other device line: with a cloud chat still open,
    /// its words already left, so it says only that new chats are off.
    public static func offDetail(_ place: PrivacyPlace) -> String {
        place.staysOnDevice ? "Off. Everything I do stays on this device." : "Off for new chats."
    }
    public static let onDetail = "On for new chats. Before anything from a chat leaves this device, I show you exactly what goes, and you decide."
    public static let unavailable = "There's no cloud model set up for this device yet, so this stays off."
    /// The file the setting and private words are kept in couldn't be
    /// opened at launch, so nothing typed here could be kept. It is opened
    /// again only when the app starts.
    public static let couldNotOpen = "Sorry, I can't open the place I keep this setting and your private words, so it stays off for now. Closing and reopening the app may help."
    public static let rowTitle = "Help from the cloud"
    public static let rowOff = "Off"
    public static let rowOn = "On"

    public static let askQuestion = "Turn on help from the cloud?"
    public static let askPoints: [String] = [
        "Your next new chat will use a bigger model on a computer somewhere else, not on this device.",
        "Before anything from a chat leaves, I show you exactly what goes. You can send it or keep it here.",
        "I try to take out names from your notes, emails, phone numbers, addresses, card numbers and your private words first. Check what I show you, since I can miss things.",
        "Earlier messages in a chat go again with each new one, so you see them in every preview.",
        "The name you gave me goes too, in my first line of each chat.",
        // Stays true whatever `CloudAuth` does: see `CloudAuth.signIn`.
        "If that computer needs me to sign in, I do it right after your yes. Signing in never carries your chats, notes or private words.",
        "Your notes themselves never leave this device.",
        "Like any website, the computer it goes to can see this device's internet address.",
        "If you tell me you might be in danger, I answer here and send nothing.",
        "You can turn this off anytime.",
    ]
    public static let askYes = "Turn it on"
    public static let askNo = "Not now"

    public static let privateTitle = "Words I always hide"
    // Says "this device" without asking `PrivacyPlace`, like
    // `MemoryWords.forgetEverythingDetail`: it is about where the words are
    // kept, `CloudHelpFileStore` next to the notes, not where a chat goes.
    // They are taken out of every request, so they never leave even with
    // the cloud on. Don't gate it like `offDetail`.
    public static let privateDetail = "Anything here is taken out before anything is sent. These words are kept only on this device, and Forget everything erases them too."
    public static let privatePlaceholder = "A word or name to keep private"
    public static let privateAdd = "Hide this word"
    public static func privateRemove(_ word: String) -> String { "Stop hiding \(word)" }
    /// The private words couldn't be read, so they are left as they are.
    public static let privateUnreadable = "Sorry, I can't read your private words just now, so I've left them as they are. If the device is locked, unlock it and try again."
    /// A private word couldn't be saved, so the list is as it was.
    public static let privateNotSaved = "Sorry, I couldn't save that just now, so your private words are as they were. Please try again in a moment."
    /// A word that wasn't added, and why.
    public static let privateTooLong = "That's longer than I can hide. Please keep it to \(CloudHelpSettings.maxPrivateWordLength) characters or fewer."
    public static let privateFull = "I'm already hiding \(CloudHelpSettings.maxPrivateWords) words, the most I can. Stop hiding one to add this."
    public static let privateAlreadyThere = "I'm already hiding that one."

    /// What to say when a word wasn't added, if anything. A blank one says
    /// nothing, since there was nothing to add.
    public static func privateRefused(_ refusal: CloudHelpSettings.Refusal) -> String? {
        switch refusal {
        case .blank: nil
        case .tooLong: privateTooLong
        case .full: privateFull
        case .alreadyThere: privateAlreadyThere
        }
    }

    /// Turning off couldn't be saved, so the setting was erased to keep it
    /// off, and the private words went with it.
    public static let offButCleared = "Sorry, I couldn't save that. Help from the cloud is off, and to make sure it stays off I cleared the cloud setting, along with your private words. You can add them again anytime."
    /// Turning off couldn't be saved or erased. It is off until the app
    /// closes, and may read as on after that.
    public static let offForNow = "Sorry, I couldn't save that. Help from the cloud is off until you close the app, but it may be on again when you come back, so please check here then."
    /// Turning on couldn't be saved, so it is still off.
    public static let onNotSaved = "Sorry, I couldn't save that, so help from the cloud is still off. Please try again in a moment."

    public static let previewTitle = "Here is exactly what leaves your device"
    public static let previewDetail = "This is the whole request for this message: where it goes, the labels sent with it, and the words. I took out the personal details I found. Earlier messages in this chat go again with each new one. Like any website, the computer it goes to also sees this device's internet address."
    public static func previewDestination(_ host: String) -> String { "Going to \(host)" }
    public static let previewNothingHidden = "I didn't find anything personal to take out."
    public static func previewHidden(_ parts: [String]) -> String {
        // Every request carries the whole chat, so the count is for all of
        // it, not just the newest message.
        "Taken out of this chat: " + parts.joined(separator: ", ") + "."
    }
    public static let previewSend = "Send this"
    public static let previewCancel = "Don't send"

    /// What VoiceOver reads for the preview, in place of the raw text.
    public static func spokenAddress(_ address: String) -> String { "Going to \(address)." }
    public static func spokenLabels(_ labels: [String]) -> String {
        "Sent with these labels: " + labels.joined(separator: ". ") + "."
    }
    /// A sign-in label, read without its value, which is a secret.
    public static func spokenSignIn(_ name: String, characters: Int) -> String {
        "\(name), sign-in value, \(characters) \(characters == 1 ? "character" : "characters")"
    }
    public static func spokenMessage(role: String, text: String) -> String {
        switch role {
        case "person": "You said: \(text)"
        case "agent": "I said: \(text)"
        default: text
        }
    }

    /// After the person chose not to send.
    public static let notSent = "Okay, I didn't send it. What you wrote is still here."
    /// The setting was turned off while this chat was using the cloud. It
    /// says only what the next chat won't do: where it does answer depends
    /// on the local model, which this line can't see, so it makes no
    /// device promise.
    public static let turnedOff = "Help from the cloud is off now, so I didn't send that. A new chat won't use the cloud."
    /// Something earlier in this chat must stay on this device, so no part
    /// of the chat can be sent. Only a new chat can use the cloud again.
    public static let staysHere = "Part of this chat has to stay on this device, so I won't send any of it. A new chat starts fresh, and I can help there."
    /// The notes or private words couldn't be read, so nothing was sent.
    public static let notesUnreadable = "Sorry, I can't read your notes or private words just now, so I can't tell what to take out. I didn't send anything. If the device is locked, unlock it and try again."
    /// The question before Forget everything, when private words go too.
    /// Tasks go as well, so it says running ones stop, like
    /// `MemoryWords.forgetEverythingDetail`.
    public static let forgetEverythingDetail = "This removes every note, every task and every word you asked me to hide from this device, and stops any task still going. It can't be undone."
    /// The same, when the screen has the switch for work while away, like
    /// `MemoryWords.forgetEverythingDetail(background: true)`.
    public static let forgetEverythingWithSummariesDetail = "This removes every note, every task, every morning summary and every word you asked me to hide from this device, stops any task still going, and turns off work while you're away. It can't be undone."
    /// Forget everything erased the notes but not the private words.
    public static let forgotNotesNotWords = "Your notes are gone, but I couldn't erase your private words just now. Please try Forget everything again in a moment."
    /// The same, when there were tasks and they went too.
    public static let forgotNotesAndTasksNotWords = "Your notes and tasks are gone, but I couldn't erase your private words just now. Please try Forget everything again in a moment."
    /// Forget everything erased the private words but not the notes.
    public static let forgotWordsNotNotes = "Your private words are gone, but I couldn't erase your notes just now. Please try Forget everything again in a moment."
    /// The same, when there were tasks and they went too.
    public static let forgotTasksAndWordsNotNotes = "Your tasks and private words are gone, but I couldn't erase your notes just now. Please try Forget everything again in a moment."
    /// The tasks went, but neither the notes nor the private words could.
    public static let forgotTasksNotNotesOrWords = "Your tasks are gone, but I couldn't erase your notes or private words just now. Please try Forget everything again in a moment."
    /// Forget everything erased the notes, and the private words could only
    /// be erased with the whole cloud setting, which turned it off.
    public static let forgotAndCloudOff = "Gone. I no longer have it. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. You can turn it on again anytime."
    /// The same, but the morning summaries' file couldn't be erased, like
    /// `MemoryWords.couldNotForgetSummaries`.
    public static let forgotAndCloudOffNotSummaries = "I forgot your notes and tasks and turned off work while you're away, but I couldn't erase your morning summaries just now. To be sure your private words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget everything again in a moment."
    /// The same, but the notes couldn't be erased.
    public static let forgotWordsAndCloudNotNotes = "Your private words are gone. To be sure of that I cleared the cloud setting too, so help from the cloud is off. I couldn't erase your notes just now. Please try Forget everything again in a moment."
    /// The same, when there were tasks and they went too.
    public static let forgotTasksAndWordsAndCloudNotNotes = "Your tasks and private words are gone. To be sure of that I cleared the cloud setting too, so help from the cloud is off. I couldn't erase your notes just now. Please try Forget everything again in a moment."
    /// Forgetting tasks when the notes can't be opened, like
    /// `TaskWords.forgetTasksDetail`, when the words always hidden go too.
    /// There may be none, so it says "any".
    public static let forgetTasksAndWordsDetail = "This stops any task still going, and removes every task, what you told me for it and any words you asked me to hide from this device. It can't be undone. Your notes aren't touched."
    /// The tasks and any private words went.
    public static let tasksAndWordsForgotten = "Your tasks are forgotten, and so are any words you asked me to hide."
    /// The same, when the words could only go with the whole cloud setting,
    /// which may have been on.
    public static let tasksAndWordsAndCloudForgotten = "Your tasks are forgotten, and so are any words you asked me to hide. To be sure of that I cleared the cloud setting too, so help from the cloud is off."
    /// The tasks went, but the private words' file couldn't be reached.
    public static let tasksForgottenNotWords = "Your tasks are forgotten, but I couldn't erase the words you asked me to hide. Closing and reopening the app may help."

    public static let all: [String] = [
        title, toggleTitle, offDetail(.onDevice), offDetail(.mayLeaveDevice), onDetail, unavailable, couldNotOpen,
        rowTitle, rowOff, rowOn,
        askQuestion, askYes, askNo, privateTitle, privateDetail, privatePlaceholder, privateAdd,
        privateRemove("Sam"), privateUnreadable, privateNotSaved, privateTooLong, privateFull, privateAlreadyThere,
        offButCleared, offForNow, onNotSaved,
        previewTitle, previewDetail, previewDestination("example.com"),
        previewNothingHidden, previewHidden(["1 name"]), previewSend, previewCancel,
        spokenAddress("example.com"), spokenLabels(["Accept, application/json"]),
        spokenSignIn("X-Sample", characters: 8),
        spokenMessage(role: "person", text: "Hi"), spokenMessage(role: "agent", text: "Hi"),
        notSent, turnedOff, staysHere, notesUnreadable, forgetEverythingDetail,
        forgotNotesNotWords, forgotWordsNotNotes, forgotAndCloudOff, forgotWordsAndCloudNotNotes,
        forgotNotesAndTasksNotWords, forgotTasksAndWordsNotNotes, forgotTasksNotNotesOrWords,
        forgotTasksAndWordsAndCloudNotNotes, forgetTasksAndWordsDetail, tasksAndWordsForgotten,
        tasksAndWordsAndCloudForgotten, tasksForgottenNotWords,
        forgetEverythingWithSummariesDetail, forgotAndCloudOffNotSummaries,
    ] + askPoints + Redaction.Kind.allCases.map(\.spoken)
}
