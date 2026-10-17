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

/// The Today screen, rendered off screen at every size, and its question
/// cards answered through the confirmation sheet's own state.
@MainActor
struct FeedViewTests {
    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                              details: "Running ten minutes late")

    private func feed(_ sources: [any FeedSource] = [SampleFeedSource()], asks: NeedsYou = NeedsYou(rule: .isolated())) -> FeedModel {
        FeedModel(sources: sources, needsYou: asks, now: { ShowcaseScene.morning })
    }

    private func render(_ model: FeedModel, size: CGSize, scheme: ColorScheme = .light,
                        text: DynamicTypeSize = .large) throws -> CGImage {
        let view = NavigationStack {
            FeedView(model: model, look: .startingPoint, onTalk: { _ in }, onChat: {})
        }
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, text)
            .frame(width: size.width, height: size.height))
        return try #require(renderer.cgImage)
    }

    @Test(arguments: [
        CGSize(width: 393, height: 852),   // iPhone 17 Pro
        CGSize(width: 852, height: 393),   // iPhone sideways
        CGSize(width: 1032, height: 1376), // iPad Pro 13-inch, portrait
        CGSize(width: 1376, height: 1032), // iPad Pro 13-inch, landscape
        CGSize(width: 320, height: 1032),  // Slide Over and the narrowest Split View
        CGSize(width: 678, height: 1032),  // half of a 13-inch in Split View
        CGSize(width: 500, height: 600),   // a small Stage Manager window
    ], [ColorScheme.light, .dark])
    func theFeedRendersAtEachSize(size: CGSize, scheme: ColorScheme) throws {
        for model in [feed(asks: ShowcaseScene.sampleQuestion()), feed(), feed([EmptyFeedSource()])] {
            let image = try render(model, size: size, scheme: scheme)
            #expect(image.width == Int(size.width * 2) || image.width == Int(size.width))
        }
    }

    @Test(arguments: [DynamicTypeSize.xSmall, .large, .accessibility3, .accessibility5])
    func theFeedRendersAtEachTextSize(text: DynamicTypeSize) throws {
        _ = try render(feed(asks: ShowcaseScene.sampleQuestion()), size: CGSize(width: 393, height: 852), text: text)
        _ = try render(feed(asks: ShowcaseScene.sampleQuestion()), size: CGSize(width: 1032, height: 1376), text: text)
    }

    @Test func theReaderRenders() throws {
        let item = try #require(SampleFeedSource().items(now: Date()).first { if case .open = $0.action { true } else { false } })
        let renderer = ImageRenderer(content: FeedReader(item: item, time: "8:52 AM").frame(width: 393, height: 852))
        #expect(try #require(renderer.cgImage).width > 0)
    }

    @Test func eachCardReadsAsOneThoughtWithItsTime() throws {
        let item = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first)
        let card = FeedCard(item: item, time: "9:36 AM", perform: {})
        #expect(card.spoken.hasPrefix("Needs you. Pay "))
        #expect(card.spoken.contains("risebakery.ca?"))
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
    }

    @Test func theFeedColumnStaysComfortable() {
        #expect(Theme.feedWidth <= 900)
        #expect(Theme.feedWidth > Theme.chatWidth)
    }
}
#endif
