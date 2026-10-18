import Foundation

/// One thing the agent remembers about the person, in plain words.
public struct MemoryNote: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let savedAt: Date
    /// Where the note came from, shown next to it so the person can judge it.
    public let source: MemorySource

    public init(id: UUID = UUID(), text: String, savedAt: Date = Date(), source: MemorySource) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, text, savedAt, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        if !c.contains(.source) {
            // Notes saved before sources existed were all typed by the person.
            source = .toldMe
        } else {
            // A source this version can't read falls back to the least trusted label.
            source = (try? c.decode(MemorySource.self, forKey: .source)) ?? .inferred
        }
    }
}

/// Where a memory came from.
///
/// On disk this is `{"kind":"toldMe"}`, `{"kind":"fromApp","app":"Calendar"}`
/// or `{"kind":"inferred"}`. `MemorySourceTests` pins that format. An unknown
/// kind reads as `inferred`, the least trusted label, rather than breaking
/// the file.
public enum MemorySource: Codable, Sendable, Equatable, Hashable {
    /// The person said or typed it.
    case toldMe
    /// Read from a connected app, such as Calendar.
    case fromApp(String)
    /// The agent worked it out. It may be wrong.
    case inferred

    public static let maxAppNameLength = 30

    private enum CodingKeys: String, CodingKey { case kind, app }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) {
        case "toldMe": self = .toldMe
        case "fromApp": self = .fromApp(try c.decodeIfPresent(String.self, forKey: .app) ?? "")
        default: self = .inferred
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toldMe: try c.encode("toldMe", forKey: .kind)
        case .fromApp(let app):
            try c.encode("fromApp", forKey: .kind)
            try c.encode(app, forKey: .app)
        case .inferred: try c.encode("inferred", forKey: .kind)
        }
    }

    /// The label shown next to the note.
    public var label: String {
        switch self {
        case .toldMe: return "You told me"
        case .fromApp(let name):
            let tidy = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            guard !tidy.isEmpty else { return "From an app" }
            return "From \(tidy.count > Self.maxAppNameLength ? String(tidy.prefix(Self.maxAppNameLength)) + "..." : tidy)"
        case .inferred: return "My guess"
        }
    }

    /// SF Symbol for the label.
    public var symbol: String {
        switch self {
        case .toldMe: return "person.wave.2"
        case .fromApp: return "app.connected.to.app.below.fill"
        case .inferred: return "sparkles"
        }
    }
}

/// Words for the memory screen.
public enum MemoryWords {
    public static let title = "What I remember"
    public static let emptyTitle = "Nothing here yet"
    // The device promise in `empty`, `saved` and `privacyNote` is made only
    // when `place` says every word stays here. Notes live only in
    // `MemoryStore`'s file, left out of backups, and nothing passes them to a
    // `ModelClient`, but a cloud model would still hear the chat, so the
    // promise follows the model, not the notes.
    public static func empty(_ place: PrivacyPlace) -> String {
        place.staysOnDevice
            ? "Tell me something worth keeping, like a birthday or how you take your tea. It stays on this device, and you can change or remove it anytime."
            : "Tell me something worth keeping, like a birthday or how you take your tea. You can change or remove it anytime."
    }
    public static let emptyActionTitle = "Add your first note"
    public static let forgetTitle = "Forget this"
    public static let forgetEverythingTitle = "Forget everything"
    /// See the note above `empty`.
    public static func saved(_ place: PrivacyPlace) -> String {
        place.staysOnDevice ? "Saved. It stays on this device." : "Saved."
    }
    public static let forgotten = "Gone. I no longer have it."
    public static let needsWords = "Type a few words first, and I'll keep them."
    public static let tooLong = "That's a lot for one note. Try splitting it into shorter ones."
    public static let editTitle = "Change"
    public static let saveTitle = "Save"
    public static let cancelTitle = "Cancel"
    public static let doneTitle = "Done"
    public static let addPlaceholder = "Something for me to remember"
    public static let addTitle = "Remember"
    public static let forgetEverythingQuestion = "Forget everything I remember?"
    // Says "this device" without asking `place`, and that is on purpose.
    // It is about where the notes and tasks are, not where the chat goes:
    // notes live only in `MemoryStore`'s local file and tasks only in the
    // engine on this device, whatever the model is, so this is true even
    // with a cloud model. It makes no promise about the chat. Don't gate it
    // like the lines above. Forget everything forgets tasks too, so it says
    // running ones stop, and it turns background work off and erases its
    // summaries, kept in the same folder as the notes.
    public static let forgetEverythingDetail = "This removes every note, every task and every morning summary from this device, stops any task still going, and turns off work while you're away. It can't be undone."
    /// See the note above `empty`.
    public static func privacyNote(_ place: PrivacyPlace) -> String {
        place.staysOnDevice ? "Kept only on this device. Removing a note erases it." : "Removing a note erases it."
    }
    /// Shown while adding is turned off, so the saved notes stay as they are.
    public static let unreadable = "Sorry, I can't read the notes I saved. I've left them untouched, so I won't add new ones for now. If this keeps happening, Forget everything clears them so we can start fresh."
    public static let unavailable = "I can't open my notes just now, usually because the device is locked. Unlock it, and I'll look again."
    /// When the notes folder couldn't be opened at launch. It is only
    /// opened again the next time the app starts.
    public static let couldNotOpen = "Sorry, I can't open my notes right now. Closing and reopening the app may help."
    public static let tryAgainTitle = "Try again"
    public static let forgetOneQuestion = "Forget this note?"
    public static let editPlaceholder = "What should I remember instead?"
    public static let couldNotForget = "Sorry, I couldn't erase that just now. Please try again in a moment."
    /// Forget everything when the tasks went but the notes couldn't be erased.
    public static let couldNotForgetNotes = "I forgot your tasks, but I couldn't erase your notes just now. Please try again in a moment."
    /// Forget everything when the rest went but the morning summaries'
    /// file couldn't be erased. Work while you're away is off either way.
    public static let couldNotForgetSummaries = "I forgot the rest and turned off work while you're away, but I couldn't erase your morning summaries just now. Please try again in a moment."
}

/// Notes the agent keeps, stored only on this device.
///
/// The person can see every note, change it, and remove it. Removing a note
/// rewrites the file without it, so the words are gone from storage, not
/// hidden behind a flag. Forgetting everything deletes the file.
public final class MemoryStore: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case saved(MemoryNote)
        case needsWords
        case tooLong
        case notFound
    }

    public static let maxLength = 500
    /// Size cap in bytes, so a short looking note can't carry megabytes.
    public static let maxBytes = 4_096

    /// The file is there but its words can't be decoded. Writes refuse rather
    /// than replace notes that may still be recoverable.
    public struct Unreadable: Error, Equatable {}

    /// The file is there but can't be opened right now, for example while an
    /// iPhone is locked. Try again later; this is not damage.
    public struct Unavailable: Error, Equatable {}

    /// What the memory screen should show.
    public enum Contents: Equatable, Sendable {
        case notes([MemoryNote])
        case unreadable
        case unavailable
    }

    public let fileURL: URL
    private let lock = NSLock()

    /// Package access: the app uses `onDevice()` so there is one store per
    /// file. Tests and screenshots point a store at a scratch file.
    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The only other file this store ever writes: the next version of the
    /// notes, staged next to the real file and renamed over it.
    var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: MemoryStore?

    /// The one store on this device, inside Application Support and left out
    /// of iCloud, Finder and Time Machine backups. Every caller gets the same
    /// instance so writes never interleave.
    public static func onDevice(fileManager: FileManager = .default) throws -> MemoryStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let store = MemoryStore(fileURL: try folder(fileManager: fileManager).appendingPathComponent("memory.json"))
        shared = store
        return store
    }

    /// The notes' folder inside Application Support, made if need be and
    /// left out of backups. The background runner keeps its file here too.
    public static func folder(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        var folder = base.appendingPathComponent("pebble", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try excludeFromBackup(&folder)
        return folder
    }

    /// Marks a folder so backups skip it. Notes stay on this device only.
    public static func excludeFromBackup(_ folder: inout URL) throws {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #endif
    }

    /// Every note, oldest first. Empty when the file can't be read; use
    /// `contents()` to tell an empty memory from an unreadable one.
    public func notes() -> [MemoryNote] {
        if case .notes(let all) = contents() { return all }
        return []
    }

    /// Every note, or why they can't be shown right now.
    public func contents() -> Contents {
        lock.lock()
        defer { lock.unlock() }
        // A staged copy left by an interrupted save is never newer than the
        // real file, and it can't be seen, so drop it.
        try? removeStaged()
        do {
            return .notes(try load())
        } catch is Unavailable {
            return .unavailable
        } catch {
            return .unreadable
        }
    }

    /// True when there is anything on disk to forget, readable or not.
    public var hasStoredFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: stagingURL.path)
    }

    /// Adds a note. Every writer comes through here, so notes that can't be
    /// read or opened are refused first, before the words are even looked
    /// at, and the file is never touched.
    @discardableResult
    public func remember(_ proposed: String, at date: Date = Date(), source: MemorySource) throws -> Decision {
        lock.lock()
        defer { lock.unlock() }
        var all = try load()
        let text: String
        switch Self.clean(proposed) {
        case .success(let t): text = t
        case .failure(let refusal): return refusal.decision
        }
        let note = MemoryNote(text: text, savedAt: date, source: source)
        all.append(note)
        try save(all)
        return .saved(note)
    }

    /// Replace a note's words. The old words do not stay in storage.
    @discardableResult
    public func edit(_ id: UUID, to proposed: String) throws -> Decision {
        lock.lock()
        defer { lock.unlock() }
        var all = try load()
        let text: String
        switch Self.clean(proposed) {
        case .success(let t): text = t
        case .failure(let refusal): return refusal.decision
        }
        guard let index = all.firstIndex(where: { $0.id == id }) else { return .notFound }
        // Editing keeps where the note came from.
        let old = all[index]
        let note = MemoryNote(id: id, text: text, savedAt: old.savedAt, source: old.source)
        all[index] = note
        try save(all)
        return .saved(note)
    }

    /// Remove one note from storage. Returns false when there was no such note.
    @discardableResult
    public func forget(_ id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = try load()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return false }
        if all.isEmpty {
            try removeFile()
        } else {
            try save(all)
        }
        return true
    }

    /// Remove every note and the file that held them, even an unreadable
    /// one, along with any staged copy from an interrupted save.
    public func forgetEverything() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeFile()
    }

    // MARK: Storage

    private func load() throws -> [MemoryNote] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { throw Unavailable() }
        guard let all = try? JSONDecoder().decode([MemoryNote].self, from: data) else { throw Unreadable() }
        return all
    }

    private func save(_ all: [MemoryNote]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(all)
        // Stage under one known name, then rename over the real file. The
        // system never makes a copy somewhere this store can't clean up.
        try removeStaged()
        #if os(macOS)
        try data.write(to: stagingURL, options: [.withoutOverwriting])
        #else
        try data.write(to: stagingURL, options: [.withoutOverwriting, .completeFileProtection])
        #endif
        guard rename(stagingURL.path, fileURL.path) == 0 else {
            try? removeStaged()
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func removeStaged() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: stagingURL.path) {
            try manager.removeItem(at: stagingURL)
        }
    }

    private func removeFile() throws {
        let manager = FileManager.default
        try removeStaged()
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
    }

    private enum Refusal: Error {
        case needsWords, tooLong
        var decision: Decision { self == .needsWords ? .needsWords : .tooLong }
    }

    private static func clean(_ proposed: String) -> Result<String, Refusal> {
        let text = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.needsWords) }
        if text.count > maxLength || text.utf8.count > maxBytes { return .failure(.tooLong) }
        return .success(text)
    }
}
