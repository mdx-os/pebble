#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// A monotonic clock tests can move forward.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += .milliseconds(Int64(seconds * 1000)); lock.unlock() }
}

/// Counts what the injected sleep was asked for, and moves the clock.
private final class Naps {
    var count = 0
}

/// The composer on Today, the count beside Today, the sheet handoff, and
/// the example markers.
@MainActor
struct TodayFollowupsTests {
    let brand = Brand(name: "Nova")
    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                              details: "Running ten minutes late")

    private func chat(beat: Duration = .zero) -> ChatController {
        ChatController(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"), replyBeat: beat)
    }

    // MARK: Type and go from Today

    /// Today sends through the chat's own path: the line joins the same
    /// conversation, the shared draft clears, and while a reply is coming
    /// nothing more goes out, just as in the chat.
    @Test func sendingFromTodayUsesTheChatsOwnPath() async {
        let chat = chat()
        chat.draft = "Pack lunches"
        #expect(HomeView.sendsFromToday(chat.draft, chat: chat))
        #expect(chat.draft.isEmpty)
        #expect(chat.sentCount == 1)
        #expect(chat.conversation.turns.contains { $0.speaker == .person && $0.text == "Pack lunches" })
        #expect(chat.isReplying)
        #expect(!HomeView.sendsFromToday("And snacks", chat: chat))
        await chat.replyTask?.value
        #expect(chat.conversation.turns.last?.speaker == .agent)
        // Nothing to send is not a send, so the chat doesn't open on it.
        #expect(!HomeView.sendsFromToday("   ", chat: chat))
    }

    /// Words of care come first from Today too, with no beat held back.
    @Test func careComesFirstFromToday() async {
        let chat = chat(beat: .seconds(60))
        let started = ContinuousClock.now
        #expect(HomeView.sendsFromToday("I want to end my life", chat: chat))
        await chat.replyTask?.value
        #expect(chat.conversation.turns.last?.text == CareCheck.reply)
        #expect(ContinuousClock.now - started < .seconds(60))
    }

    /// A line sent from Today counts as speaking, so a new chat asks first.
    @Test func aLineFromTodayMeansANewChatAsksFirst() async {
        let chat = chat()
        #expect(!NewChatRule.asksFirst(personHasSpoken: chat.conversation.turns.contains { $0.speaker == .person },
                                       draft: chat.draft, pendingLine: nil))
        HomeView.sendsFromToday("Pack lunches", chat: chat)
        await chat.replyTask?.value
        #expect(NewChatRule.asksFirst(personHasSpoken: chat.conversation.turns.contains { $0.speaker == .person },
                                      draft: chat.draft, pendingLine: nil))
    }

    /// The empty Today says only what is true now and has no button of its
    /// own: the composer is the way in.
    @Test func theEmptyTodayPromisesOnlyWhatExists() {
        for promise in ["finish", "background", "while you", "show up here", "I'll only ask"] {
            #expect(!FeedWords.empty.localizedCaseInsensitiveContains(promise), "\(promise)")
        }
        #expect(FeedWords.empty.contains("below"))
    }

    /// Today with its composer, at every text size, on a phone and a big iPad.
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .accessibility3, .accessibility5], [ColorScheme.light, .dark])
    func todayWithItsComposerRenders(text: DynamicTypeSize, scheme: ColorScheme) throws {
        let chat = chat()
        for size in [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)] {
            for sources in [[EmptyFeedSource()], [SampleFeedSource()]] as [[any FeedSource]] {
                let model = FeedModel(sources: sources, needsYou: NeedsYou(rule: .isolated()), place: .onDevice,
                                      now: { ShowcaseScene.morning })
                let view = NavigationStack {
                    FeedView(model: model, look: .startingPoint, onTalk: { _ in })
                        .safeAreaInset(edge: .bottom) { TodayComposer(chat: chat, keyboardSends: true, send: { _ in }) }
                }
                let renderer = ImageRenderer(content: view
                    .environment(\.dynamicTypeSize, text)
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height))
                #expect(try #require(renderer.cgImage).width == Int(size.width * renderer.scale))
            }
        }
    }

    // MARK: The count beside Today

    /// With no Today on screen at all, the loop the home screen runs still
    /// drops a timed out question, so the sidebar's count goes down.
    @Test func theNeedsYouCountDropsAfterTheWindowWithTodayOffScreen() async throws {
        let clock = Clock()
        let asks = NeedsYou(rule: .isolated(now: clock.now))
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        _ = try #require(asks.ask(note))
        #expect(model.feed.needsYou.count == 1)
        let naps = Naps()
        await model.keepFresh { wait in
            naps.count += 1
            #expect(wait == FeedModel.refreshInterval)
            // The first nap passes the window; the second ends the loop.
            guard naps.count == 1 else { throw CancellationError() }
            clock.advance(AskFirst.defaultWindow + 1)
        }
        #expect(naps.count == 2)
        #expect(model.feed.needsYou.isEmpty)
    }

    /// Before the window ends the count stays.
    @Test func theCountStaysInsideTheWindow() async throws {
        let clock = Clock()
        let asks = NeedsYou(rule: .isolated(now: clock.now))
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        _ = try #require(asks.ask(note))
        let naps = Naps()
        await model.keepFresh { _ in
            naps.count += 1
            guard naps.count == 1 else { throw CancellationError() }
            clock.advance(AskFirst.defaultWindow - 1)
        }
        #expect(model.feed.needsYou.count == 1)
    }

    /// Asking, a yes and a dismissal each show at once, with no refresh.
    @Test func eachChangeToTheQuestionsShowsAtOnce() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        var calls = 0
        let counted = NeedsYou(rule: .isolated())
        counted.onChange = { MainActor.assumeIsolated { calls += 1 } }

        let first = try #require(asks.ask(note))
        #expect(model.feed.needsYou.count == 1)
        let yes = ConfirmationState(request: first, rule: rule, onApprove: { asks.approved($0) }, onDecline: {})
        #expect(yes.tapPrimary() == .approved)
        #expect(model.feed.needsYou.isEmpty)

        let second = try #require(asks.ask(note))
        #expect(model.feed.needsYou.count == 1)
        asks.dismissed(second)
        #expect(model.feed.needsYou.isEmpty)

        // The hook fires once for each, and not for a dismissal of nothing.
        let asked = try #require(counted.ask(note))
        counted.dismissed(asked)
        counted.dismissed(asked)
        #expect(calls == 2)
    }

    // MARK: Closing a sheet, then moving on

    @Test func theHandoffWaitsForTheSheetToGo() {
        var handoff = SheetHandoff()
        var ran = 0
        handoff.hold { ran += 1 }
        // Another sheet is still on its way out: keep waiting.
        #expect(handoff.sheetClosed(stillOpen: true, questionOpen: false) == nil)
        handoff.sheetClosed(stillOpen: false, questionOpen: false)?()
        #expect(ran == 1)
        // Only once.
        #expect(handoff.sheetClosed(stillOpen: false, questionOpen: false) == nil)
    }

    /// A question that opened while the sheet was closing waits for its
    /// answer; nothing waiting is allowed to sweep it away.
    @Test func aQuestionThatOpensMeanwhileWins() {
        var handoff = SheetHandoff()
        var ran = false
        handoff.hold { ran = true }
        #expect(handoff.sheetClosed(stillOpen: false, questionOpen: true) == nil)
        #expect(!ran)
        #expect(handoff.waiting == nil)
    }

    /// No guessed delay is left in the home screen.
    @Test func theHomeScreenWaitsOnNoTimer() throws {
        let source = try ContrastGuardTests.sources().first { $0.name == "HomeView.swift" }?.text ?? ""
        #expect(!source.isEmpty)
        #expect(!source.contains("asyncAfter"))
    }

    // MARK: Examples say so

    @Test func exampleCardsSayExampleFirst() throws {
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: ShowcaseScene.sampleQuestion(), place: .onDevice,
                              now: { ShowcaseScene.morning })
        let cards = model.feed.needsYou + model.feed.groups.flatMap(\.items)
        #expect(cards.count > 2)
        for item in cards {
            #expect(model.isSample(item))
            let card = FeedCard(item: item, time: "9:36 AM", isSample: model.isSample(item), perform: {})
            #expect(card.spoken.hasPrefix("\(FeedWords.exampleMarker). \(item.spokenKind). "))
        }
        // Real cards and real questions don't.
        let asks = NeedsYou(rule: .isolated())
        _ = asks.ask(note)
        let real = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice)
        let question = try #require(real.feed.needsYou.first)
        #expect(!real.isSample(question))
        #expect(!FeedCard(item: question, time: "9:36 AM", isSample: false, perform: {}).spoken.contains(FeedWords.exampleMarker))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theSamplePaymentSheetShowsTheExampleLabel(scheme: ColorScheme) throws {
        let asks = ShowcaseScene.sampleQuestion()
        #expect(asks.isSample)
        let request = try #require(asks.items(now: Date()).first?.request)
        let renderer = ImageRenderer(content: ConfirmationSheet(request: request, rule: asks.rule, isExample: true,
                                                                onApprove: { _ in }, onDecline: {})
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 852))
        #expect(try #require(renderer.cgImage).width > 0)
    }

    @Test func theShowcaseBakeryUsesAnExampleDomain() throws {
        let item = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first)
        #expect(item.title.contains("risebakery.example"))
    }

    // MARK: Cards never run off the screen, measured

    /// The size a view takes when offered `width`, as rendered.
    private func measured(_ view: some View, width: CGFloat, text: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, text))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        return CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
    }

    /// Every card, rendered at the width its column gives it, from Slide
    /// Over to a 13-inch iPad and the smallest text size to the largest,
    /// takes no more than that width. This measures what SwiftUI lays out,
    /// so a card that refuses to wrap fails here.
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .accessibility1, .accessibility5])
    func everyCardFitsItsColumnAsRendered(text: DynamicTypeSize) throws {
        let long = FeedItem(id: "long", kind: .ready, time: ShowcaseScene.morning,
                            title: "accounts.risebakery.example.billing-secure-example.net sent a receipt",
                            body: String(repeating: "A rather long line of words to wrap. ", count: 6), action: .open("x"))
        let items = SampleFeedSource().items(now: ShowcaseScene.morning)
            + (ShowcaseScene.sampleQuestion().items(now: Date())) + [long]
        for window in [320, 393, 678, 1032, 1376] as [CGFloat] {
            let content = FeedView.contentWidth(in: window, column: Theme.feedWidth)
            let count = FeedView.columnCount(for: content, minimum: 320, accessibilityText: text.isAccessibilitySize)
            let column = (content - CGFloat(count - 1) * FeedView.cardSpacing) / CGFloat(count)
            for item in items {
                let size = try measured(FeedCard(item: item, time: "9:36 AM", isSample: true, perform: {}),
                                        width: column, text: text)
                #expect(size.width <= column + 0.5, "\(item.id) is \(size.width) wide in \(column) at \(text)")
            }
            // The grid as Today builds it fits the room it has, too.
            let grid = LazyVGrid(columns: FeedView.columns(for: content, minimum: 320,
                                                          accessibilityText: text.isAccessibilitySize),
                                 alignment: .leading, spacing: FeedView.cardSpacing) {
                ForEach(items) { FeedCard(item: $0, time: "9:36 AM", perform: {}) }
            }
            let size = try measured(grid, width: content, text: text)
            #expect(size.width <= content + 0.5, "the grid is \(size.width) wide in \(content) at \(text)")
        }
    }
}
#endif
