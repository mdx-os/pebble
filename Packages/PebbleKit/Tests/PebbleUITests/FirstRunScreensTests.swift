#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

@MainActor
struct FirstRunScreensTests {
    let brand = Brand(name: "Nova")

    @Test(arguments: ShowcaseScene.allCases, [ColorScheme.light, .dark])
    func everyScreenRendersInLightAndDark(scene: ShowcaseScene, scheme: ColorScheme) throws {
        let size = CGSize(width: 393, height: 852)
        let renderer = ImageRenderer(content: scene.view(brand: brand)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height))
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size.width * renderer.scale))
    }

    @Test func finishingTheFirstRunSavesNameLookAndFlag() throws {
        let suite = "pebble.ui.onboarding.\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let names = InMemoryAgentNameStore()
        let store = InMemoryOnboardingStore()
        var sent: String?? = .none
        let model = OnboardingModel(brand: brand, names: names, store: store, looks: looks,
                                    page: .hello, draftName: "", onFinish: { sent = .some($0) })
        model.advance()
        #expect(model.page == .name)
        model.draftName = "   "
        model.commitName()
        #expect(model.page == .name)
        #expect(model.hint == FirstConversation.needsAName)
        model.draftName = " Pip "
        model.commitName()
        // Not saved until the first run finishes.
        #expect(names.loadDisplayName() == nil)
        #expect(model.page == .look)
        model.look = .tide
        model.advance()
        #expect(model.page == .ideas)
        #expect(!store.hasFinished())
        let job = try #require(model.starters.first)
        model.pick(job)
        #expect(sent == .some(job.prompt))
        #expect(store.hasFinished())
        #expect(names.loadDisplayName() == "Pip")
        #expect(AgentLook.load(from: looks) == .tide)
        #expect(model.displayName == "Pip")
    }

    @Test func skippingEverythingStillFinishesOnce() throws {
        let suite = "pebble.ui.skip.\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let store = InMemoryOnboardingStore()
        var finishes = 0
        let model = OnboardingModel(brand: brand, names: InMemoryAgentNameStore(), store: store, looks: looks,
                                    page: .name, draftName: "", onFinish: { line in
                                        #expect(line == nil)
                                        finishes += 1
                                    })
        model.skipName()
        model.advance()
        model.finishWithoutIdea()
        #expect(store.hasFinished())
        #expect(finishes == 1)
        #expect(model.displayName == brand.name)
    }

    @Test func theProactivityPageIsHiddenUntilThereIsAChoice() {
        let model = OnboardingModel(brand: brand, names: InMemoryAgentNameStore(), store: InMemoryOnboardingStore(),
                                    looks: UserDefaults(suiteName: "pebble.ui.hidden")!, page: .hello, draftName: "", onFinish: { _ in })
        #expect(!model.visiblePages.contains(.proactivity))
    }

    @Test func forgettingFromTheMemoryScreenErasesItFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store, place: .onDevice)
        model.newNote = "Door code 4417"
        model.add()
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.notes.count == 2)
        #expect(model.newNote.isEmpty)
        let secret = try #require(model.notes.first)
        model.forget(secret)
        #expect(model.notes.map(\.text) == ["Prefers tea"])
        #expect(model.status == MemoryWords.forgotten)
        let bytes = try Data(contentsOf: url)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("4417"))

        let tea = try #require(model.notes.first)
        model.beginEdit(tea)
        model.editDraft = "Prefers coffee"
        model.saveEdit()
        #expect(model.editingID == nil)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("tea"))

        let coffee = try #require(model.notes.first)
        model.beginEdit(coffee)
        model.forget(coffee)
        #expect(model.editingID == nil)
        #expect(model.editDraft.isEmpty)

        model.forgetEverything()
        #expect(model.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [MemorySource.toldMe, .fromApp("Calendar"), .inferred], [ColorScheme.light, .dark])
    func sourceLabelsRender(source: MemorySource, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: SourceLabel(source: source).environment(\.colorScheme, scheme))
        #expect(try #require(renderer.cgImage).width > 0)
    }

    @Test func theMemoryScreenShowsWhereEachNoteCameFrom() {
        let model = MemoryModel(store: ShowcaseScene.sampleMemory(), place: .onDevice)
        #expect(Set(model.notes.map(\.source)) == [.toldMe, .fromApp("Calendar"), .inferred])
    }

    @Test func aBlankNoteFromTheScreenIsRefusedKindly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        model.newNote = "   "
        model.add()
        #expect(model.notes.isEmpty)
        #expect(model.status == MemoryWords.needsWords)
    }

    @Test func extraApprovalsFromOneQuestionAreRefused() {
        let action = ProposedAction(kind: .purchase,
                                    recipient: Recipient(id: "merchant:1", displayName: "Rise Bakery", handle: "risebakery.example"),
                                    details: "Sourdough", price: Price(minorUnits: 1450, currency: "CAD"))
        let rule = AskFirst.isolated()
        var approvals: [Approval] = []
        let sheet = ConfirmationState(request: rule.ask(action)!, rule: rule,
                                      onApprove: { approvals.append($0) }, onDecline: {})
        sheet.tapPrimary()
        #expect(sheet.tapPrimary() == .ignored)
        #expect(approvals.count == 1)
        #expect(rule.decide(action, approval: approvals.first) == .proceed)
        for extra in approvals {
            #expect(rule.decide(action, approval: extra) == .stop)
        }
    }

    @Test func notNowClosesTheQuestionForGood() {
        let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")
        let rule = AskFirst.isolated()
        let request = rule.ask(action)!
        var declined = false
        let sheet = ConfirmationState(request: request, rule: rule, onApprove: { _ in }, onDecline: { declined = true })
        sheet.cancel()
        #expect(declined)
        #expect(rule.decide(action, approval: request.approve()) == .stop)
    }

    @Test func anUnreadableMemoryIsShownAndCanBeCleared() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        try Data("not notes {".utf8).write(to: url)
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        #expect(model.isUnreadable)
        #expect(model.hasStoredFile)
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.status == MemoryWords.unreadable)
        #expect(model.newNote == "Prefers tea")
        model.forgetEverything()
        #expect(!model.isUnreadable)
        #expect(!model.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
