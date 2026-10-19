import Foundation

// The calendar connector: what is on the person's calendar and in their
// reminders, read and never changed. Everything it reads stays in memory,
// as the plain values below. Nothing here opens a connection, keeps a file
// or logs a line, and `ConnectorGate` in Tools/GuardKit checks that.

/// One event, as plain values. An all day event's start and end are the
/// midnights its calendar gives, so it covers whole days.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarName: String
    public let isAllDay: Bool
    /// The place as written on the event, if it has one.
    public let location: String?

    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date, calendarName: String = "",
                isAllDay: Bool = false, location: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(start, end)
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.location = location
    }
}

/// One reminder, as plain values.
public struct CalendarReminder: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// When it is due, if it has a date. A reminder due on a day with no
    /// time has `dueHasTime` false and `due` at the start of that day.
    public let due: Date?
    public let dueHasTime: Bool
    public let listName: String
    public let isCompleted: Bool

    public init(id: String = UUID().uuidString, title: String, due: Date?, dueHasTime: Bool = true,
                listName: String = "", isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = due == nil ? false : dueHasTime
        self.listName = listName
        self.isCompleted = isCompleted
    }

    /// True when it is not done and its time has passed. One due on a day
    /// with no time is overdue only once that day is over, in `calendar`.
    public func isOverdue(now: Date, calendar: Calendar) -> Bool {
        guard !isCompleted, let due else { return false }
        if dueHasTime { return due < now }
        return calendar.compare(due, to: now, toGranularity: .day) == .orderedAscending
    }
}

/// What the connector reads: the calendar's events, or the reminders.
public enum CalendarKind: Sendable, Equatable, CaseIterable {
    case events
    case reminders
}

/// What the person has said about letting the agent read a kind, as the
/// system keeps it.
public enum CalendarAccess: Sendable, Equatable, CaseIterable {
    /// Never asked.
    case notDetermined
    /// The person said no.
    case denied
    /// A setting the person can't change keeps it closed, such as one from
    /// work or school.
    case restricted
    /// May read everything.
    case fullAccess
    /// May add events but not read them.
    case writeOnly
}

/// Why a read gave no answer. Each has its reason in plain words, so a
/// closed calendar never looks like an empty one.
public struct CalendarBlock: Sendable, Equatable {
    public enum Why: Sendable, Equatable, CaseIterable {
        case notAskedYet
        case denied
        case restricted
        case writeOnly
        /// Allowed, but the system gave nothing back.
        case couldNotRead
    }

    public let kind: CalendarKind
    public let why: Why

    public init(kind: CalendarKind, why: Why) {
        self.kind = kind
        self.why = why
    }

    /// The block for `access`, or nil when it lets the agent read.
    public init?(kind: CalendarKind, access: CalendarAccess) {
        switch access {
        case .fullAccess: return nil
        case .notDetermined: self.init(kind: kind, why: .notAskedYet)
        case .denied: self.init(kind: kind, why: .denied)
        case .restricted: self.init(kind: kind, why: .restricted)
        case .writeOnly: self.init(kind: kind, why: .writeOnly)
        }
    }

    /// The reason, for the person to read.
    public var words: String { CalendarWords.reason(why, kind: kind) }
}

/// A read's answer: what was found, or why nothing could be read. Found
/// and empty means there really is nothing.
public enum CalendarAnswer<Value: Sendable>: Sendable {
    case found(Value)
    case blocked(CalendarBlock)

    public var value: Value? {
        if case .found(let value) = self { return value }
        return nil
    }

    public var block: CalendarBlock? {
        if case .blocked(let block) = self { return block }
        return nil
    }
}

extension CalendarAnswer: Equatable where Value: Equatable {}

/// The calendar as the agent may use it. Reading never asks the person:
/// it says what the system already allows, and when that isn't enough it
/// answers with the reason. Asking is its own call, made only once the
/// person has asked for something that needs it.
public protocol CalendarSource: Sendable {
    /// What the system allows now. Never asks.
    func access(_ kind: CalendarKind) -> CalendarAccess
    /// Asks the person, once, if they have never been asked, and gives
    /// back what they chose. Call it only in answer to something the
    /// person asked for.
    func requestAccess(_ kind: CalendarKind) async -> CalendarAccess
    /// The events that overlap `window`, earliest first.
    func events(in window: DateInterval) async -> CalendarAnswer<[CalendarEvent]>
    /// The reminders not yet done that are due by `end`, overdue ones
    /// included, soonest first.
    func reminders(dueBy end: Date) async -> CalendarAnswer<[CalendarReminder]>
}

/// What the connector needs from the system's calendar store. EventKit is
/// the real one (`EventKitCalendarStore`), and tests use `FakeCalendarStore`.
/// Only `CalendarConnector` reads a store, so every read goes through its
/// check of what the person allowed.
public protocol CalendarStore: Sendable {
    func access(_ kind: CalendarKind) -> CalendarAccess
    func requestAccess(_ kind: CalendarKind) async -> CalendarAccess
    func events(in window: DateInterval) async -> [CalendarEvent]
    /// Reminders not yet done, due by `end`, or nil when the store could
    /// give none back.
    func reminders(dueBy end: Date) async -> [CalendarReminder]?
}

/// The calendar source the app uses, over any store.
public struct CalendarConnector: CalendarSource {
    let store: any CalendarStore

    public init(store: any CalendarStore) {
        self.store = store
    }

    public func access(_ kind: CalendarKind) -> CalendarAccess {
        store.access(kind)
    }

    /// Asks only when the person has never been asked. A no stays a no:
    /// the system wouldn't ask again, so neither does this.
    public func requestAccess(_ kind: CalendarKind) async -> CalendarAccess {
        let now = store.access(kind)
        guard now == .notDetermined else { return now }
        return await store.requestAccess(kind)
    }

    public func events(in window: DateInterval) async -> CalendarAnswer<[CalendarEvent]> {
        let access = store.access(.events)
        if let block = CalendarBlock(kind: .events, access: access) { return .blocked(block) }
        let found = await store.events(in: window)
        return .found(found.filter { $0.overlaps(window) }.sorted(by: CalendarEvent.earlier))
    }

    public func reminders(dueBy end: Date) async -> CalendarAnswer<[CalendarReminder]> {
        let access = store.access(.reminders)
        if let block = CalendarBlock(kind: .reminders, access: access) { return .blocked(block) }
        guard let found = await store.reminders(dueBy: end) else {
            return .blocked(CalendarBlock(kind: .reminders, why: .couldNotRead))
        }
        let due = found.filter { reminder in
            guard let date = reminder.due else { return false }
            return !reminder.isCompleted && date <= end
        }
        return .found(due.sorted { ($0.due ?? end, $0.id) < ($1.due ?? end, $1.id) })
    }
}

extension CalendarEvent {
    /// True when the event and `window` share some time. Touching at an
    /// edge is not sharing. An event with no length is in the window when
    /// its moment is, from the window's start up to its end.
    func overlaps(_ window: DateInterval) -> Bool {
        if start == end { return start >= window.start && start < window.end }
        return start < window.end && end > window.start
    }

    /// Earliest start first, then the earliest end, then by id, so the
    /// order never depends on the store's.
    static func earlier(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        (a.start, a.end, a.id) < (b.start, b.end, b.id)
    }
}
