import Foundation
@testable import PebbleCore
import SourceScan
import Testing

/// The app has one notes store, so every writer, the memory screen, the
/// cloud redactor and the task engine alike, is heard by everything that
/// watches it. `MemoryStore.onDevice()` gives the same store every time,
/// its plain init is package-only so the app can't make another, and the
/// only other makers in the package are the store's own and the
/// showcase's, which is Debug only and never touches real notes.
struct OneNotesStoreTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Code only: comments and words in strings are blanked.
    func code(_ file: URL) throws -> String {
        String(SwiftSource(try String(contentsOf: file, encoding: .utf8)).code)
    }

    func swiftFiles(in folder: URL) throws -> [URL] {
        try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func theAppMakesOneNotesStore() throws {
        let app = Self.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let appFiles = try swiftFiles(in: app)
        #expect(!appFiles.isEmpty)
        var opened = 0
        for file in appFiles {
            let text = try code(file)
            opened += text.components(separatedBy: "MemoryStore.onDevice(").count - 1
            #expect(!text.contains("MemoryStore(fileURL"), "\(file.lastPathComponent) makes a store")
        }
        #expect(opened == 1)
        let makers = try swiftFiles(in: Self.root.appendingPathComponent("Sources")).filter {
            try code($0).contains("MemoryStore(fileURL")
        }.map(\.lastPathComponent).sorted()
        #expect(makers == ["Memory.swift", "ShowcaseScene.swift"])
        let showcase = try String(contentsOf: Self.root.appendingPathComponent("Sources/PebbleUI/ShowcaseScene.swift"),
                                  encoding: .utf8)
        #expect(showcase.contains("#if canImport(SwiftUI) && DEBUG"))
    }
}

struct MemoryStoreTests {
    let folder: URL
    let store: MemoryStore

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
    }

    @Test func aNewStoreRemembersNothing() {
        #expect(store.notes().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func aNoteIsVisibleAndSurvivesARestart() throws {
        let note = try saved(store.remember("  Sam's birthday is in May \n", source: .toldMe))
        #expect(note.text == "Sam's birthday is in May")
        #expect(store.notes() == [note])
        let reopened = MemoryStore(fileURL: store.fileURL)
        #expect(reopened.notes() == [note])
    }

    @Test func blankAndOverlongNotesAreRefused() throws {
        #expect(try store.remember("   ", source: .toldMe) == .needsWords)
        #expect(try store.remember(String(repeating: "a", count: MemoryStore.maxLength + 1), source: .toldMe) == .tooLong)
        #expect(store.notes().isEmpty)
    }

    @Test func forgettingANotePurgesItsWordsFromStorage() throws {
        let keep = try saved(store.remember("Prefers tea", source: .toldMe))
        let secret = try saved(store.remember("Door code 4417", source: .toldMe))
        #expect(try store.forget(secret.id))
        #expect(store.notes() == [keep])
        #expect(MemoryStore(fileURL: store.fileURL).notes() == [keep])
        #expect(!folderContains("4417"))
        #expect(folderContains("Prefers tea"))
    }

    @Test func forgettingTheLastNoteRemovesTheFile() throws {
        let only = try saved(store.remember("Door code 4417", source: .toldMe))
        #expect(try store.forget(only.id))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!folderContains("4417"))
    }

    @Test func forgettingSomethingUnknownChangesNothing() throws {
        let note = try saved(store.remember("Prefers tea", source: .toldMe))
        #expect(try store.forget(UUID()) == false)
        #expect(store.notes() == [note])
    }

    @Test func editingLeavesNoTraceOfTheOldWords() throws {
        let note = try saved(store.remember("Lives on Elm Street", source: .toldMe))
        let edited = try saved(store.edit(note.id, to: "Lives downtown"))
        #expect(edited.id == note.id)
        #expect(store.notes().map(\.text) == ["Lives downtown"])
        #expect(!folderContains("Elm Street"))
        #expect(try store.edit(UUID(), to: "x") == .notFound)
        #expect(try store.edit(note.id, to: " ") == .needsWords)
        #expect(store.notes().map(\.text) == ["Lives downtown"])
    }

    @Test func forgetEverythingLeavesNothingBehind() throws {
        try store.remember("Door code 4417", source: .toldMe)
        try store.remember("Sam's birthday is in May", source: .toldMe)
        try store.forgetEverything()
        #expect(store.notes().isEmpty)
        #expect(MemoryStore(fileURL: store.fileURL).notes().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
    }

    @Test func anUnreadableFileIsNeverOverwritten() throws {
        let garbage = Data("not notes {".utf8)
        try garbage.write(to: store.fileURL)
        #expect(store.notes().isEmpty)
        #expect(throws: MemoryStore.Unreadable.self) { try store.remember("Prefers tea", source: .toldMe) }
        #expect(throws: MemoryStore.Unreadable.self) { try store.edit(UUID(), to: "x") }
        #expect(throws: MemoryStore.Unreadable.self) { try store.forget(UUID()) }
        // The refusal comes first, before the words are even checked.
        #expect(throws: MemoryStore.Unreadable.self) { try store.remember("   ", source: .toldMe) }
        #expect(throws: MemoryStore.Unreadable.self) { try store.edit(UUID(), to: "   ") }
        #expect(FileManager.default.contents(atPath: store.fileURL.path) == garbage)
    }

    @Test func anUnreadableFileIsNotShownAsAnEmptyMemory() throws {
        #expect(store.contents() == .notes([]))
        try Data("not notes {".utf8).write(to: store.fileURL)
        #expect(store.contents() == .unreadable)
        #expect(store.hasStoredFile)
    }

    @Test func aStagedCopyFromAnInterruptedSaveDoesNotOutliveAForget() throws {
        let note = try saved(store.remember("Door code 4417", source: .toldMe))
        try store.remember("Prefers tea", source: .toldMe)
        // Simulate a save that stopped after staging.
        try Data("Door code 4417".utf8).write(to: store.stagingURL)
        #expect(try store.forget(note.id))
        #expect(!folderContains("4417"))
    }

    @Test func aStagedCopyWithNoRealFileIsVisibleUntilClearedOnRead() throws {
        try Data("Door code 4417".utf8).write(to: store.stagingURL)
        #expect(store.hasStoredFile)
        #expect(store.contents() == .notes([]))
        #expect(!folderContains("4417"))
        #expect(!store.hasStoredFile)
    }

    @Test func aNoteHeavyWithHiddenMarksIsTooLong() throws {
        let heavy = "a" + String(repeating: "\u{0301}", count: 5_000)
        #expect(heavy.count == 1)
        #expect(try store.remember(heavy, source: .toldMe) == .tooLong)
    }

    @Test func forgetEverythingAlsoClearsAStagedCopy() throws {
        try store.remember("Door code 4417", source: .toldMe)
        try Data("Door code 4417".utf8).write(to: store.stagingURL)
        try store.forgetEverything()
        #expect(!folderContains("4417"))
    }

    @Test func forgetEverythingLeavesOtherFilesInTheFolderAlone() throws {
        let neighbor = folder.appendingPathComponent("memory-photos.db")
        try Data("keep".utf8).write(to: neighbor)
        try store.remember("Prefers tea", source: .toldMe)
        try store.forgetEverything()
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
    }

    @Test func forgetEverythingClearsAnUnreadableFileToo() throws {
        try Data("not notes {".utf8).write(to: store.fileURL)
        try store.forgetEverything()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The same words from the same source are kept once. The same words
    /// the person typed are theirs, so they don't count.
    @Test func rememberOnceKeepsTheSameWordsOnce() throws {
        let typed = try saved(store.remember("Tea at four", source: .toldMe))
        let first = try store.rememberOnce("Tea at four", source: .inferred)
        #expect(first.isNew)
        let again = try store.rememberOnce(" Tea at four ", source: .inferred)
        #expect(!again.isNew)
        #expect(again.decision == first.decision)
        #expect(store.notes().count == 2)
        #expect(store.notes().first == typed)
        #expect(try store.rememberOnce("  ", source: .inferred) == (.needsWords, false))
        #expect(try store.rememberOnce(String(repeating: "a", count: MemoryStore.maxLength + 1),
                                       source: .inferred) == (.tooLong, false))
    }

    /// Every change, from any writer, is told to whoever watches, and only
    /// changes are. Nothing is told once the watch is let go.
    @Test func everyChangeIsTold() throws {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func add() { lock.lock(); value += 1; lock.unlock() }
            var now: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let count = Count()
        var watch: TaskObservation? = store.observeChanges { count.add() }
        let note = try saved(store.remember("Prefers tea", source: .toldMe))
        #expect(count.now == 1)
        _ = try store.edit(note.id, to: "Prefers green tea")
        #expect(count.now == 2)
        _ = try store.edit(note.id, to: " ")
        _ = try store.rememberOnce("Prefers green tea", source: .toldMe)
        #expect(try !store.forget(UUID()))
        #expect(count.now == 2)
        #expect(try store.forget(note.id))
        #expect(count.now == 3)
        try store.forgetEverything()
        #expect(count.now == 4)
        _ = watch
        watch = nil
        _ = try store.remember("Later", source: .toldMe)
        #expect(count.now == 4)
    }

    private func saved(_ decision: MemoryStore.Decision) throws -> MemoryNote {
        guard case .saved(let note) = decision else {
            Issue.record("expected a saved note, got \(decision)")
            struct NotSaved: Error {}
            throw NotSaved()
        }
        return note
    }

    /// True when any file in the store's folder holds these words.
    private func folderContains(_ words: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { name in
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path)
            else { return false }
            return String(decoding: data, as: UTF8.self).contains(words)
        }
    }
}
