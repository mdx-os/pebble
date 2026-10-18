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

/// Answers only after a long pause, so a test can act while a reply is coming.
private struct SlowModel: ModelClient {
    var runsOnDevice: Bool { true }
    func reply(to transcript: [ChatTurn]) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "late"
    }
}

@MainActor
struct ChatSendingTests {
    let brand = Brand(name: "Nova")

    @Test func aSecondSendWhileReplyingIsIgnoredAndKeepsTheDraft() {
        let controller = ChatController(brand: brand, model: SlowModel(), names: InMemoryAgentNameStore(stored: "Pip"))
        controller.submit("Pack lunches")
        #expect(controller.isReplying)
        let turns = controller.conversation.turns.count
        controller.draft = "and then walk"
        controller.submit(controller.draft)
        #expect(controller.conversation.turns.count == turns)
        #expect(controller.draft == "and then walk")
        controller.stopReplying()
    }

    @Test func stoppingAReplyAddsNothing() async {
        let controller = ChatController(brand: brand, model: SlowModel(), names: InMemoryAgentNameStore(stored: "Pip"))
        controller.submit("Pack lunches")
        let turns = controller.conversation.turns.count
        controller.stopReplying()
        for _ in 0..<100 where controller.isReplying { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isReplying)
        #expect(controller.conversation.turns.count == turns)
        #expect(controller.failure == nil)
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
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: "Pip", onDevice: true))
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
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: brand.name, onDevice: true))
    }

    @Test func aNameChosenEarlierIsRestored() {
        let store = InMemoryAgentNameStore(stored: "Pip")
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: store)
        #expect(controller.displayName.text == "Pip")
        #expect(controller.brand.name == brand.name)
        #expect(controller.conversation.turns.first?.text == FirstConversation.opening(named: "Pip", onDevice: true))
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

    @Test func onlyNewAgentLinesAreReadAloud() throws {
        let start = Conversation.firstRun(named: "Pip", onDevice: true)
        #expect(ChatView.announcement(for: start, covered: false) == nil)
        let asked = try start.appendingPerson("gym")
        #expect(ChatView.announcement(for: asked, covered: false) == nil)
        let answered = Conversation(
            turns: asked.turns + [ChatTurn(id: UUID(), speaker: .agent, text: "Here's a plan")],
            onDevice: true
        )
        #expect(ChatView.announcement(for: answered, covered: false) == "Here's a plan")
    }

    @Test func theAppModelOpensWithAnHonestPrivacyLine() {
        let controller = ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore())
        #expect(controller.conversation.turns.first?.text.contains("stays here") == true)
    }
}
#endif
