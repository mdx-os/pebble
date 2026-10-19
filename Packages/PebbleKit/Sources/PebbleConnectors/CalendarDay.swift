import Foundation

/// Two timed events that share time.
public struct CalendarClash: Sendable, Equatable {
    /// The one that starts first, or ends first when both start together.
    public let first: CalendarEvent
    public let second: CalendarEvent
    /// The time they share, inside the window they were found in.
    public let shared: DateInterval
}

public enum CalendarClashes {
    /// Every pair of timed events that share time inside `window`, in the
    /// order of their shared time. All day events never clash: they say
    /// what a day is, not where the person has to be. Events that only
    /// touch, one ending as the next begins, don't clash either.
    public static func find(in events: [CalendarEvent], window: DateInterval) -> [CalendarClash] {
        let timed = events.filter { !$0.isAllDay }.sorted(by: CalendarEvent.earlier)
        var clashes: [CalendarClash] = []
        for (index, first) in timed.enumerated() {
            for second in timed[(index + 1)...] {
                let start = max(first.start, second.start, window.start)
                let end = min(first.end, second.end, window.end)
                if start < end {
                    clashes.append(CalendarClash(first: first, second: second, shared: DateInterval(start: start, end: end)))
                }
            }
        }
        return clashes.sorted { ($0.shared.start, $0.first.id, $0.second.id) < ($1.shared.start, $1.first.id, $1.second.id) }
    }
}

/// What a morning card on Today can say about the day: what comes first,
/// how much there is, what clashes and what is overdue. Plain values, made
/// from what a read found; a read that was blocked gives its reason
/// instead, never this with nothing in it.
public struct MorningCalendarSummary: Sendable, Equatable {
    /// The day `now` falls on, from midnight to midnight in the calendar's
    /// time zone. On a day the clocks change it is 23 or 25 hours.
    public let day: DateInterval
    /// The first timed event of the day that hasn't ended by `now`.
    public let firstEvent: CalendarEvent?
    /// Every event on the day, all day ones included.
    public let eventCount: Int
    /// How many of those are all day.
    public let allDayCount: Int
    public let clashes: [CalendarClash]
    /// Reminders not done whose time has passed, the oldest first.
    public let overdueReminders: [CalendarReminder]

    /// The summary of the day `now` falls on in `calendar`, whose time zone
    /// decides where the day starts and ends.
    public init(events: [CalendarEvent], reminders: [CalendarReminder], now: Date, calendar: Calendar) {
        let day = Self.day(of: now, calendar: calendar)
        self.day = day
        let today = events.filter { $0.overlaps(day) }.sorted(by: CalendarEvent.earlier)
        eventCount = today.count
        allDayCount = today.filter(\.isAllDay).count
        firstEvent = today.first { !$0.isAllDay && $0.end > now }
        clashes = CalendarClashes.find(in: today, window: day)
        overdueReminders = reminders.filter { $0.isOverdue(now: now, calendar: calendar) }
            .sorted { ($0.due ?? now, $0.id) < ($1.due ?? now, $1.id) }
    }

    /// Midnight to midnight around `now`, as `calendar` counts it.
    static func day(of now: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
    }
}
