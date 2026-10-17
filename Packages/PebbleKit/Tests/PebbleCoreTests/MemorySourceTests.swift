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
        try store.remember("Sam's birthday is in May", source: .toldMe)
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

    @Test func editingANoteKeepsItsSource() throws {
        let store = try scratch()
        guard case .saved(let guess) = try store.remember("Prefers tea", source: .inferred) else {
            Issue.record("not saved"); return
        }
        try store.edit(guess.id, to: "Prefers coffee")
        #expect(store.notes().first?.source == .inferred)
    }

    @Test func theOnDiskFormatIsPinned() throws {
        let json = #"""
        [{"id":"A1000000-0000-4000-8000-000000000001","savedAt":0,"source":{"kind":"toldMe"},"text":"a"},
         {"id":"A1000000-0000-4000-8000-000000000002","savedAt":0,"source":{"app":"Calendar","kind":"fromApp"},"text":"b"},
         {"id":"A1000000-0000-4000-8000-000000000003","savedAt":0,"source":{"kind":"inferred"},"text":"c"}]
        """#
        let notes = try JSONDecoder().decode([MemoryNote].self, from: Data(json.utf8))
        #expect(notes.map(\.source) == [.toldMe, .fromApp("Calendar"), .inferred])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let written = String(decoding: try encoder.encode(notes[1].source), as: UTF8.self)
        #expect(written == #"{"app":"Calendar","kind":"fromApp"}"#)
        #expect(String(decoding: try encoder.encode(MemorySource.toldMe), as: UTF8.self) == #"{"kind":"toldMe"}"#)
        #expect(String(decoding: try encoder.encode(MemorySource.inferred), as: UTF8.self) == #"{"kind":"inferred"}"#)
    }

    @Test func anUnknownSourceReadsAsInferredWithoutBreakingTheFile() throws {
        let store = try scratch()
        let json = #"[{"id":"A1000000-0000-4000-8000-000000000004","savedAt":0,"source":{"kind":"telepathy"},"text":"x"},{"id":"A1000000-0000-4000-8000-000000000005","savedAt":0,"source":"garbled","text":"y"}]"#
        try Data(json.utf8).write(to: store.fileURL)
        #expect(store.notes().map(\.source) == [.inferred, .inferred])
    }

    @Test func savingTheSameWordsKeepsWhereItCameFromToo() throws {
        let store = try scratch()
        guard case .saved(let guess) = try store.remember("Prefers tea", source: .inferred) else {
            Issue.record("not saved"); return
        }
        try store.edit(guess.id, to: "  Prefers tea ")
        #expect(store.notes().first?.source == .inferred)
    }

    @Test func labelsReadPlainly() {
        #expect(MemorySource.toldMe.label == "You told me")
        #expect(MemorySource.fromApp("Calendar").label == "From Calendar")
        #expect(MemorySource.fromApp("  ").label == "From an app")
        #expect(MemorySource.inferred.label == "My guess")
        let long = MemorySource.fromApp(String(repeating: "x", count: 80)).label
        #expect(long.count <= "From ".count + MemorySource.maxAppNameLength + 3)
        for s in [MemorySource.toldMe, .fromApp("Mail\nApp"), .inferred] {
            #expect(!s.label.contains("\u{2014}") && !s.label.contains("\u{2013}") && !s.label.contains("\n"))
        }
    }
}
