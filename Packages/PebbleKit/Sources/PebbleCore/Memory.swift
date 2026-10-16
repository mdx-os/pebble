import Foundation

/// One thing the agent remembers about the person, in plain words.
public struct MemoryNote: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let savedAt: Date

    public init(id: UUID = UUID(), text: String, savedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
    }
}

/// Words for the memory screen.
public enum MemoryWords {
    public static let title = "What I remember"
    public static let empty = "Nothing yet. Anything I remember shows up here, and you can change or remove it."
    public static let forgetTitle = "Forget this"
    public static let forgetEverythingTitle = "Forget everything"
    public static let forgotten = "Gone. I no longer have it."
    public static let needsWords = "There's nothing to remember there."
    public static let tooLong = "That's a lot to hold. Try a shorter note."
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

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default place on this device, inside Application Support.
    public static func onDevice(fileManager: FileManager = .default) throws -> MemoryStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let folder = base.appendingPathComponent("pebble", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
    }

    /// Every note, oldest first.
    public func notes() -> [MemoryNote] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    @discardableResult
    public func remember(_ proposed: String, at date: Date = Date()) throws -> Decision {
        let text: String
        switch Self.clean(proposed) {
        case .success(let t): text = t
        case .failure(let refusal): return refusal.decision
        }
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        let note = MemoryNote(text: text, savedAt: date)
        all.append(note)
        try save(all)
        return .saved(note)
    }

    /// Replace a note's words. The old words do not stay in storage.
    @discardableResult
    public func edit(_ id: UUID, to proposed: String) throws -> Decision {
        let text: String
        switch Self.clean(proposed) {
        case .success(let t): text = t
        case .failure(let refusal): return refusal.decision
        }
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return .notFound }
        let note = MemoryNote(id: id, text: text, savedAt: all[index].savedAt)
        all[index] = note
        try save(all)
        return .saved(note)
    }

    /// Remove one note from storage. Returns false when there was no such note.
    @discardableResult
    public func forget(_ id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
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

    /// Remove every note and the file that held them.
    public func forgetEverything() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeFile()
    }

    // MARK: Storage

    private func load() -> [MemoryNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MemoryNote].self, from: data)) ?? []
    }

    private func save(_ all: [MemoryNote]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(all)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }

    private func removeFile() throws {
        let manager = FileManager.default
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
        if text.count > maxLength { return .failure(.tooLong) }
        return .success(text)
    }
}
