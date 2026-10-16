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

    @Test func choicesNothingHonorsYetAreNotOffered() {
        // The flow never reaches the proactivity step while only one choice
        // is offered; storage refusing unoffered values is tested below.
        #expect(!Proactivity.checkIn.isOffered && !Proactivity.suggest.isOffered)
        var flow = OnboardingFlow()
        flow.skip()
        #expect(flow.step == .starters)
        flow.chooseProactivity(.suggest)
        #expect(flow.proactivity == .quiet)
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
        lines += [FirstConversation.needsAName, FirstConversation.nameTooLong]
        for job in FirstConversation.jobs { lines += [job.title, job.prompt] }
        for line in lines {
            #expect(!line.isEmpty)
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
        }
        #expect(Set(Proactivity.allCases.map(\.title)).count == Proactivity.allCases.count)
    }

    @Test func noWordsSayTheAgentWatches() {
        var lines = [OnboardingWords.welcome, OnboardingWords.proactivityQuestion, OnboardingWords.startersHeading]
        for choice in Proactivity.allCases { lines += [choice.title, choice.detail] }
        for line in lines {
            for word in ["notice", "watch", "monitor", "see what you"] {
                #expect(!line.localizedCaseInsensitiveContains(word), "\(word) in: \(line)")
            }
        }
    }

    @Test func finishingIsRememberedEvenWhenEverythingWasSkipped() {
        let store = InMemoryOnboardingStore()
        let names = InMemoryAgentNameStore()
        var flow = OnboardingFlow()
        flow.save(to: store, names: names)
        #expect(!store.hasFinished())
        flow.skip(); flow.skip()
        flow.save(to: store, names: names)
        #expect(store.hasFinished())
        #expect(store.loadProactivity() == .quiet)
        #expect(names.loadDisplayName() == nil)
        #expect(!OnboardingFlow.isNeeded(store: store, names: names))
    }

    @Test func theChosenNameIsSavedWithTheFirstRun() {
        let store = InMemoryOnboardingStore()
        let names = InMemoryAgentNameStore()
        var flow = OnboardingFlow()
        _ = flow.chooseName(" Pip ")
        flow.skip()
        flow.save(to: store, names: names)
        #expect(names.loadDisplayName() == "Pip")
    }

    @Test func someoneWhoAlreadyNamedTheirAgentSkipsTheFirstRun() {
        #expect(OnboardingFlow.isNeeded(store: InMemoryOnboardingStore(), names: InMemoryAgentNameStore()))
        #expect(!OnboardingFlow.isNeeded(store: InMemoryOnboardingStore(), names: InMemoryAgentNameStore(stored: "Pip")))
    }

    @Test func resetForgetsEveryFirstRunChoice() throws {
        let suite = "pebble.onboarding.reset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOnboardingStore(defaults: defaults)
        store.saveProactivity(.quiet)
        store.markFinished()
        store.reset()
        #expect(!store.hasFinished())
        #expect(defaults.object(forKey: OnboardingStorageKeys.finished) == nil)
        #expect(defaults.object(forKey: Proactivity.storageKey) == nil)
        let memory = InMemoryOnboardingStore(finished: true)
        memory.reset()
        #expect(!memory.hasFinished())
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
