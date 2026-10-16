#if canImport(SwiftUI)
import Foundation
@testable import PebbleCore
import Testing
@testable import PebbleUI

/// A monotonic clock tests can move forward.
final class SheetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ by: Duration) { lock.lock(); time += by; lock.unlock() }
}

@MainActor
struct ConfirmationExpiryTests {
    let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")
    let window = Duration.seconds(AskFirst.defaultWindow)

    private func makeSheet(_ clock: SheetClock, approved: @escaping () -> Void = {}, declined: @escaping () -> Void = {})
        throws -> (AskFirst, ConfirmationState) {
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(action))
        let state = ConfirmationState(request: request, rule: rule, now: clock.now,
                                      onApprove: { _ in approved() }, onDecline: declined)
        return (rule, state)
    }

    @Test func aLateYesShowsTheTimedOutScreenAndApprovesNothing() throws {
        let clock = SheetClock()
        var approved = 0
        var declined = 0
        let (_, sheet) = try makeSheet(clock, approved: { approved += 1 }, declined: { declined += 1 })
        #expect(sheet.screen == .asking)
        #expect(sheet.primaryTitle == ProposedAction.yesTitle)
        clock.advance(window + .seconds(1))
        #expect(sheet.tapPrimary() == .timedOut)
        #expect(sheet.screen == .timedOut)
        #expect(sheet.primaryTitle == ConfirmationWords.closeTitle)
        #expect(!sheet.showsNotNow)
        #expect(sheet.footnote == ConfirmationWords.expired)
        #expect(sheet.spoken == ConfirmationWords.expired)
        #expect(approved == 0)
        #expect(declined == 0)
    }

    @Test func theSheetTimesOutOnItsOwnWhileOpen() throws {
        let clock = SheetClock()
        let (_, sheet) = try makeSheet(clock)
        sheet.tick()
        #expect(sheet.screen == .asking)
        clock.advance(window + .seconds(1))
        sheet.tick()
        #expect(sheet.screen == .timedOut)
    }

    @Test func aMistimedTapRightAfterTheSwapDoesNotDismiss() throws {
        let clock = SheetClock()
        var declined = 0
        let (_, sheet) = try makeSheet(clock, declined: { declined += 1 })
        clock.advance(window + .seconds(1))
        sheet.tick()
        clock.advance(.milliseconds(200))
        #expect(sheet.tapPrimary() == .ignored)
        #expect(sheet.screen == .timedOut)
        #expect(declined == 0)
        clock.advance(ConfirmationState.closeGrace)
        #expect(sheet.tapPrimary() == .closed)
        #expect(declined == 1)
    }

    @Test func escapeStillClosesAfterATimeout() throws {
        let clock = SheetClock()
        var declined = 0
        let (_, sheet) = try makeSheet(clock, declined: { declined += 1 })
        clock.advance(window + .seconds(1))
        sheet.tick()
        #expect(sheet.cancel() == .closed)
        #expect(declined == 1)
        #expect(sheet.screen == .answered)
    }

    @Test func aYesInTimeStillProceedsWhenCheckedLate() throws {
        let clock = SheetClock()
        var approval: Approval?
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(action))
        let sheet = ConfirmationState(request: request, rule: rule, now: clock.now,
                                      onApprove: { approval = $0 }, onDecline: {})
        clock.advance(window - .seconds(1))
        #expect(sheet.tapPrimary() == .approved)
        clock.advance(.seconds(5))
        #expect(rule.verdict(action, approval: approval) == .proceed)
        #expect(rule.verdict(action, approval: approval) == .stop)
    }
}
#endif
