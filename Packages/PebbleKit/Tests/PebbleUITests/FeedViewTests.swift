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

/// A source with fixed items.
private struct Fixed: FeedSource {
    let items: [FeedItem]
    func items(now: Date) -> [FeedItem] { items }
}

/// The Today screen, rendered off screen at every size, and its question
/// cards answered through the confirmation sheet's own state.
@MainActor
struct FeedViewTests {
    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                              details: "Running ten minutes late")

    private func feed(_ sources: [any FeedSource] = [SampleFeedSource()], asks: NeedsYou = NeedsYou(rule: .isolated())) -> FeedModel {
        FeedModel(sources: sources, needsYou: asks, place: .onDevice, now: { ShowcaseScene.morning })
    }

    private func render(_ model: FeedModel, size: CGSize, scheme: ColorScheme = .light,
                        text: DynamicTypeSize = .large) throws -> CGImage {
        let view = NavigationStack {
            FeedView(model: model, look: .startingPoint, onTalk: { _ in })
        }
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, text)
            .frame(width: size.width, height: size.height))
        return try #require(renderer.cgImage)
    }

    @Test("Smoke: the feed draws at each size", arguments: [
        CGSize(width: 393, height: 852),   // iPhone 17 Pro
        CGSize(width: 852, height: 393),   // iPhone sideways
        CGSize(width: 1032, height: 1376), // iPad Pro 13-inch, portrait
        CGSize(width: 1376, height: 1032), // iPad Pro 13-inch, landscape
        CGSize(width: 320, height: 1032),  // Slide Over and the narrowest Split View
        CGSize(width: 678, height: 1032),  // half of a 13-inch in Split View
        CGSize(width: 500, height: 600),   // a small Stage Manager window
    ], [ColorScheme.light, .dark])
    func smokeTheFeedAtEachSize(size: CGSize, scheme: ColorScheme) throws {
        for model in [feed(asks: ShowcaseScene.sampleQuestion()), feed(), feed([EmptyFeedSource()])] {
            _ = try render(model, size: size, scheme: scheme)
        }
    }

    @Test("Smoke: the feed draws at each text size",
          arguments: [DynamicTypeSize.xSmall, .large, .accessibility3, .accessibility5])
    func smokeTheFeedAtEachTextSize(text: DynamicTypeSize) throws {
        _ = try render(feed(asks: ShowcaseScene.sampleQuestion()), size: CGSize(width: 393, height: 852), text: text)
        _ = try render(feed(asks: ShowcaseScene.sampleQuestion()), size: CGSize(width: 1032, height: 1376), text: text)
    }

    @Test("Smoke: the reader draws", arguments: [false, true])
    func smokeTheReader(isSample: Bool) throws {
        let item = try #require(SampleFeedSource().items(now: Date()).first { if case .open = $0.action { true } else { false } })
        try smokeRender(FeedReader(item: item, time: "8:52 AM", isSample: isSample).frame(width: 393, height: 852))
    }

    /// The reader says an example is an example, and only then.
    @Test func onlyExampleCardsOpenAsExamples() throws {
        let sample = feed()
        let item = try #require(sample.feed.groups.flatMap(\.items).first)
        #expect(sample.isSample(item))
        let real = FeedItem(id: "real", kind: .did, time: ShowcaseScene.morning, title: "Done", body: "", action: .open("x"))
        let mixed = FeedModel(sources: [SampleFeedSource(), Fixed(items: [real])], needsYou: NeedsYou(rule: .isolated()),
                              place: .onDevice, now: { ShowcaseScene.morning })
        #expect(!mixed.isSample(real))
        #expect(mixed.isSample(item))
    }

    // MARK: Cards never run off the screen

    /// Every width the feed can get, from Slide Over to a full 13-inch iPad,
    /// with the card minimum scaled from the smallest text size to past the
    /// largest (320 pt grows to about 1000 at AX5). Each card fits, and
    /// accessibility sizes get one plain column. This checks the column
    /// math only; `everyCardFitsItsColumnAsRendered` measures the cards.
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility1, .accessibility5],
          [280, 320, 420, 560, 760, 1000] as [CGFloat])
    func cardsAlwaysFitTheScreen(text: DynamicTypeSize, minimum: CGFloat) {
        for window in [320, 375, 393, 500, 678, 744, 852, 1032, 1376] as [CGFloat] {
            let width = FeedView.contentWidth(in: window, column: Theme.feedWidth)
            let count = FeedView.columnCount(for: width, minimum: minimum, accessibilityText: text.isAccessibilitySize)
            #expect(count >= 1 && count <= 2)
            if text.isAccessibilitySize { #expect(count == 1) }
            // Columns share the width there is. An adaptive or fixed column
            // at `minimum` would run past the screen once `minimum` > width.
            let columns = FeedView.columns(for: width, minimum: minimum, accessibilityText: text.isAccessibilitySize)
            #expect(columns.count == count)
            #expect(columns.allSatisfy { if case .flexible = $0.size { true } else { false } },
                    "cards could overflow at \(window) pt and \(text)")
            // Two columns only when each card keeps its comfortable width.
            let card = (width - CGFloat(count - 1) * FeedView.cardSpacing) / CGFloat(count)
            if count == 2 { #expect(card >= minimum) }
        }
        #expect(FeedView.columns(for: 272, minimum: 999, accessibilityText: false).count == 1)
    }

    // MARK: Contrast

    /// Words on the accent fill ("Have a look" and the small chat pill) are
    /// readable at small sizes, without changing the brand color.
    @Test func wordsOnTheAccentAreReadable() {
        #expect(Theme.onAccentRGB.contrast(with: Theme.accentRGB) >= 4.5)
        // Why white isn't used there.
        #expect(Theme.RGB.white.contrast(with: Theme.accentRGB) < 4.5)
        #expect(abs(Theme.RGB.white.contrast(with: Theme.RGB(red: 0, green: 0, blue: 0)) - 21) < 0.01)
    }

    @Test func eachCardReadsAsOneThoughtWithItsTime() throws {
        let item = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first)
        let card = FeedCard(item: item, time: "9:36 AM", perform: {})
        #expect(card.spoken.hasPrefix("Needs you. Pay "))
        #expect(card.spoken.contains("risebakery.example?"))
        #expect(card.spoken.hasSuffix("pickup tomorrow at 9. 9:36 AM"))
    }

    @Test func theNeedsYouSectionComesAndGoesWithTheQuestion() throws {
        let asks = NeedsYou(rule: .isolated())
        let model = feed(asks: asks)
        #expect(!model.feed.showsNeedsYou)
        let request = try #require(asks.ask(note))
        model.refresh()
        #expect(model.feed.needsYou.map(\.request) == [request])
        model.closedQuestion(request)
        #expect(!model.feed.showsNeedsYou)
    }

    @Test func eachCardDoesItsOneThing() throws {
        let asks = NeedsYou(rule: .isolated())
        _ = try #require(asks.ask(note))
        let model = feed(asks: asks)
        var talked: [String] = []
        let question = try #require(model.feed.needsYou.first)
        model.perform(question, talk: { talked.append($0) })
        #expect(model.reviewing == question.request)
        let items = model.feed.groups.flatMap(\.items)
        let result = try #require(items.first { if case .open = $0.action { true } else { false } })
        model.perform(result, talk: { talked.append($0) })
        #expect(model.reading == result)
        let spotted = try #require(items.first { if case .talk = $0.action { true } else { false } })
        model.perform(spotted, talk: { talked.append($0) })
        #expect(talked == ["Help me plan something for Sam's birthday."])
    }

    /// The card opens the confirmation sheet. A yes there counts once, for
    /// exactly what was shown, and the card leaves.
    @Test func aYesFromTheFeedGoesThroughTheSheet() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(note))
        let model = feed(asks: asks)
        model.perform(try #require(model.feed.needsYou.first), talk: { _ in })
        let request = try #require(model.reviewing)
        var approval: Approval?
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { approval = $0; model.approved($0) },
                                      onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .approved)
        #expect(model.reviewing == nil)
        #expect(!model.feed.showsNeedsYou)
        let yes = try #require(approval)
        #expect(rule.decide(note, approval: yes) == .proceed)
        #expect(rule.decide(note, approval: yes) == .stop)
    }

    /// After a yes the sheet goes away. Its disappear path, and the feed's,
    /// must not withdraw the yes before the asker acts on it.
    @Test func aYesSurvivesTheSheetGoingAway() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(note))
        let model = feed(asks: asks)
        model.perform(try #require(model.feed.needsYou.first), talk: { _ in })
        let request = try #require(model.reviewing)
        var approval: Approval?
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { approval = $0; model.approved($0) },
                                      onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .approved)
        // What ConfirmationSheet and HomeView run on disappear.
        sheet.disappeared()
        model.closedQuestion(request)
        model.refresh()
        #expect(rule.decide(note, approval: try #require(approval)) == .proceed)
    }

    /// A card that carries a question but was not pinned by NeedsYou opens
    /// nothing.
    @Test func onlyAPinnedQuestionOpensTheSheet() throws {
        let request = try #require(AskFirst.isolated().ask(note))
        let posing = FeedItem(id: "posing", kind: .needsYou, time: ShowcaseScene.morning, title: "Pay?", body: "",
                              action: .review(request))
        let model = feed([Fixed(items: [posing])])
        #expect(!model.feed.showsNeedsYou)
        model.perform(posing, talk: { _ in })
        #expect(model.reviewing == nil)
    }

    @Test func theShowcaseQuestionUsesItsOwnRule() {
        #expect(ShowcaseScene.sampleQuestion().rule !== AskFirst.shared)
    }

    /// A card left on screen past the window opens a sheet that can only
    /// say it timed out.
    @Test func aTimedOutCardCantBeApproved() throws {
        let clock = Clock()
        let rule = AskFirst.isolated(now: clock.now)
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(note))
        let model = feed(asks: asks)
        let card = try #require(model.feed.needsYou.first)
        clock.advance(AskFirst.defaultWindow + 1)
        model.perform(card, talk: { _ in })
        let request = try #require(model.reviewing)
        var approved = false
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { _ in approved = true }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .timedOut)
        #expect(!approved)
        #expect(sheet.footnote == ConfirmationWords.expired)
        model.refresh()
        #expect(!model.feed.showsNeedsYou)
    }

    @Test func notNowFromTheFeedWithdrawsTheQuestion() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(note))
        let model = feed(asks: asks)
        model.perform(try #require(model.feed.needsYou.first), talk: { _ in })
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.cancel() == .closed)
        #expect(!model.feed.showsNeedsYou)
        #expect(rule.isClosed(request))
    }

    @Test func cardTimesReadNaturally() {
        let model = feed()
        let now = ShowcaseScene.morning
        let calendar = Calendar.current
        #expect(model.timeLabel(for: now - 3600) == (now - 3600).formatted(date: .omitted, time: .shortened))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(model.timeLabel(for: yesterday) == FeedWords.yesterday)
        // Any day but today says which day, ahead of the clock too.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(model.timeLabel(for: tomorrow) == tomorrow.formatted(.dateTime.month(.abbreviated).day()))
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        #expect(model.timeLabel(for: threeDaysAgo) == threeDaysAgo.formatted(.dateTime.weekday(.wide)))
    }

    @Test func eachCardSaysWhatItDoesOnce() throws {
        let item = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first)
        #expect(item.action?.hint == FeedWords.reviewHint)
    }

    @Test func theFeedColumnStaysComfortable() {
        #expect(Theme.feedWidth <= 900)
        #expect(Theme.feedWidth > Theme.chatWidth)
    }
}
#endif
