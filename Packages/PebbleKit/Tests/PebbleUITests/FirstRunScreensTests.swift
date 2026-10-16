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
        #expect(names.loadDisplayName() == "Pip")
        #expect(model.page == .look)
        model.look = .tide
        model.advance()
        #expect(model.page == .ideas)
        #expect(!store.hasFinished())
        let job = try #require(model.starters.first)
        model.pick(job)
        #expect(sent == .some(job.prompt))
        #expect(store.hasFinished())
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
                                    looks: .standard, page: .hello, draftName: "", onFinish: { _ in })
        #expect(!model.visiblePages.contains(.proactivity))
    }

    @Test func forgettingFromTheMemoryScreenErasesItFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store)
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

        model.forgetEverything()
        #expect(model.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aBlankNoteFromTheScreenIsRefusedKindly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let model = MemoryModel(store: MemoryStore(fileURL: url))
        model.newNote = "   "
        model.add()
        #expect(model.notes.isEmpty)
        #expect(model.status == MemoryWords.needsWords)
    }

    @Test func yesOnTheSheetApprovesExactlyOnce() {
        let action = ProposedAction(kind: .purchase,
                                    recipient: Recipient(id: "merchant:1", displayName: "Rise Bakery"),
                                    details: "Sourdough", price: Price(minorUnits: 1450, currency: "CAD"))
        var approval: Approval?
        var declined = false
        let sheet = ConfirmationSheet(request: ConfirmationRequest(action: action),
                                      onApprove: { approval = $0 }, onDecline: { declined = true })
        sheet.onApprove(sheet.request.approve())
        let rule = AskFirst()
        #expect(rule.decide(action, approval: approval) == .proceed)
        #expect(rule.decide(action, approval: approval) == .stop)
        sheet.onDecline()
        #expect(declined)
    }

    @Test func pricesShowWithTheirCurrency() {
        let text = ConfirmationSheet.format(Price(minorUnits: 1450, currency: "CAD"))
        #expect(text.contains("14.50") || text.contains("14,50"))
    }
}
#endif
