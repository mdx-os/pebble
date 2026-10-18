#if canImport(SwiftUI)
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// The wide layout at every iPad size and multitasking width, rendered off
/// screen. AppUITests drives the same layout in the Simulator.
@MainActor
struct HomeLayoutTests {
    let brand = Brand(name: "Nova")

    private func chat() -> ChatController {
        ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                            conversation: ShowcaseScene.sampleFirstChat())
    }

    @Test("Smoke: the sidebar layout draws at each size", arguments: [
        CGSize(width: 1032, height: 1376), // iPad Pro 13-inch, portrait
        CGSize(width: 1376, height: 1032), // iPad Pro 13-inch, landscape
        CGSize(width: 744, height: 1133),  // iPad mini, portrait
        CGSize(width: 1133, height: 744),  // iPad mini, landscape
        CGSize(width: 678, height: 1032),  // half of a 13-inch in Split View
        CGSize(width: 500, height: 600),   // a small Stage Manager window
    ], HomeSection.allCases)
    func smokeTheSidebarLayoutAtEachSize(size: CGSize, section: HomeSection) throws {
        let controller = chat()
        let feed = FeedModel(sources: [SampleFeedSource()], needsYou: ShowcaseScene.sampleQuestion(), place: .onDevice)
        let view = HomeSplit(
            chat: controller,
            section: .constant(section),
            needsYouCount: feed.feed.needsYou.count,
            todayScreen: FeedView(model: feed, look: .startingPoint, onTalk: { _ in })
                .safeAreaInset(edge: .bottom) {
                    TodayComposer(chat: controller, inFront: true, send: { _ in })
                },
            chatScreen: ChatView(controller: controller, look: .startingPoint, firstMessage: nil),
            memoryScreen: MemoryView(store: ShowcaseScene.sampleMemory(), place: .onDevice),
            newChat: {}
        )
        try smokeRender(view.frame(width: size.width, height: size.height))
    }

    @Test("Smoke: the shortcuts screen draws", arguments: [ColorScheme.light, .dark])
    func smokeTheShortcutsScreen(scheme: ColorScheme) throws {
        try smokeRender(KeyboardShortcutsView()
            .environment(\.colorScheme, scheme)
            .frame(width: 540, height: 620))
    }

    @Test("Smoke: the wide chat draws at each text size", arguments: [DynamicTypeSize.large, .accessibility3])
    func smokeTheChatWideAtEachTextSize(size: DynamicTypeSize) throws {
        try smokeRender(ChatView(controller: chat(), look: .startingPoint, firstMessage: nil)
            .environment(\.dynamicTypeSize, size)
            .frame(width: 1376, height: 1032))
    }

    /// The chat column stops at a reading width, so lines never run edge to
    /// edge on a 13-inch screen.
    @Test func theChatColumnHasAReadingWidth() {
        #expect(Theme.chatWidth <= 720)
        #expect(Theme.bubbleWidth < Theme.chatWidth)
    }

    /// The window can change shape at any moment. The conversation lives
    /// outside the chat screen, so a new screen shows the same words.
    @Test func aNewChatScreenKeepsTheConversation() throws {
        let controller = chat()
        controller.conversation = try controller.conversation.appendingPerson("Pack lunches")
        let before = controller.conversation.turns.map(\.text)
        _ = ChatView(controller: controller, look: nil, firstMessage: nil)
        _ = ChatView(controller: controller, look: nil, firstMessage: nil)
        #expect(controller.conversation.turns.map(\.text) == before)
    }

    @Test func aKeptConversationIsUsedOnlyWhenItsPrivacyPromiseHolds() {
        let offDevice = Conversation(turns: ShowcaseScene.sampleFirstChat().turns, onDevice: false)
        let controller = ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(),
                                             conversation: offDevice)
        #expect(controller.conversation.turns.count == 1)
    }
}
#endif
