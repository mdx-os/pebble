#if canImport(SwiftUI)
import Foundation
@testable import PebbleCore
import SwiftUI
import Testing
@testable import PebbleUI

/// Taps are felt only on iPhone, and each answer to a question gets one.
@MainActor
struct HapticTests {
    let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")

    @Test func onlyAPhoneFeelsATap() {
        for haptic in [Haptic.sent, .answered, .saved, .forgotten] {
            #expect(haptic.feedback(on: .phone) != nil, "\(haptic) on phone")
            #expect(haptic.feedback(on: .pad) == nil, "\(haptic) on pad")
            #expect(haptic.feedback(on: .mac) == nil, "\(haptic) on mac")
        }
        #if os(macOS)
        #expect(Haptic.Device.current == .mac)
        #endif
    }

    /// Plays the sheet the way `.haptic(_:trigger:when:)` sees it: one look
    /// at each change of screen, a tap when the new screen passes the rule.
    private func taps(on device: Haptic.Device, answer: (ConfirmationState) -> Void) throws -> Int {
        let clock = SheetClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.ask(action))
        let sheet = ConfirmationState(request: request, rule: rule, now: clock.now,
                                      onApprove: { _ in }, onDecline: {})
        var screens = [sheet.screen]
        func look() { if sheet.screen != screens.last { screens.append(sheet.screen) } }
        sheet.tick(); look()
        answer(sheet); look()
        // Pressing again, or Escape, after answering changes nothing.
        sheet.tapPrimary(); look()
        sheet.cancel(); look()
        sheet.disappeared(); look()
        return screens.dropFirst()
            .filter(ConfirmationState.tapsOnChange(to:))
            .compactMap { _ in Haptic.answered.feedback(on: device) }
            .count
    }

    @Test func yesTapsOnceOnAPhone() throws {
        #expect(try taps(on: .phone) { $0.tapPrimary() } == 1)
        #expect(try taps(on: .pad) { $0.tapPrimary() } == 0)
        #expect(try taps(on: .mac) { $0.tapPrimary() } == 0)
    }

    @Test func notNowTapsOnceOnAPhone() throws {
        #expect(try taps(on: .phone) { $0.cancel() } == 1)
        #expect(try taps(on: .pad) { $0.cancel() } == 0)
        #expect(try taps(on: .mac) { $0.cancel() } == 0)
    }

    @Test func aTimeoutIsNotATap() {
        #expect(!ConfirmationState.tapsOnChange(to: .timedOut))
        #expect(!ConfirmationState.tapsOnChange(to: .asking))
        #expect(ConfirmationState.tapsOnChange(to: .answered))
    }
}
#endif
