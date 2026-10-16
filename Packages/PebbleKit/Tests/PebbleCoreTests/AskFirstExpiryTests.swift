import Foundation
@testable import PebbleCore
import Testing

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
}

struct AskFirstExpiryTests {
    let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Running late")

    @Test func theWindowIsShortAndSensible() {
        #expect(AskFirst.defaultWindow == 300)
    }

    @Test func aYesInsideTheWindowWorks() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(note))
        clock.advance(AskFirst.defaultWindow - 1)
        #expect(!rule.isClosed(request))
        #expect(rule.decide(note, approval: request.approve()) == .proceed)
    }

    @Test func aYesAfterTheWindowNeverWorks() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(note))
        let approval = request.approve()
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.isClosed(request))
        #expect(rule.decide(note, approval: approval) == .stop)
        clock.advance(-AskFirst.defaultWindow)
        #expect(rule.decide(note, approval: approval) == .stop)
    }

    @Test func anApprovalMadeInTimeButUsedLateStops() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let approval = try #require(rule.ask(note)).approve()
        clock.advance(AskFirst.defaultWindow + 0.5)
        #expect(rule.decide(note, approval: approval) == .stop)
    }

    @Test func aClockThatJumpsBackDoesNotReopenAQuestion() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let approval = try #require(rule.ask(note)).approve()
        clock.advance(-60)
        #expect(rule.decide(note, approval: approval) == .stop)
    }

    @Test func isClosedAgreesWithDecideWhenTheClockJumpsBack() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(note))
        clock.advance(-60)
        #expect(rule.isClosed(request))
    }

    @Test func askingAgainGivesAFreshWindow() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        _ = rule.ask(note)
        clock.advance(AskFirst.defaultWindow * 2)
        let fresh = try #require(rule.ask(note))
        #expect(rule.decide(note, approval: fresh.approve()) == .proceed)
    }

    @Test func expiredWordsAreWarmAndDashFree() {
        #expect(!ConfirmationWords.expired.contains("\u{2014}") && !ConfirmationWords.expired.contains("\u{2013}"))
    }
}
