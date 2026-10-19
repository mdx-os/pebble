import Foundation

/// A calendar store in memory, for tests and examples. It behaves as the
/// system's does: it hands back nothing it isn't allowed to, and asking
/// changes what it allows only the first time.
public final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: [CalendarKind: CalendarAccess]
    private var answers: [CalendarKind: CalendarAccess]
    private var asked: [CalendarKind: Int] = [:]
    private let events: [CalendarEvent]
    private let reminders: [CalendarReminder]?

    /// `access` is what the system allows now, and `answer` what the person
    /// chooses when asked. With `reminders` nil, reading them gives nothing back.
    public init(events: [CalendarEvent] = [], reminders: [CalendarReminder]? = [],
                access: CalendarAccess = .fullAccess, answer: CalendarAccess = .fullAccess) {
        self.events = events
        self.reminders = reminders
        allowed = [.events: access, .reminders: access]
        answers = [.events: answer, .reminders: answer]
    }

    public func setAccess(_ access: CalendarAccess, for kind: CalendarKind) {
        lock.withLock { allowed[kind] = access }
    }

    /// How many times the person was asked about `kind`.
    public func timesAsked(_ kind: CalendarKind) -> Int {
        lock.withLock { asked[kind, default: 0] }
    }

    public func access(_ kind: CalendarKind) -> CalendarAccess {
        lock.withLock { allowed[kind] ?? .notDetermined }
    }

    public func requestAccess(_ kind: CalendarKind) async -> CalendarAccess {
        lock.withLock {
            asked[kind, default: 0] += 1
            if allowed[kind] == .notDetermined { allowed[kind] = answers[kind] ?? .denied }
            return allowed[kind] ?? .denied
        }
    }

    public func events(in window: DateInterval) async -> [CalendarEvent] {
        guard access(.events) == .fullAccess else { return [] }
        return events
    }

    public func reminders(dueBy end: Date) async -> [CalendarReminder]? {
        guard access(.reminders) == .fullAccess else { return [] }
        return reminders
    }
}
