import Foundation
@testable import PebbleCore
import Testing

struct MemorySourceTests {
    func scratch() throws -> MemoryStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
    }

    @Test func eachSourceIsSavedAndReadBack() throws {
        let store = try scratch()
        try store.remember("Sam's birthday is in May")
        try store.remember("Dentist Thursday", source: .fromApp("Calendar"))
        try store.remember("Prefers tea", source: .inferred)
        let reopened = MemoryStore(fileURL: store.fileURL)
        #expect(reopened.notes().map(\.source) == [.toldMe, .fromApp("Calendar"), .inferred])
    }

    @Test func notesSavedBeforeSourcesCountAsToldMe() throws {
        let store = try scratch()
        let old = #"[{"id":"A1000000-0000-4000-8000-000000000009","savedAt":0,"text":"Prefers tea"}]"#
        try Data(old.utf8).write(to: store.fileURL)
        #expect(store.notes().first?.source == .toldMe)
        #expect(store.contents() != .unreadable)
    }

    @Test func rewritingANoteMakesItYourWords() throws {
        let store = try scratch()
        guard case .saved(let guess) = try store.remember("Prefers tea", source: .inferred) else {
            Issue.record("not saved"); return
        }
        try store.edit(guess.id, to: "Prefers coffee")
        #expect(store.notes().first?.source == .toldMe)
    }

    @Test func labelsReadPlainly() {
        #expect(MemorySource.toldMe.label == "You told me")
        #expect(MemorySource.fromApp("Calendar").label == "From Calendar")
        #expect(MemorySource.fromApp("  ").label == "From an app")
        #expect(MemorySource.inferred.label == "I inferred this")
        let long = MemorySource.fromApp(String(repeating: "x", count: 80)).label
        #expect(long.count <= "From ".count + MemorySource.maxAppNameLength + 3)
        for s in [MemorySource.toldMe, .fromApp("Mail\nApp"), .inferred] {
            #expect(!s.label.contains("\u{2014}") && !s.label.contains("\u{2013}") && !s.label.contains("\n"))
        }
    }
}
