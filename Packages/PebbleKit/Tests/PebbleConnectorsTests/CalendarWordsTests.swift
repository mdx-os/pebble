import Foundation
import PebbleConnectors
import PromiseWords
import Testing

/// docs/VOICE.md for the calendar's reasons: no dashes, no promise about
/// where words go, none of the system words, and each one its own.
struct CalendarWordsTests {
    static let dashes: [Character] = ["\u{2014}", "\u{2013}"]
    static let systemWords = ["error", "failed", "invalid", "permission", "authoriz", "access", "denied",
                              "restricted", "status", "request", "eventkit"]

    @Test func everyReasonIsPlainAndKind() {
        let all = CalendarWords.all
        #expect(all.count == CalendarBlock.Why.allCases.count * CalendarKind.allCases.count)
        #expect(Set(all).count == all.count, "each reason says its own thing")
        for line in all {
            #expect(!line.isEmpty)
            #expect(!line.contains(where: Self.dashes.contains), "dash in: \(line)")
            #expect(!line.contains("!"), "no exclamation marks in a reason: \(line)")
            #expect(DevicePromise.found(in: line).isEmpty, "promises \(DevicePromise.found(in: line)): \(line)")
            for word in Self.systemWords {
                #expect(!line.lowercased().contains(word), "\(word) in: \(line)")
            }
        }
    }

    @Test func eachBlockReadsItsOwnReason() {
        for why in CalendarBlock.Why.allCases {
            #expect(CalendarBlock(kind: .events, why: why).words.contains("calendar"))
            #expect(CalendarBlock(kind: .reminders, why: why).words.contains("reminders"))
        }
    }
}
