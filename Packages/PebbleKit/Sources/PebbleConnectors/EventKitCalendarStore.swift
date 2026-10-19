#if canImport(EventKit)
import EventKit
import Foundation

/// The system's calendar and reminders, through EventKit, read only. It
/// never asks the person by itself: `access` only reads what the system
/// keeps, and `requestAccess` is the one call that asks. What it reads is
/// turned into plain values at once and kept nowhere.
///
/// Asking needs the app's usage strings for full access to events and to
/// reminders; without them the system ends the app as it asks.
public final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    private let store: EKEventStore
    /// Reads a reminder's due date, when its own components name no calendar.
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        store = EKEventStore()
        self.calendar = calendar
    }

    public func access(_ kind: CalendarKind) -> CalendarAccess {
        Self.access(EKEventStore.authorizationStatus(for: Self.entity(kind)))
    }

    public func requestAccess(_ kind: CalendarKind) async -> CalendarAccess {
        do {
            switch kind {
            case .events: _ = try await store.requestFullAccessToEvents()
            case .reminders: _ = try await store.requestFullAccessToReminders()
            }
        } catch {
            // What the person chose is read back below either way.
        }
        return access(kind)
    }

    public func events(in window: DateInterval) async -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        return store.events(matching: predicate).map(Self.event)
    }

    public func reminders(dueBy end: Date) async -> [CalendarReminder]? {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let calendar = calendar
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found.map { $0.map { Self.reminder($0, calendar: calendar) } })
            }
        }
    }

    static func entity(_ kind: CalendarKind) -> EKEntityType {
        switch kind {
        case .events: .event
        case .reminders: .reminder
        }
    }

    /// The system's status in the connector's words. A status this code
    /// doesn't know yet reads as closed, so it is never taken for a yes.
    static func access(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    static func event(_ event: EKEvent) -> CalendarEvent {
        let start: Date = event.startDate
        let end: Date = event.endDate ?? start
        // A repeating event's occurrences share an identifier, so the
        // start tells them apart.
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEvent(id: "\(identifier) \(start.timeIntervalSinceReferenceDate)",
                             title: event.title ?? "", start: start, end: end,
                             calendarName: event.calendar?.title ?? "", isAllDay: event.isAllDay,
                             location: event.location.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func reminder(_ reminder: EKReminder, calendar: Calendar) -> CalendarReminder {
        let components = reminder.dueDateComponents
        let due = components.flatMap { components in (components.calendar ?? calendar).date(from: components) }
        return CalendarReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", due: due,
                                dueHasTime: components?.hour != nil, listName: reminder.calendar?.title ?? "",
                                isCompleted: reminder.isCompleted)
    }
}
#endif
