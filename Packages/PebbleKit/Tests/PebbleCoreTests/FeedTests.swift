import Foundation
@testable import PebbleCore
import Testing

struct FeedTests {
    /// A fixed calendar so the tests read the same in every time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }()

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func item(_ id: String, _ kind: FeedItem.Kind = .did, at time: Date) -> FeedItem {
        FeedItem(id: id, kind: kind, time: time, title: id, body: "")
    }

    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                              details: "Running ten minutes late")

    // MARK: Grouping and order

    @Test func cardsAreGroupedByTimeOfDayNewestFirst() {
        let now = Self.at(17, 19)
        let feed = Feed.build([
            Self.item("breakfast", at: Self.at(17, 8)),
            Self.item("lunch", at: Self.at(17, 12, 30)),
            Self.item("yesterday", at: Self.at(16, 22)),
            Self.item("dinner", at: Self.at(17, 18)),
            Self.item("coffee", at: Self.at(17, 10)),
            Self.item("last week", at: Self.at(10, 9)),
        ], now: now, calendar: Self.calendar)
        #expect(feed.groups.map(\.period) == [.thisEvening, .thisAfternoon, .thisMorning, .earlier])
        #expect(feed.groups.map { $0.items.map(\.id) } == [["dinner"], ["lunch"], ["coffee", "breakfast"], ["yesterday", "last week"]])
        #expect(feed.count == 6)
    }

    @Test func emptyPeriodsAreLeftOut() {
        let feed = Feed.build([Self.item("a", at: Self.at(17, 9)), Self.item("b", at: Self.at(15, 9))],
                              now: Self.at(17, 10), calendar: Self.calendar)
        #expect(feed.groups.map(\.title) == ["This morning", "Earlier"])
    }

    @Test func theDayTurnsAtNoonAndFive() {
        let now = Self.at(17, 23)
        let c = Self.calendar
        #expect(FeedPeriod.of(Self.at(17, 0), now: now, calendar: c) == .thisMorning)
        #expect(FeedPeriod.of(Self.at(17, 11, 59), now: now, calendar: c) == .thisMorning)
        #expect(FeedPeriod.of(Self.at(17, 12), now: now, calendar: c) == .thisAfternoon)
        #expect(FeedPeriod.of(Self.at(17, 17), now: now, calendar: c) == .thisEvening)
        #expect(FeedPeriod.of(Self.at(16, 23, 59), now: now, calendar: c) == .earlier)
    }

    @Test func aTimeAheadOfTheClockCountsAsNow() {
        let now = Self.at(17, 9)
        #expect(FeedPeriod.of(Self.at(17, 20), now: now, calendar: Self.calendar) == .thisMorning)
        #expect(FeedPeriod.of(Self.at(18, 9), now: now, calendar: Self.calendar) == .thisMorning)
    }

    @Test func cardsAtTheSameMomentKeepAFixedOrder() {
        let time = Self.at(17, 9)
        let one = Feed.build([Self.item("b", at: time), Self.item("a", at: time)], now: time, calendar: Self.calendar)
        let two = Feed.build([Self.item("a", at: time), Self.item("b", at: time)], now: time, calendar: Self.calendar)
        #expect(one == two)
    }

    // MARK: Needs you

    @Test func needsYouIsPinnedOnlyWhenSomethingIsWaiting() throws {
        let now = Self.at(17, 10)
        let quiet = Feed.build([Self.item("a", at: now)], now: now, calendar: Self.calendar)
        #expect(!quiet.showsNeedsYou)
        #expect(quiet.needsYou.isEmpty)

        let asks = NeedsYou(rule: .isolated())
        _ = try #require(asks.ask(note, at: now - 60))
        let feed = Feed.build(from: [asks, SampleFeedSource()], now: now, calendar: Self.calendar)
        #expect(feed.showsNeedsYou)
        #expect(feed.needsYou.map(\.kind) == [.needsYou])
        #expect(feed.needsYou.first?.title == "Send this to 416 555 0101?")
        #expect(feed.needsYou.first?.body == note.details)
        // The question is never also one of the timed cards.
        #expect(!feed.groups.flatMap(\.items).contains { $0.kind == .needsYou })
    }

    @Test func theQuestionThatWillTimeOutFirstIsOnTop() throws {
        let asks = NeedsYou(rule: .isolated())
        let now = Self.at(17, 10)
        let late = ProposedAction(kind: .send, recipient: note.recipient, details: "On my way")
        _ = try #require(asks.ask(late, at: now - 30))
        _ = try #require(asks.ask(note, at: now - 120))
        let feed = Feed.build(from: [asks], now: now, calendar: Self.calendar)
        #expect(feed.needsYou.map(\.body) == [note.details, late.details])
    }

    @Test func aCardCantPoseAsAQuestion() throws {
        let now = Self.at(17, 10)
        let request = try #require(AskFirst.isolated().ask(note))
        let feed = Feed.build([
            // Says it needs you, but asks nothing: dropped.
            FeedItem(id: "fake", kind: .needsYou, time: now, title: "Pay me?", body: ""),
            // Carries a question but isn't a question card: dropped.
            FeedItem(id: "hidden", kind: .did, time: now, title: "Done", body: "", action: .review(request)),
            Self.item("real", at: now),
        ], now: now, calendar: Self.calendar)
        #expect(feed.needsYou.isEmpty)
        #expect(feed.groups.flatMap(\.items).map(\.id) == ["real"])
    }

    @Test func aBrandNewPersonSeesAnEmptyFeed() {
        let feed = Feed.build(from: [EmptyFeedSource(), NeedsYou(rule: .isolated())], now: Self.at(17, 9))
        #expect(feed.isEmpty)
        #expect(!feed.showsNeedsYou)
    }

    // MARK: Acting from the feed follows the ask first rules

    @Test func aQuestionAskFirstRefusesNeverReachesTheFeed() {
        let asks = NeedsYou(rule: .isolated())
        let noHandle = ProposedAction(kind: .send, recipient: Recipient(id: "c:2", displayName: "Sam"), details: "hi")
        let noPrice = ProposedAction(kind: .purchase, recipient: note.recipient, details: "Sourdough")
        #expect(asks.ask(noHandle) == nil)
        #expect(asks.ask(noPrice) == nil)
        #expect(asks.items(now: Date()).isEmpty)
    }

    @Test func aTimedOutQuestionLeavesTheFeedAndCantBeApproved() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note))
        #expect(asks.items(now: Date()).count == 1)
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(asks.items(now: Date()).isEmpty)
        // The sheet the card opens says yes through the same rule, which says no.
        #expect(rule.sayYes(to: request) == .timedOut)
        #expect(rule.decide(note, approval: request.approve()) == .stop)
    }

    @Test func aTimedOutQuestionOpenedFromAStaleCardStillCantBeApproved() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(note))
        // The card was on screen before the window ran out.
        let card = try #require(asks.items(now: Date()).first?.request)
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.isClosed(card))
        #expect(rule.sayYes(to: card) == .timedOut)
    }

    @Test func aYesFromTheFeedCountsOnceAndTheCardLeaves() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let handed = Handed()
        let asked = asks.ask(note, onApprove: { handed.add($0) })
        #expect(asked != nil)
        let card = try #require(asks.items(now: Date()).first?.request)
        guard case .approved(let approval) = rule.sayYes(to: card) else {
            Issue.record("a yes in time should approve")
            return
        }
        asks.approved(approval)
        #expect(asks.items(now: Date()).isEmpty)
        #expect(handed.approvals == [approval])
        // The approval is the usual single use one.
        #expect(rule.decide(note, approval: approval) == .proceed)
        #expect(rule.decide(note, approval: approval) == .stop)
        // A used question can't be said yes to again.
        #expect(rule.sayYes(to: card) == .timedOut)
    }

    @Test func aYesForOneThingDoesntCoverAnother() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note))
        guard case .approved(let approval) = rule.sayYes(to: request) else {
            Issue.record("a yes in time should approve")
            return
        }
        let changed = ProposedAction(kind: .send, recipient: note.recipient, details: "My address is 12 Elm St")
        #expect(rule.decide(changed, approval: approval) == .stop)
    }

    @Test func notNowWithdrawsTheQuestionForGood() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note))
        // What the sheet does on Not now, then what the feed does.
        rule.withdraw(request)
        asks.dismissed(request)
        #expect(asks.items(now: Date()).isEmpty)
        #expect(rule.sayYes(to: request) == .timedOut)
        #expect(rule.decide(note, approval: request.approve()) == .stop)
    }

    @Test func aQuestionWithdrawnElsewhereAlsoLeavesTheFeed() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note))
        rule.withdraw(request)
        #expect(asks.items(now: Date()).isEmpty)
    }

    // MARK: Sample and words

    @Test func theSampleHasEveryKindButQuestionsAndSaysItIsASample() {
        let source = SampleFeedSource()
        let items = source.items(now: Self.at(17, 10, 40))
        #expect(source.isSample)
        #expect(!EmptyFeedSource().isSample)
        #expect(Set(items.map(\.kind)) == [.did, .ready, .noticed])
        #expect(Set(items.map(\.id)).count == items.count)
        let feed = Feed.build(items, now: Self.at(17, 10, 40), calendar: Self.calendar)
        #expect(feed.groups.map(\.period) == [.thisMorning, .earlier])
    }

    @Test func todayComesFirstAndTheShortcutsFollowTheSidebar() {
        #expect(HomeSection.allCases.first == .today)
        let numbered = HomeWords.shortcuts.filter { $0.keys.hasPrefix("⌘ ") && $0.keys.count == 3 && $0.keys.last!.isNumber }
        #expect(numbered.map(\.action) == HomeSection.allCases.map(\.title))
        #expect(HomeWords.shortcuts.contains { $0.keys == "⌘ N" && $0.action == HomeWords.newChatTitle })
    }

    @Test func feedWordsAreCalmAndUseNoDashes() {
        let sample = SampleFeedSource().items(now: Date()).flatMap { item -> [String] in
            var words = [item.title, item.body]
            switch item.action {
            case .open(let text), .talk(let text): words.append(text)
            default: break
            }
            return words
        }
        for line in FeedWords.all + sample {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
            #expect(!line.contains("!"), "exclamation in: \(line)")
        }
    }
}

/// Collects approvals handed on by `NeedsYou`.
private final class Handed: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Approval] = []
    func add(_ approval: Approval) { lock.lock(); list.append(approval); lock.unlock() }
    var approvals: [Approval] { lock.lock(); defer { lock.unlock() }; return list }
}

extension FeedWords {
    static var all: [String] {
        [title, needsYouHeading, needsYouDetail, thisMorning, thisAfternoon, thisEvening, earlier, yesterday,
         didLabel, readyLabel, noticedLabel, openTitle, talkTitle, reviewTitle, emptyTitle, empty,
         emptyActionTitle, sampleNote, doneTitle, chatWith("Pip")]
    }
}
