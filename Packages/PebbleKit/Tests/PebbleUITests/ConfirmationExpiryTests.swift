#if canImport(SwiftUI)
import Foundation
@testable import PebbleCore
import Testing
@testable import PebbleUI

@MainActor
struct ConfirmationExpiryTests {
    @Test func yesOnATimedOutSheetDoesNothingButSaySo() throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSinceReferenceDate: 0) }
        let clock = Clock()
        let rule = AskFirst.isolated(now: { clock.t })
        let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")
        let request = try #require(rule.ask(action))
        var approved = 0
        var declined = 0
        let sheet = ConfirmationSheet(request: request, rule: rule, onApprove: { _ in approved += 1 }, onDecline: { declined += 1 })
        clock.t += AskFirst.defaultWindow + 1
        sheet.approve()
        #expect(approved == 0)
        #expect(declined == 1)
    }
}
#endif
