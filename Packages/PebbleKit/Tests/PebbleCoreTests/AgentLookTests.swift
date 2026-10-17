import Foundation
import PebbleCore
import Testing

struct AgentLookTests {
    @Test func aLookIsSavedOnDeviceAndBadValuesFallBack() throws {
        let suite = "pebble.look.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AgentLook.load(from: defaults) == .sunrise)
        AgentLook.tide.save(to: defaults)
        #expect(AgentLook.load(from: defaults) == .tide)
        defaults.set("neon", forKey: AgentLook.storageKey)
        #expect(AgentLook.load(from: defaults) == .sunrise)
    }

    @Test func screenWordsAreFreeOfDashes() {
        var lines = [
            FirstRunWords.hello, FirstRunWords.helloDetail(onDevice: true), FirstRunWords.helloDetail(),
            FirstRunWords.beginTitle,
            FirstRunWords.nameQuestion, FirstRunWords.nameDetail, FirstRunWords.lookQuestion,
            FirstRunWords.lookDetail, FirstRunWords.ideasDetail, FirstRunWords.justChatTitle,
            FirstRunWords.greeting(named: "Pip"),
            ConfirmationWords.heading, ConfirmationWords.promise,
            MemoryWords.title, MemoryWords.empty, MemoryWords.forgetTitle,
            MemoryWords.forgetEverythingTitle, MemoryWords.forgotten,
        ]
        lines += AgentLook.allCases.map(\.title)
        for line in lines {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
        }
    }
}
