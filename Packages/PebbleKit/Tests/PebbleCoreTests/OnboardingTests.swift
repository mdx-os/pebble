import Foundation
import PebbleCore
import Testing

struct OnboardingTests {
    @Test func theFirstRunGoesFromNameToStarters() throws {
        var flow = OnboardingFlow()
        #expect(flow.step == .name)
        let named = flow.chooseName("  Pip ")
        #expect(named)
        #expect(flow.name?.text == "Pip")
        // Only one proactivity choice is honored today, so there is no question to ask.
        #expect(Proactivity.offered == [.quiet])
        #expect(flow.step == .starters)
        #expect(!flow.starters.isEmpty)
        let first = try #require(flow.starters.first)
        let picked = flow.pickStarter(first.id)
        #expect(picked == first.prompt)
        #expect(flow.step == .done)
    }

    @Test func choicesNothingHonorsYetCannotBePicked() {
        var flow = OnboardingFlow()
        flow.chooseProactivity(.suggest)
        flow.chooseProactivity(.checkIn)
        #expect(flow.proactivity == .quiet)
        #expect(!Proactivity.checkIn.isOffered && !Proactivity.suggest.isOffered)
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
        #expect(flow.name == nil)
        #expect(flow.proactivity == .quiet)
        #expect(flow.step == .starters)
        #expect(!flow.starters.isEmpty)
        flow.skip()
        #expect(flow.step == .done)
    }

    @Test func startersCannotBePickedBeforeTheirStep() {
        var flow = OnboardingFlow()
        let early = flow.pickStarter("morning")
        #expect(early == nil)
        #expect(flow.step == .name)
    }

    @Test func anUnknownStarterIsIgnored() {
        var flow = OnboardingFlow()
        flow.skip()
        let unknown = flow.pickStarter("nope")
        #expect(unknown == nil)
        #expect(flow.step == .starters)
    }

    @Test func allFirstRunWordsAreFreeOfDashes() {
        var lines = [
            OnboardingWords.welcome, OnboardingWords.proactivityQuestion,
            OnboardingWords.startersHeading, OnboardingWords.continueTitle, OnboardingWords.skipTitle,
        ]
        for choice in Proactivity.allCases { lines += [choice.title, choice.detail] }
        for line in lines {
            #expect(!line.isEmpty)
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
        }
        #expect(Set(Proactivity.allCases.map(\.title)).count == Proactivity.allCases.count)
    }

    @Test func noChoiceSaysTheAgentWatches() {
        for choice in Proactivity.allCases {
            #expect(!choice.detail.localizedCaseInsensitiveContains("notice"))
        }
    }

    @Test func finishingIsRememberedEvenWhenEverythingWasSkipped() {
        let store = InMemoryOnboardingStore()
        var flow = OnboardingFlow()
        flow.save(to: store)
        #expect(!store.hasFinished())
        flow.skip(); flow.skip()
        flow.save(to: store)
        #expect(store.hasFinished())
        #expect(store.loadProactivity() == .quiet)
    }

    @Test func userDefaultsKeepsTheFirstRunOnDevice() throws {
        let suite = "pebble.onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        #expect(store.loadProactivity() == .quiet)
        #expect(!store.hasFinished())
        store.markFinished()
        #expect(UserDefaultsOnboardingStore(defaults: defaults).hasFinished())
        defaults.set("loud", forKey: Proactivity.storageKey)
        #expect(store.loadProactivity() == .quiet)
        defaults.set(Proactivity.suggest.rawValue, forKey: Proactivity.storageKey)
        #expect(store.loadProactivity() == .quiet)
    }
}
