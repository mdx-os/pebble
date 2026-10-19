import Foundation

/// A calendar store in memory, for tests and examples. It behaves as the
/// system's does: it hands back nothing it isn't allowed to, and asking
/// changes what it allows only the first time.
public final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: [CalendarKind: CalendarAccess]
    private var answers: [CalendarKind: CalendarAccess]
    private var asked: [CalendarKind: Int] = [:]
    private var pauses: [CalendarKind: Pause] = [:]
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

    /// Holds the next read of `kind` until the pause is resumed, so a test
    /// can change what is allowed while a read is under way. The read looks
    /// at what is allowed only once it is resumed, as the system does.
    public func pause(_ kind: CalendarKind) -> Pause {
        let pause = Pause()
        lock.withLock { pauses[kind] = pause }
        return pause
    }

    public func events(in window: DateInterval) async -> [CalendarEvent] {
        await takePause(.events)?.hold()
        guard access(.events) == .fullAccess else { return [] }
        return events
    }

    public func reminders(dueBy end: Date) async -> [CalendarReminder]? {
        await takePause(.reminders)?.hold()
        guard access(.reminders) == .fullAccess else { return [] }
        return reminders
    }

    private func takePause(_ kind: CalendarKind) -> Pause? {
        lock.withLock { pauses.removeValue(forKey: kind) }
    }

    /// One held read. `reached` returns once the read is waiting, and
    /// `resume` lets it go on.
    public final class Pause: @unchecked Sendable {
        private let lock = NSLock()
        private var isReached = false
        private var isResumed = false
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private var held: CheckedContinuation<Void, Never>?

        /// Returns once the read has started and is held.
        public func reached() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if isReached { continuation.resume() } else { watchers.append(continuation) }
                }
            }
        }

        public func resume() {
            lock.withLock {
                isResumed = true
                held?.resume()
                held = nil
            }
        }

        func hold() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    isReached = true
                    watchers.forEach { $0.resume() }
                    watchers = []
                    if isResumed { continuation.resume() } else { held = continuation }
                }
            }
        }
    }
}
