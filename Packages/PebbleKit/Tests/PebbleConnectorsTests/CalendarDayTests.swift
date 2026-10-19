import Foundation
@testable import PebbleConnectors
import Testing

/// Times for the tests, in New York unless a test says otherwise, so the
/// clocks change on 8 March 2026 (a 23 hour day) and 1 November 2026 (25).
enum Clock {
    static func calendar(_ zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static let newYork = calendar()

    /// A wall clock time in `calendar`. Never a time the clocks skip or
    /// repeat; those are written as UTC with `utc`.
    static func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar = newYork) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func utc(_ text: String) -> Date {
        try! Date(text + "Z", strategy: .iso8601)
    }

    static func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay)
    }

    /// An all day event as the calendar gives it: midnight to midnight.
    static func allDay(_ id: String, _ month: Int, _ day: Int, in calendar: Calendar = newYork) -> CalendarEvent {
        let start = at(month, day, 0, in: calendar)
        return event(id, start, calendar.date(byAdding: .day, value: 1, to: start)!, allDay: true)
    }
}

struct ClashCase: Sendable, CustomTestStringConvertible {
    let name: String
    let events: [CalendarEvent]
    let window: DateInterval
    /// The pairs that clash, by id, in order.
    let clashes: [[String]]

    var testDescription: String { name }

    static let day = DateInterval(start: Clock.at(6, 1, 0), end: Clock.at(6, 2, 0))
    static let springDay = DateInterval(start: Clock.at(3, 8, 0), end: Clock.at(3, 9, 0))

    static let all: [ClashCase] = [
        ClashCase(name: "overlapping", events: [Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 10)),
                                                Clock.event("b", Clock.at(6, 1, 9, 30), Clock.at(6, 1, 11))],
                  window: day, clashes: [["a", "b"]]),
        ClashCase(name: "touching edges", events: [Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 10)),
                                                   Clock.event("b", Clock.at(6, 1, 10), Clock.at(6, 1, 11))],
                  window: day, clashes: []),
        ClashCase(name: "one inside another", events: [Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 12)),
                                                       Clock.event("b", Clock.at(6, 1, 10), Clock.at(6, 1, 11))],
                  window: day, clashes: [["a", "b"]]),
        ClashCase(name: "the same time twice", events: [Clock.event("b", Clock.at(6, 1, 9), Clock.at(6, 1, 10)),
                                                        Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 10))],
                  window: day, clashes: [["a", "b"]]),
        ClashCase(name: "three at once", events: [Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 12)),
                                                  Clock.event("b", Clock.at(6, 1, 10), Clock.at(6, 1, 11)),
                                                  Clock.event("c", Clock.at(6, 1, 10, 30), Clock.at(6, 1, 13))],
                  window: day, clashes: [["a", "b"], ["a", "c"], ["b", "c"]]),
        ClashCase(name: "all day beside timed", events: [Clock.allDay("holiday", 6, 1),
                                                         Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 10))],
                  window: day, clashes: []),
        ClashCase(name: "two all day", events: [Clock.allDay("holiday", 6, 1), Clock.allDay("trip", 6, 1)],
                  window: day, clashes: []),
        ClashCase(name: "an overlap before the window",
                  events: [Clock.event("a", Clock.at(5, 31, 20), Clock.at(5, 31, 22)),
                           Clock.event("b", Clock.at(5, 31, 21), Clock.at(6, 1, 0))],
                  window: day, clashes: []),
        ClashCase(name: "an overlap across the window's start",
                  events: [Clock.event("a", Clock.at(5, 31, 22), Clock.at(6, 1, 2)),
                           Clock.event("b", Clock.at(5, 31, 23), Clock.at(6, 1, 1))],
                  window: day, clashes: [["a", "b"]]),
        ClashCase(name: "no time at all", events: [Clock.event("a", Clock.at(6, 1, 9), Clock.at(6, 1, 9)),
                                                   Clock.event("b", Clock.at(6, 1, 8), Clock.at(6, 1, 10))],
                  window: day, clashes: []),
        // 1:00 in the morning to 3:00 is one hour on the day the clocks
        // go forward, so the next event at 3:00 only touches it.
        ClashCase(name: "touching across the clock change",
                  events: [Clock.event("a", Clock.utc("2026-03-08T06:00:00"), Clock.utc("2026-03-08T07:00:00")),
                           Clock.event("b", Clock.utc("2026-03-08T07:00:00"), Clock.utc("2026-03-08T08:00:00"))],
                  window: springDay, clashes: []),
        ClashCase(name: "overlapping across the clock change",
                  events: [Clock.event("a", Clock.utc("2026-03-08T06:30:00"), Clock.utc("2026-03-08T07:30:00")),
                           Clock.event("b", Clock.utc("2026-03-08T07:00:00"), Clock.utc("2026-03-08T08:00:00"))],
                  window: springDay, clashes: [["a", "b"]]),
    ]
}

struct CalendarClashTests {
    @Test(arguments: ClashCase.all)
    func clashes(_ example: ClashCase) {
        let found = CalendarClashes.find(in: example.events, window: example.window)
        #expect(found.map { [$0.first.id, $0.second.id] } == example.clashes)
        for clash in found {
            #expect(clash.shared.duration > 0)
            #expect(example.window.contains(clash.shared.start) && clash.shared.end <= example.window.end)
        }
    }

    @Test func theSharedTimeIsWhatBothHold() {
        let found = CalendarClashes.find(in: ClashCase.all[0].events, window: ClashCase.day)
        #expect(found.map(\.shared) == [DateInterval(start: Clock.at(6, 1, 9, 30), end: Clock.at(6, 1, 10))])
    }

    @Test func theSharedTimeAcrossTheClockChangeIsHalfAnHour() {
        let found = CalendarClashes.find(in: ClashCase.all[11].events, window: ClashCase.springDay)
        #expect(found.map(\.shared.duration) == [1_800])
    }
}

struct MorningCalendarSummaryTests {
    @Test func anOrdinaryMorning() {
        let events = [
            Clock.event("later", Clock.at(6, 1, 10, 30), Clock.at(6, 1, 11, 30)),
            Clock.event("standup", Clock.at(6, 1, 9), Clock.at(6, 1, 9, 15)),
            Clock.event("review", Clock.at(6, 1, 10), Clock.at(6, 1, 11)),
            Clock.allDay("birthday", 6, 1),
            Clock.event("tomorrow", Clock.at(6, 2, 9), Clock.at(6, 2, 10)),
            Clock.event("yesterday", Clock.at(5, 31, 9), Clock.at(5, 31, 10)),
        ]
        let reminders = [
            CalendarReminder(id: "bins", title: "Bins", due: Clock.at(5, 31, 20)),
            CalendarReminder(id: "pay", title: "Pay rent", due: Clock.at(5, 31, 0), dueHasTime: false),
            CalendarReminder(id: "done", title: "Done", due: Clock.at(5, 30, 9), isCompleted: true),
            CalendarReminder(id: "today", title: "Today, no time", due: Clock.at(6, 1, 0), dueHasTime: false),
            CalendarReminder(id: "noon", title: "At noon", due: Clock.at(6, 1, 12)),
            CalendarReminder(id: "someday", title: "Someday", due: nil),
        ]
        let summary = MorningCalendarSummary(events: events, reminders: reminders, now: Clock.at(6, 1, 7),
                                             calendar: Clock.newYork)
        #expect(summary.day == DateInterval(start: Clock.at(6, 1, 0), end: Clock.at(6, 2, 0)))
        #expect(summary.firstEvent?.id == "standup")
        #expect(summary.eventCount == 4)
        #expect(summary.allDayCount == 1)
        #expect(summary.clashes.map { [$0.first.id, $0.second.id] } == [["review", "later"]])
        #expect(summary.overdueReminders.map(\.id) == ["pay", "bins"])
    }

    /// Later in the morning the first event is the next one not over yet,
    /// and one under way still counts.
    @Test func theFirstEventIsTheFirstNotOverYet() {
        let events = [Clock.allDay("birthday", 6, 1),
                      Clock.event("standup", Clock.at(6, 1, 9), Clock.at(6, 1, 9, 15)),
                      Clock.event("review", Clock.at(6, 1, 10), Clock.at(6, 1, 11))]
        let under = MorningCalendarSummary(events: events, reminders: [], now: Clock.at(6, 1, 10, 15),
                                           calendar: Clock.newYork)
        #expect(under.firstEvent?.id == "review")
        let evening = MorningCalendarSummary(events: events, reminders: [], now: Clock.at(6, 1, 20),
                                             calendar: Clock.newYork)
        #expect(evening.firstEvent == nil, "an all day event is never the first thing to go to")
        #expect(evening.eventCount == 3)
    }

    /// The day the clocks go back has 25 hours, so an event at half past
    /// eleven that night is still today, and a day counted as 24 hours
    /// would lose it.
    @Test func aDayWithTwentyFiveHours() {
        let late = Clock.event("late", Clock.at(11, 1, 23, 30), Clock.at(11, 1, 23, 45))
        let next = Clock.event("next", Clock.at(11, 2, 0, 30), Clock.at(11, 2, 1))
        let summary = MorningCalendarSummary(events: [late, next], reminders: [], now: Clock.at(11, 1, 7),
                                             calendar: Clock.newYork)
        #expect(summary.day.duration == 25 * 3_600)
        #expect(summary.eventCount == 1)
        #expect(summary.firstEvent == late)
    }

    /// The day the clocks go forward has 23 hours, so half past midnight
    /// the next morning is tomorrow, though it is 24 hours after midnight
    /// in the hours this day had.
    @Test func aDayWithTwentyThreeHours() {
        let tomorrow = Clock.event("tomorrow", Clock.at(3, 9, 0, 30), Clock.at(3, 9, 1))
        let early = Clock.event("early", Clock.utc("2026-03-08T06:30:00"), Clock.utc("2026-03-08T07:30:00"))
        let overlapping = Clock.event("overlap", Clock.utc("2026-03-08T07:00:00"), Clock.utc("2026-03-08T08:00:00"))
        let summary = MorningCalendarSummary(events: [tomorrow, overlapping, early, Clock.allDay("trip", 3, 8)],
                                             reminders: [], now: Clock.at(3, 8, 0, 15), calendar: Clock.newYork)
        #expect(summary.day.duration == 23 * 3_600)
        #expect(summary.eventCount == 3)
        #expect(summary.allDayCount == 1)
        #expect(summary.firstEvent == early)
        #expect(summary.clashes.map { [$0.first.id, $0.second.id] } == [["early", "overlap"]])
    }

    /// An all day event covers the day it is on, and on the day the clocks
    /// change too, but it is never the first event and never clashes.
    @Test func anAllDayEventIsCountedButNeverClashes() {
        let summary = MorningCalendarSummary(
            events: [Clock.allDay("trip", 11, 1), Clock.event("lunch", Clock.at(11, 1, 12), Clock.at(11, 1, 13))],
            reminders: [], now: Clock.at(11, 1, 7), calendar: Clock.newYork)
        #expect(summary.eventCount == 2)
        #expect(summary.allDayCount == 1)
        #expect(summary.clashes.isEmpty)
        #expect(summary.firstEvent?.id == "lunch")

        let yesterday = MorningCalendarSummary(events: [Clock.allDay("trip", 10, 31)], reminders: [],
                                               now: Clock.at(11, 1, 7), calendar: Clock.newYork)
        #expect(yesterday.eventCount == 0, "an all day event ending at midnight only touches the next day")
    }

    /// The same moment is a different day in another time zone, and the
    /// summary follows the calendar it is given.
    @Test func theTimeZoneDecidesTheDay() {
        let breakfast = Clock.event("breakfast", Clock.utc("2026-06-01T13:00:00"), Clock.utc("2026-06-01T14:00:00"))
        let now = Clock.utc("2026-06-01T02:00:00")
        let newYork = MorningCalendarSummary(events: [breakfast], reminders: [], now: now, calendar: Clock.newYork)
        let tokyo = MorningCalendarSummary(events: [breakfast], reminders: [], now: now,
                                           calendar: Clock.calendar("Asia/Tokyo"))
        #expect(newYork.eventCount == 0, "still the evening before in New York")
        #expect(tokyo.eventCount == 1)
        #expect(tokyo.day.start == Clock.utc("2026-05-31T15:00:00"))
    }

    /// A reminder due on a day with no time is overdue only once that day
    /// is over where the person is, and the clock change doesn't move it.
    @Test func aReminderWithNoTimeIsOverdueTheDayAfter() {
        let due = CalendarReminder(id: "pay", title: "Pay rent", due: Clock.at(3, 8, 0), dueHasTime: false)
        #expect(!due.isOverdue(now: Clock.at(3, 8, 23, 30), calendar: Clock.newYork))
        #expect(due.isOverdue(now: Clock.at(3, 9, 0, 1), calendar: Clock.newYork))
        let timed = CalendarReminder(id: "call", title: "Call", due: Clock.utc("2026-03-08T07:30:00"))
        #expect(!timed.isOverdue(now: Clock.utc("2026-03-08T07:29:00"), calendar: Clock.newYork))
        #expect(timed.isOverdue(now: Clock.utc("2026-03-08T07:31:00"), calendar: Clock.newYork))
    }
}
