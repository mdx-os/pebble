import Foundation
@testable import PebbleBackground
import PebbleCore
import SourceScan
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Thursday 15 October 2026 at `hour`:`minute`, plus `days`.
private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
    let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour, minute: minute))!
    return calendar.date(byAdding: .day, value: days, to: base)!
}

extension Trait where Self == ConditionTrait {
    /// Root reads a file at mode 0o000 anyway, so the lock can't be faked.
    static var fakesALock: Self { .enabled(if: geteuid() != 0, "file permissions don't hold for root") }
}

/// A file that is there but won't open: a regular file at mode 0o000, so
/// opening it fails with `EACCES`. `asLock` makes the store take that
/// error as its protection keeping it shut, as `EPERM` is before the first
/// unlock; without it, the same file is a disk error.
private func lockedStore(saved: BackgroundState, asLock: Bool = true) throws
    -> (BackgroundStore, unlock: () throws -> Void, remove: () -> Void) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-service-\(UUID().uuidString).json")
    let store = BackgroundStore(fileURL: url, shutErrors: asLock ? [EPERM, EACCES] : [EPERM])
    try store.save(saved)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    #expect(!store.canOpen)
    #expect(store.isShut == asLock)
    return (store, {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }, {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: store.stagingURL)
    })
}

private func scratchStore() -> BackgroundStore {
    BackgroundStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("background-service-\(UUID().uuidString).json"))
}

/// Needs you with one question open, so a summary has something to say.
private func oneWaiting() -> NeedsYou {
    let asks = NeedsYou(rule: .isolated())
    _ = asks.ask(ProposedAction(kind: .send,
                                recipient: Recipient(id: "contact:sam", displayName: "Sam", handle: "sam@example.com"),
                                details: "See you at 4"), at: at(6, 50))
    return asks
}

private let morningJob = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])

/// Writes down what the service asked the system for.
@MainActor
final class RecordingScheduler: BackgroundScheduling {
    private(set) var registered = 0
    private(set) var asks: [Date] = []
    private(set) var cancels = 0

    func register() { registered += 1 }
    func ask(at wake: Date) { asks.append(wake) }
    func cancel() { cancels += 1 }
}

/// A switch kept where nothing opens before the first unlock, as
/// `UserDefaults` is: while shut it reads off, with no sign that anything
/// is wrong, and every write is lost. Once unlocked it reads what it held.
final class LockedSwitch: BackgroundSwitch, @unchecked Sendable {
    let real: InMemoryBackgroundSwitch
    private let lock = NSLock()
    private var shut = true

    init(_ real: InMemoryBackgroundSwitch) {
        self.real = real
    }

    func unlock() { lock.withLock { shut = false } }
    private var isShut: Bool { lock.withLock { shut } }

    var isOn: Bool { isShut ? false : real.isOn }
    func set(_ on: Bool) { if !isShut { real.set(on) } }
    var isKnown: Bool { true }
    var nextDue: Date? { isShut ? nil : real.nextDue }
    func setNextDue(_ due: Date?) { if !isShut { real.setNextDue(due) } }
    var heldBeforeLoad: BackgroundHeldRun? { isShut ? nil : real.heldBeforeLoad }
    func setHeldBeforeLoad(_ held: BackgroundHeldRun?) { if !isShut { real.setHeldBeforeLoad(held) } }
    var forgetPending: Bool { isShut ? false : real.forgetPending }
    func setForgetPending(_ pending: Bool) { if !isShut { real.setForgetPending(pending) } }
}

@MainActor
struct BackgroundServiceTests {
    /// Before the first unlock, a switch that reads off may only be unread.
    /// The service never cancels the ask on its word, the run reports no
    /// success, and once the device is unlocked the card says it waited,
    /// though the switch lost the note.
    @Test(.fakesALock) func aSwitchThatReadsOffBeforeTheFirstUnlockNeverCancels() throws {
        let (store, unlock, remove) = try lockedStore(saved: morningJob)
        defer { remove() }
        let toggle = LockedSwitch(InMemoryBackgroundSwitch(on: true, nextDue: at(7)))
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        #expect(!toggle.isOn, "reads off")
        #expect(runner.switchReading == .unknown)
        let scheduler = RecordingScheduler()
        let service = BackgroundService(runner: runner, scheduler: scheduler, clock: { at(7, 1) })

        service.start()
        #expect(scheduler.registered == 1)
        #expect(scheduler.cancels == 0, "the ask from before is never cancelled")
        #expect(scheduler.asks == [at(7, 1) + BackgroundPlan.retryAfterHold])

        let conditions = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(conditions.fileShut)
        let success = service.run(now: at(7, 1), conditions: conditions, time: BackgroundTime())
        #expect(!success, "nothing was done")
        #expect(scheduler.cancels == 0)
        #expect(!scheduler.asks.isEmpty)
        #expect(toggle.real.heldBeforeLoad == nil, "the switch lost the note")

        try unlock()
        toggle.unlock()
        #expect(runner.switchReading == .on)
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.locked)))
    }

    /// Off for certain, the ask is cancelled and a wake reports no success:
    /// the system's guess at when to wake the app isn't trained on runs
    /// that did nothing.
    @Test func aRunWhileOffIsNoSuccess() {
        let store = scratchStore()
        defer { try? store.forget() }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        #expect(runner.switchReading == .off)
        let scheduler = RecordingScheduler()
        let service = BackgroundService(runner: runner, scheduler: scheduler, clock: { at(7, 1) })
        service.start()
        #expect(scheduler.cancels == 1)
        #expect(scheduler.asks.isEmpty)
        let conditions = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!service.run(now: at(7, 1), conditions: conditions, time: BackgroundTime()))
        #expect(scheduler.asks.isEmpty)
    }

    /// A file that won't open for another reason, such as a disk error, is
    /// no lock: no reason is claimed, and the run reports no success.
    @Test(.fakesALock) func aDiskErrorIsNoSuccess() throws {
        let (store, unlock, remove) = try lockedStore(saved: morningJob, asLock: false)
        defer { remove() }
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        let service = BackgroundService(runner: runner, scheduler: RecordingScheduler(), clock: { at(7, 1) })
        let conditions = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!conditions.fileShut, "not the lock")
        #expect(!service.run(now: at(7, 1), conditions: conditions, time: BackgroundTime()))
        #expect(toggle.heldBeforeLoad == nil, "no reason claimed")

        try unlock()
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil)
    }

    /// With the screen locked after the first unlock, the file opens, so
    /// the run makes the summary and reports success.
    @Test func aRunWithTheScreenLockedAfterTheFirstUnlockMakesTheSummary() throws {
        let store = scratchStore()
        defer { try? store.forget() }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        let scheduler = RecordingScheduler()
        let service = BackgroundService(runner: runner, scheduler: scheduler, clock: { at(7, 1) })
        let conditions = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!conditions.fileShut)
        #expect(service.run(now: at(7, 1), conditions: conditions, time: BackgroundTime()))
        #expect(runner.results.count == 1)
        #expect(scheduler.asks.last == at(7, days: 1), "asks for tomorrow before it can be suspended")

        // Out of time, it says so to the system.
        runner.turnOff()
        runner.turnOn(now: at(6, days: 1))
        let time = BackgroundTime()
        time.timeIsUp()
        #expect(!service.run(now: at(7, 1, days: 1), conditions: conditions, time: time))
    }

    /// The service finds the lock by trying the file, through the one
    /// helper the tests drive, and never from the screen or protected data.
    @Test func theServiceNeverReadsTheScreenForTheLock() throws {
        let source = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("Packages/PebbleKit/Sources/PebbleBackground/BackgroundService.swift"),
            encoding: .utf8)
        for screen in ["isProtectedDataAvailable", "protectedDataWillBecomeUnavailable", "applicationState"] {
            #expect(!source.contains(screen), "\(screen) in BackgroundService")
        }
        #expect(source.contains(".background(store:"))
    }
}
