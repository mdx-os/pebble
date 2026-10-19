#if canImport(EventKit)
import EventKit
#endif
import Foundation
@testable import PebbleConnectors
import Testing

/// Reading never asks the person, and a calendar that can't be read says
/// why instead of looking empty.
struct CalendarConnectorTests {
    static let window = DateInterval(start: Date(timeIntervalSinceReferenceDate: 800_000_000), duration: 86_400)
    static let meeting = CalendarEvent(id: "a", title: "Dentist", start: window.start + 3_600,
                                       end: window.start + 7_200, calendarName: "Home", location: "Main Street")
    static let call = CalendarReminder(id: "r", title: "Call the plumber", due: window.start + 600)

    static func connector(_ access: CalendarAccess, answer: CalendarAccess = .fullAccess,
                          reminders: [CalendarReminder]? = [call]) -> (CalendarConnector, FakeCalendarStore) {
        let store = FakeCalendarStore(events: [meeting], reminders: reminders, access: access, answer: answer)
        return (CalendarConnector(store: store), store)
    }

    @Test func withFullAccessItReadsEventsAndReminders() async {
        let (connector, _) = Self.connector(.fullAccess)
        #expect(await connector.events(in: Self.window) == .found([Self.meeting]))
        #expect(await connector.reminders(dueBy: Self.window.end) == .found([Self.call]))
    }

    /// A read with nothing decided yet asks nobody: it answers with the
    /// reason, and the person is asked only by `requestAccess`.
    @Test func readingNeverAsksThePerson() async {
        let (connector, store) = Self.connector(.notDetermined)
        let events = await connector.events(in: Self.window)
        let reminders = await connector.reminders(dueBy: Self.window.end)
        #expect(events == .blocked(CalendarBlock(kind: .events, why: .notAskedYet)))
        #expect(reminders == .blocked(CalendarBlock(kind: .reminders, why: .notAskedYet)))
        #expect(store.timesAsked(.events) == 0)
        #expect(store.timesAsked(.reminders) == 0)
        #expect(connector.access(.events) == .notDetermined, "reading the state changed nothing")
    }

    @Test func askingIsItsOwnCallAndThenReadingWorks() async {
        let (connector, store) = Self.connector(.notDetermined)
        #expect(await connector.requestAccess(.events) == .fullAccess)
        #expect(store.timesAsked(.events) == 1)
        #expect(store.timesAsked(.reminders) == 0, "asking about one kind never asks about the other")
        #expect(await connector.events(in: Self.window) == .found([Self.meeting]))
        #expect(await connector.reminders(dueBy: Self.window.end).block?.why == .notAskedYet)
    }

    /// Once the person has chosen, asking again asks nobody.
    @Test func aChoiceMadeIsNeverAskedAgain() async {
        for access in [CalendarAccess.denied, .restricted, .fullAccess, .writeOnly] {
            let (connector, store) = Self.connector(access)
            #expect(await connector.requestAccess(.events) == access)
            #expect(store.timesAsked(.events) == 0, "\(access)")
        }
    }

    @Test func sayingNoWhenAskedIsKept() async {
        let (connector, _) = Self.connector(.notDetermined, answer: .denied)
        #expect(await connector.requestAccess(.reminders) == .denied)
        #expect(await connector.reminders(dueBy: Self.window.end).block?.why == .denied)
    }

    /// A no, a setting that closes it, or room only to add, each gives its
    /// reason in words. None is an empty answer that would read as
    /// "nothing on your calendar".
    @Test(arguments: [
        (CalendarAccess.denied, CalendarBlock.Why.denied),
        (.restricted, .restricted),
        (.writeOnly, .writeOnly),
        (.notDetermined, .notAskedYet),
    ])
    func aClosedCalendarSaysWhyAndIsNeverEmpty(access: CalendarAccess, why: CalendarBlock.Why) async {
        let (connector, _) = Self.connector(access)
        let events = await connector.events(in: Self.window)
        let reminders = await connector.reminders(dueBy: Self.window.end)
        #expect(events.value == nil, "never an empty list")
        #expect(reminders.value == nil, "never an empty list")
        #expect(events.block == CalendarBlock(kind: .events, why: why))
        #expect(reminders.block == CalendarBlock(kind: .reminders, why: why))
        #expect(events.block?.words.isEmpty == false)
        #expect(events.block?.words != reminders.block?.words)
    }

    @Test func remindersTheStoreCouldNotGiveSaySo() async {
        let (connector, _) = Self.connector(.fullAccess, reminders: nil)
        #expect(await connector.reminders(dueBy: Self.window.end)
                    == .blocked(CalendarBlock(kind: .reminders, why: .couldNotRead)))
    }

    @Test func onlyRemindersNotDoneAndDueByTheEndComeBack() async {
        let late = CalendarReminder(id: "late", title: "Late", due: Self.window.start - 86_400)
        let done = CalendarReminder(id: "done", title: "Done", due: Self.window.start, isCompleted: true)
        let later = CalendarReminder(id: "later", title: "Later", due: Self.window.end + 1)
        let undated = CalendarReminder(id: "undated", title: "Someday", due: nil)
        let (connector, _) = Self.connector(.fullAccess, reminders: [Self.call, later, done, undated, late])
        #expect(await connector.reminders(dueBy: Self.window.end) == .found([late, Self.call]))
    }

    @Test func eventsComeBackInOrderAndOnlyInsideTheWindow() async {
        let start = Self.window.start
        let early = CalendarEvent(id: "early", title: "Early", start: start + 60, end: start + 120)
        let before = CalendarEvent(id: "before", title: "Before", start: start - 3_600, end: start)
        let after = CalendarEvent(id: "after", title: "After", start: Self.window.end, end: Self.window.end + 60)
        let store = FakeCalendarStore(events: [Self.meeting, after, early, before])
        #expect(await CalendarConnector(store: store).events(in: Self.window) == .found([early, Self.meeting]))
    }

    #if canImport(EventKit)
    @Test func theSystemsStatusesReadAsTheConnectorsAndAnUnknownOneIsAClosedOne() {
        #expect(EventKitCalendarStore.access(.notDetermined) == .notDetermined)
        #expect(EventKitCalendarStore.access(.denied) == .denied)
        #expect(EventKitCalendarStore.access(.restricted) == .restricted)
        #expect(EventKitCalendarStore.access(.fullAccess) == .fullAccess)
        #expect(EventKitCalendarStore.access(.writeOnly) == .writeOnly)
        #expect(EventKitCalendarStore.entity(.events) == .event)
        #expect(EventKitCalendarStore.entity(.reminders) == .reminder)
    }
    #endif
}
