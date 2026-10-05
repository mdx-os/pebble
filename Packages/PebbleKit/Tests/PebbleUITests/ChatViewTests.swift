#if canImport(SwiftUI)
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

struct ChatViewTests {
    let brand = Brand(name: "Nova")

    @MainActor
    @Test(arguments: [
        CGSize(width: 393, height: 852),   // iPhone
        CGSize(width: 1032, height: 1376), // iPad
        CGSize(width: 1280, height: 800),  // Mac window
    ])
    func rendersAtEachDeviceSize(size: CGSize) throws {
        let renderer = ImageRenderer(
            content: ChatView(brand: brand, names: InMemoryAgentNameStore())
                .frame(width: size.width, height: size.height)
        )
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size.width * renderer.scale))
    }

    @MainActor
    @Test func rendersAChosenName() throws {
        let size = CGSize(width: 393, height: 852)
        let renderer = ImageRenderer(
            content: ChatView(brand: brand, names: InMemoryAgentNameStore(stored: "Pip"))
                .frame(width: size.width, height: size.height)
        )
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size.width * renderer.scale))
    }
}

@MainActor
struct ChatRenameTests {
    let brand = Brand(name: "Nova")

    @Test func renamingSavesOnDeviceAndUpdatesTheGreeting() {
        let store = InMemoryAgentNameStore()
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: store)
        #expect(controller.displayName.text == brand.name)
        #expect(controller.showsNameInvitation)
        #expect(store.loadDisplayName() == nil)
        controller.beginRename()
        controller.setNameDraft("  Pip  ")
        controller.commitName()
        #expect(store.loadDisplayName() == "Pip")
        #expect(controller.displayName.text == "Pip")
        #expect(controller.brand.name == brand.name)
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: "Pip"))
        #expect(!controller.showsNameInvitation)
        #expect(controller.renameTitle == FirstConversation.changeNameTitle)
    }

    @Test func aBlankNameIsKeptOffTheDevice() {
        let store = InMemoryAgentNameStore()
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: store)
        controller.beginRename()
        controller.setNameDraft("   ")
        controller.commitName()
        #expect(store.loadDisplayName() == nil)
        #expect(controller.nameHint == FirstConversation.needsAName)
        #expect(controller.isChoosingName)
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: brand.name))
    }

    @Test func aNameChosenEarlierIsRestored() {
        let store = InMemoryAgentNameStore(stored: "Pip")
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: store)
        #expect(controller.displayName.text == "Pip")
        #expect(controller.brand.name == brand.name)
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: "Pip"))
        #expect(!controller.showsNameInvitation)
    }

    @Test func renamingAfterThePersonSpeaksKeepsTheTranscript() throws {
        let store = InMemoryAgentNameStore()
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: store)
        controller.conversation = try controller.conversation.appendingPerson("Hello there")
        let spoken = controller.conversation.turns.map(\.text)
        controller.beginRename()
        controller.setNameDraft("Pip")
        controller.commitName()
        #expect(store.loadDisplayName() == "Pip")
        #expect(controller.displayName.text == "Pip")
        #expect(controller.conversation.turns.map(\.text) == spoken)
    }
}
#endif
