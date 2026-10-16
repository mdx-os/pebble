import Foundation
import PebbleCore
import Testing

struct OnboardingTests {
    @Test func theFirstRunGoesNameThenProactivityThenStarters() throws {
        var flow = OnboardingFlow()
        #expect(flow.step == .name)
        let named = flow.chooseName("  Pip ")
        #expect(named)
        #expect(flow.name?.text == "Pip")
        #expect(flow.step == .proactivity)
        flow.chooseProactivity(.checkIn)
        #expect(flow.proactivity == .checkIn)
        #expect(flow.step == .starters)
        #expect(!flow.starters.isEmpty)
        let first = try #require(flow.starters.first)
        let picked = flow.pickStarter(first.id)
        #expect(picked == first.prompt)
        #expect(flow.step == .done)
    }

    @Test func anUnusableNameStaysOnTheNameStep() {
        var flow = OnboardingFlow()
        let blank = flow.chooseName("   ")
        #expect(!blank)
        #expect(flow.hint == FirstConversation.needsAName)
        let long = flow.chooseName(String(repeating: "a", count: AgentName.maxLength + 1))
        #expect(!long)
        #expect(flow.hint == FirstConversation.nameTooLong)
        #expect(flow.step == .name)
        #expect(flow.name == nil)
        let named = flow.chooseName("Pip")
        #expect(named)
        #expect(flow.hint == nil)
    }

    @Test func skippingKeepsGentleDefaultsAndStillOffersIdeas() {
        var flow = OnboardingFlow()
        flow.skip()
        flow.skip()
        #expect(flow.name == nil)
        #expect(flow.proactivity == .quiet)
        #expect(flow.step == .starters)
        #expect(!flow.starters.isEmpty)
        flow.skip()
        #expect(flow.step == .done)
    }

    @Test func choicesOutOfOrderAreIgnored() {
        var flow = OnboardingFlow()
        flow.chooseProactivity(.suggest)
        #expect(flow.proactivity == .quiet)
        let pickedEarly = flow.pickStarter("morning")
        #expect(pickedEarly == nil)
        #expect(flow.step == .name)
    }

    @Test func anUnknownStarterIsIgnored() {
        var flow = OnboardingFlow()
        flow.skip(); flow.skip()
        let pickedUnknown = flow.pickStarter("nope")
        #expect(pickedUnknown == nil)
        #expect(flow.step == .starters)
    }

    @Test func everyProactivityChoiceHasPlainWords() {
        for choice in Proactivity.allCases {
            #expect(!choice.title.isEmpty && !choice.detail.isEmpty)
            #expect(!(choice.title + choice.detail).contains("\u{2014}"))
        }
        #expect(Set(Proactivity.allCases.map(\.title)).count == Proactivity.allCases.count)
    }

    @Test func proactivityIsSavedOnDevice() throws {
        let suite = "pebble.proactivity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProactivityStore(defaults: defaults)
        #expect(store.load() == .quiet)
        store.save(.suggest)
        #expect(ProactivityStore(defaults: defaults).load() == .suggest)
        defaults.set("loud", forKey: Proactivity.storageKey)
        #expect(store.load() == .quiet)
    }
}
