import Foundation
@testable import PebbleBackground
import PebbleCore
import SourceScan
import TestScratch
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

/// A file that is there but won't open. Opening it fails with
/// `BackgroundStore.shutError`, as before the first unlock, through the
/// store's faults, so no file modes are needed and root runs it the same.
/// With `asLock` false it fails with `EIO`, a disk error.
private func lockedStore(saved: BackgroundState, asLock: Bool = true) throws
    -> (BackgroundStore, unlock: () throws -> Void) {
    let faults = BackgroundStoreFaults()
    let store = BackgroundStore(fileURL: Scratch.url("background-service"), faults: faults)
    try store.save(saved)
    faults.openError = asLock ? BackgroundStore.shutError : EIO
    #expect(!store.canOpen)
    #expect(store.isShut == asLock)
    return (store, { faults.openError = nil })
}

private func scratchStore() -> BackgroundStore {
    BackgroundStore(fileURL: Scratch.url("background-service"))
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
///
/// `isKnown` stays true while shut, on purpose: `UserDefaults` gives no
/// sign either. What makes the runner read it as unknown is that it reads
/// as never set (`hasBeenSet` false) while the store's file is shut.
/// Don't make `isKnown` false to "fix" this, or the test no longer shows
/// the case it is for.
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
    var hasBeenSet: Bool { isShut ? false : real.hasBeenSet }
    var nextDue: Date? { isShut ? nil : real.nextDue }
    func setNextDue(_ due: Date?) { if !isShut { real.setNextDue(due) } }
    var heldBeforeLoad: BackgroundHeldRun? { isShut ? nil : real.heldBeforeLoad }
    func setHeldBeforeLoad(_ held: BackgroundHeldRun?) { if !isShut { real.setHeldBeforeLoad(held) } }
    var forgetPending: Bool { isShut ? false : real.forgetPending }
    func setForgetPending(_ pending: Bool) { if !isShut { real.setForgetPending(pending) } }
}

@MainActor
@Suite(.scratchFiles)
struct BackgroundServiceTests {
    /// Before the first unlock, a switch that reads off may only be unread.
    /// The service never cancels the ask on its word, the run reports no
    /// success, and once the device is unlocked the card says it waited,
    /// though the switch lost the note.
    @Test func aSwitchThatReadsOffBeforeTheFirstUnlockNeverCancels() throws {
        let (store, unlock) = try lockedStore(saved: morningJob)
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
    @Test func aDiskErrorIsNoSuccess() throws {
        let (store, unlock) = try lockedStore(saved: morningJob, asLock: false)
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

    /// A run whose file opens makes the summary and reports success. No
    /// screen is locked here: the service never reads the screen, which
    /// `theServiceNeverReadsTheScreenForTheLock` pins, so a phone locked
    /// again after its first unlock, whose file opens, is this case.
    @Test func aRunWhoseFileOpensMakesTheSummaryAndSucceeds() throws {
        let store = scratchStore()
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
    /// helper the tests drive, and neither it nor the runner reads the
    /// screen or protected data.
    @Test func theServiceNeverReadsTheScreenForTheLock() throws {
        let sources = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Sources")
        let service = try String(contentsOf: sources.appendingPathComponent("PebbleBackground/BackgroundService.swift"),
                                 encoding: .utf8)
        let runner = try String(contentsOf: sources.appendingPathComponent("PebbleCore/Background.swift"),
                                encoding: .utf8)
        for (name, text) in [("BackgroundService", service), ("Background", runner)] {
            let code = String(SwiftSource(text).code)
            for screen in ["isProtectedDataAvailable", "protectedDataWillBecomeUnavailable", "applicationState"] {
                #expect(!code.contains(screen), "\(screen) in \(name)")
            }
        }
        #expect(service.contains(".background(store:"))
    }

    /// The UI test's seed leaves no scratch folder behind: any launch
    /// without the seed removes the one an earlier seeded launch made.
    @Test func theSeedsScratchFolderGoesOnTheNextLaunch() throws {
        let suite = "background-seed-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = Scratch.url("seed").deletingPathExtension()
        defaults.set("on", forKey: BackgroundSeed.launchKey)
        let seeded = try #require(BackgroundSeed.launched(defaults: defaults, folder: folder))
        #expect(seeded.store.hasStoredFile)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        defaults.removeObject(forKey: BackgroundSeed.launchKey)
        #expect(BackgroundSeed.launched(defaults: defaults, folder: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
