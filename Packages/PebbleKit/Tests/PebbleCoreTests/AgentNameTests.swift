import Foundation
import PebbleCore
import Testing

struct AgentNameTests {
    let brand = Brand(name: "Nova")

    @Test func aUsableNameCollapsesWhitespace() throws {
        let name = try accepted("  pip   stone \n")
        #expect(name.text == "pip stone")
        #expect(name.initial == "P")
    }

    @Test func theInitialUsesTheFirstLetter() throws {
        #expect(try accepted("nova").initial == "N")
    }

    @Test func aBlankLineNeedsAName() {
        #expect(AgentName.decide("  \n") == .needsAName)
    }

    @Test func aNameAtTheLimitIsKept() throws {
        let text = String(repeating: "a", count: AgentName.maxLength)
        #expect(try accepted(text).text == text)
    }

    @Test func aLongLineIsRefused() {
        let text = String(repeating: "a", count: AgentName.maxLength + 1)
        #expect(AgentName.decide(text) == .tooLong)
    }

    @Test func theProductNameIsOnlyAStartingPoint() {
        let profile = AgentProfile(brand: brand, stored: nil)
        #expect(!profile.hasChosenName)
        #expect(profile.displayName.text == brand.name)
        #expect(profile.brand == brand)
    }

    @Test func aSavedNameStaysSeparateFromTheProductName() throws {
        let profile = AgentProfile(brand: brand, stored: "  Pip  ")
        #expect(profile.hasChosenName)
        #expect(profile.displayName.text == "Pip")
        #expect(profile.brand.name == brand.name)
        #expect(profile.displayName.text != brand.name)
    }

    @Test func anUnusableStoredNameFallsBackToTheProductName() {
        let stored = String(repeating: "n", count: AgentName.maxLength + 1)
        let profile = AgentProfile(brand: brand, stored: stored)
        #expect(!profile.hasChosenName)
        #expect(profile.displayName.text == brand.name)
    }

    @Test func choosingTheProductWordStillCountsAsASavedName() {
        let profile = AgentProfile(brand: brand, stored: brand.name)
        #expect(profile.hasChosenName)
        #expect(profile.displayName.text == brand.name)
    }

    @Test func anEmptyProductNameHasAVisibleMark() {
        let profile = AgentProfile(brand: Brand(name: "   "), stored: " ")
        #expect(profile.displayName.text == "?")
        #expect(profile.displayName.initial == "?")
    }

    @Test func theStorageKeyIsTheAgentNotAContact() {
        #expect(AgentName.storageKey == "pebble.agent.displayName")
        #expect(!AgentName.storageKey.localizedCaseInsensitiveContains("contact"))
    }

    @Test func renameInvitesUntilANameIsSaved() {
        let store = InMemoryAgentNameStore()
        var naming = AgentRenameState(profile: AgentProfile(brand: brand, stored: store.loadDisplayName()))
        #expect(naming.showsInvitation)
        #expect(naming.renameTitle == FirstConversation.giveNameTitle)
        #expect(store.loadDisplayName() == nil)

        naming.begin()
        #expect(naming.isOpen)
        #expect(naming.draft.isEmpty)
        #expect(!naming.showsInvitation)
        naming.setDraft("   ")
        #expect(naming.confirm() == nil)
        #expect(naming.hint == FirstConversation.needsAName)
        #expect(naming.isOpen)
        #expect(store.loadDisplayName() == nil)

        naming.setDraft(String(repeating: "a", count: AgentName.maxLength + 1))
        #expect(naming.confirm() == nil)
        #expect(naming.hint == FirstConversation.nameTooLong)

        naming.setDraft("  Pip  ")
        guard let chosen = naming.confirm() else {
            Issue.record("expected a name")
            return
        }
        store.saveDisplayName(chosen.text)
        #expect(chosen.text == "Pip")
        #expect(store.loadDisplayName() == "Pip")
        #expect(naming.profile.brand == brand)
        #expect(!naming.showsInvitation)
        #expect(naming.renameTitle == FirstConversation.changeNameTitle)

        let restored = AgentProfile(brand: brand, stored: store.loadDisplayName())
        #expect(restored.displayName.text == "Pip")
        #expect(restored.brand.name == brand.name)
    }

    @Test func cancelLeavesTheSavedNameAlone() {
        var naming = AgentRenameState(profile: AgentProfile(brand: brand, stored: nil))
        naming.begin()
        naming.setDraft("Pip")
        naming.cancel()
        #expect(!naming.isOpen)
        #expect(naming.draft.isEmpty)
        #expect(!naming.profile.hasChosenName)
    }

    @Test func aSecondNameReplacesTheFirst() throws {
        var naming = AgentRenameState(profile: AgentProfile(brand: brand, chosen: try accepted("Pip")))
        naming.begin()
        #expect(naming.draft == "Pip")
        naming.setDraft("Ada")
        let renamed = naming.confirm()
        #expect(renamed?.text == "Ada")
        #expect(naming.profile.displayName.text == "Ada")
        #expect(naming.profile.brand == brand)
    }

    @Test func userDefaultsStoresTheNameOnDevice() throws {
        let suite = "pebble.agent-name.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentNameStore(defaults: defaults)
        #expect(store.loadDisplayName() == nil)
        store.saveDisplayName("Pip")
        #expect(store.loadDisplayName() == "Pip")
        #expect(defaults.string(forKey: AgentName.storageKey) == "Pip")
        let contactKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.localizedCaseInsensitiveContains("contact")
        }
        for key in contactKeys {
            #expect(defaults.string(forKey: key) != "Pip")
        }
    }

    private func accepted(_ proposed: String) throws -> AgentName {
        guard case .accepted(let name) = AgentName.decide(proposed) else {
            Issue.record("expected a usable name")
            struct ExpectedName: Error {}
            throw ExpectedName()
        }
        return name
    }
}
