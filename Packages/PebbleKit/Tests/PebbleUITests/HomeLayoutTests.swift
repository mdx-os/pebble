#if canImport(SwiftUI)
import PebbleCore
import PebbleModel
import SourceScan
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

    /// The row drawn chosen and the row VoiceOver hears chosen are the same
    /// one. With no selection yet, Today is drawn chosen only beside its own
    /// screen. A collapsed list with no selection, as after going back on
    /// iPhone, has no row chosen.
    @Test(arguments: [nil] + HomeSection.allCases.map(Optional.some), [true, false])
    func theChosenRowIsHeardChosen(section: HomeSection?, regular: Bool) {
        typealias Split = HomeSplit<EmptyView, EmptyView, EmptyView>
        let chosen = HomeSection.allCases.filter { Split.isChosen($0, section: section, regular: regular) }
        if let section {
            #expect(chosen == [section], "the selection is the one row drawn chosen")
        } else if regular {
            #expect(chosen == [.today], "Today shows beside the list, so it is drawn chosen")
        } else {
            #expect(chosen.isEmpty, "a collapsed list with nothing chosen draws no row chosen")
        }
        for place in HomeSection.allCases {
            // Where this code draws the fill, the row it draws is heard chosen.
            #expect(Split.traits(place, section: section, regular: regular, ownFill: true).contains(.isSelected)
                        == Split.isChosen(place, section: section, regular: regular),
                    "\(place) with \(String(describing: section)), regular \(regular)")
            // Where the system draws the selection, as on the Mac, it gives
            // the trait itself, so nothing is added: with no selection the
            // Mac draws none, and Today must not be heard selected.
            #expect(Split.traits(place, section: section, regular: regular, ownFill: false).isEmpty,
                    "\(place) with \(String(describing: section)), regular \(regular), system selection")
        }
        // A count is heard as what it counts, never as a bare number: the
        // one the chosen row draws itself and the system badge on the rest.
        for count in [1, 3] {
            let spoken = Split.spokenCount(count)
            #expect(spoken == HomeWords.waiting(count))
            #expect(spoken.contains("\(count)") && spoken.contains("waiting"), "\(spoken)")
        }
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = (try? String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/HomeView.swift"),
                                encoding: .utf8)) ?? ""
        let code = String(SwiftSource(text).code)
        #expect(code.contains("Self.traits(place, section: section, regular: isRegular, ownFill: Self.drawsOwnFill)"),
                "the sidebar adds the trait only where it draws its own fill")
        #expect(code.range(of: #"Text\(count, format: \.number\)\s*\.monospacedDigit\(\)\s*\.accessibilityLabel\(Self\.spokenCount\(count\)\)"#,
                           options: .regularExpression) != nil, "the drawn count carries the spoken label")
        #expect(code.range(of: #"\.badge\([^\n]*\n?[^\n]*Text\(count, format: \.number\)\.accessibilityLabel\(Self\.spokenCount\(count\)\)\)"#,
                           options: .regularExpression) != nil, "the system badge carries the spoken label too")
        #if os(iOS)
        #expect(Split.drawsOwnFill)
        #else
        #expect(!Split.drawsOwnFill, "the Mac keeps the system's selection")
        #endif
    }

    /// Done draws its own style, so it brings back what the system's would
    /// give: a ring while the keyboard is on it, and the iPad pointer's
    /// highlight. The focus is read in `FocusRing`, a view inside the button,
    /// not on the style, where it stays false.
    @Test func doneShowsKeyboardFocusAndPointerHover() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/Theme.swift"),
                              encoding: .utf8)
        let code = String(SwiftSource(text).code)
        let start = try #require(code.range(of: "struct FillButtonStyle"))
        let style = String(code[start.lowerBound...].prefix(1400))
        #expect(style.contains(".pointerHover(in: Capsule())"))
        #expect(style.range(of: #"struct FillButtonStyle[^{]*\{[^}]*isFocused"#, options: .regularExpression) == nil,
                "the style never reads the focus itself")
        let ring = try #require(code.range(of: "struct FocusRing"))
        let ringBody = String(code[ring.lowerBound...].prefix(600))
        #expect(ringBody.contains(#"@Environment(\.isFocused)"#))
        #expect(ringBody.range(of: #"if\s+isFocused\s*\{\s*Capsule\(\)\.strokeBorder"#, options: .regularExpression) != nil)
        #expect(style.contains("FocusRing {"), "the style's capsule sits inside FocusRing")
        try smokeRender(DoneButton {}.padding().frame(width: 200, height: 100))
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
        let offDevice = Conversation(turns: ShowcaseScene.sampleFirstChat().turns, place: .mayLeaveDevice)
        let controller = ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(),
                                             conversation: offDevice)
        #expect(controller.conversation.turns.count == 1)
    }
}
#endif
