import Foundation
@testable import PebbleCore
import Testing

/// A monotonic clock tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += .milliseconds(Int64(seconds * 1000)); lock.unlock() }
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
        #expect(rule.decide(note, approval: request.approve()) == .proceed)
    }

    /// Never calls `isClosed`, so nothing tidies the question away early:
    /// only the window itself can stop this.
    @Test func aYesAfterTheWindowNeverWorksAndSaysWhy() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(note))
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.sayYes(to: request) == .timedOut)
        #expect(rule.verdict(note, approval: request.approve()) == .stop)
    }

    @Test func anApprovalNeverSaidThroughTheSheetAndUsedLateTimesOut() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let approval = try #require(rule.ask(note)).approve()
        clock.advance(AskFirst.defaultWindow + 0.5)
        #expect(rule.verdict(note, approval: approval) == .timedOut)
    }

    @Test func aYesInTimeIsHonoredWhenCheckedLateButNotForever() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let early = try #require(rule.ask(note))
        clock.advance(AskFirst.defaultWindow - 1)
        guard case .approved(let approval) = rule.sayYes(to: early) else { Issue.record("yes refused"); return }
        clock.advance(10)
        #expect(rule.verdict(note, approval: approval) == .proceed)

        let stale = try #require(rule.ask(note))
        guard case .approved(let held) = rule.sayYes(to: stale) else { Issue.record("yes refused"); return }
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.verdict(note, approval: held) == .timedOut)
    }

    /// Changing the date and time in Settings must not bring a question back.
    /// The rule may read only a monotonic clock, never the wall clock.
    @Test func expiryNeverReadsTheWallClock() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleCore/AskFirst.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "public final class AskFirst"))
        let rule = String(text[start.lowerBound...])
        for wall in ["Date(", "Date.init", "Date.now", "-> Date", ": Date", "timeIntervalSince"] {
            #expect(!rule.contains(wall), "AskFirst reads the wall clock: \(wall)")
        }
        #expect(rule.contains("ContinuousClock"))
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
