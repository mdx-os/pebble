import Foundation
@testable import PebbleCore
import PromiseWords
import SourceScan
import TestScratch
import Testing

/// A fixed calendar and clock, so every decision is the same on any machine.
enum BackgroundClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Thursday 15 October 2026 at `hour`:`minute`, plus `days`.
    static func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }
}

/// Tasks held still, for the summary to count.
final class FixedTasks: TaskEngine, @unchecked Sendable {
    let rule: AskFirst
    var tasks: [AgentTask]
    var isSample: Bool { false }

    init(_ tasks: [AgentTask], rule: AskFirst = .isolated()) {
        self.tasks = tasks
        self.rule = rule
    }

    func start(_ request: TaskRequest) -> String { "" }
    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation { TaskObservation {} }
    func redirect(_ id: String, with instructions: String) -> Bool { false }
    func stop(_ id: String) -> Bool { false }
    func dismiss(_ id: String) -> Bool { false }
    func clear() -> ClearedTasks { .none }
    func retry(_ id: String) -> Bool { false }
    func resume(_ id: String, with approval: Approval) -> TaskApproval { .refused }
    func questionClosed(_ request: ConfirmationRequest) {}
    func refresh() {}
}

/// Counts calls, from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private let calendar = BackgroundClock.calendar
private func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date { BackgroundClock.at(hour, minute, days: days) }

private let background = BackgroundConditions(moment: .background)

private func scratchStore() -> BackgroundStore {
    BackgroundStore(fileURL: Scratch.url("background"))
}

private func scratchSwitch(defaults: UserDefaults? = nil) -> FileBackgroundSwitch {
    FileBackgroundSwitch(fileURL: Scratch.url("background-switch"), defaults: defaults)
}

/// A file that is there but can't be opened, as before the first unlock.
/// `saved` is what the file holds, or a few bytes of its own. Opening it
/// fails with `BackgroundStore.shutError`, through the store's faults, so
/// no file modes are needed and the test runs the same as root. With
/// `asLock` false it fails with `EIO`, a disk error. The bytes stay on
/// disk, and a save still replaces them, so a runner that wrote while it
/// shouldn't would change them.
private func lockedStore(saved: BackgroundState? = nil, asLock: Bool = true) throws
    -> (BackgroundStore, unlock: () throws -> Void) {
    let faults = BackgroundStoreFaults()
    let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
    if let saved {
        try store.save(saved)
    } else {
        try Data("locked".utf8).write(to: store.fileURL)
    }
    faults.openError = asLock ? BackgroundStore.shutError : EIO
    #expect(!store.canOpen)
    #expect(store.isShut == asLock)
    return (store, { faults.openError = nil })
}

/// The bytes of a locked store's file.
private func lockedBytes(_ store: BackgroundStore) throws -> Data {
    try Data(contentsOf: store.fileURL)
}

/// The protection class every save asked for, and what it wrote, through
/// the stores' real write path, which it then takes.
final class ProtectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [FileProtectionType] = []
    private var written: [Data] = []

    var classes: [FileProtectionType] { lock.withLock { list } }
    var payloads: [Data] { lock.withLock { written } }

    var writer: ProtectedWriter {
        ProtectedWriter { [self] data, url, protection in
            lock.withLock {
                list.append(protection)
                written.append(data)
            }
            try ProtectedWriter.disk.write(data, url, protection)
        }
    }
}

/// The real switch, writing down in order when it was turned on or off and
/// when a Forget everything's wait began or ended.
private final class OrderedSwitch: BackgroundSwitch, @unchecked Sendable {
    let real: FileBackgroundSwitch
    private let lock = NSLock()
    private var list: [String] = []

    init(_ real: FileBackgroundSwitch) {
        self.real = real
    }

    var steps: [String] { lock.withLock { list } }
    func clear() { lock.withLock { list = [] } }
    private func log(_ step: String) { lock.withLock { list.append(step) } }

    var isOn: Bool { real.isOn }
    func set(_ on: Bool) { log("set(\(on))"); real.set(on) }
    var isKnown: Bool { real.isKnown }
    var hasBeenSet: Bool { real.hasBeenSet }
    var nextDue: Date? { real.nextDue }
    func setNextDue(_ due: Date?) { real.setNextDue(due) }
    var heldBeforeLoad: BackgroundHeldRun? { real.heldBeforeLoad }
    func setHeldBeforeLoad(_ held: BackgroundHeldRun?) { real.setHeldBeforeLoad(held) }
    var forgetPending: Bool { real.forgetPending }
    func setForgetPending(_ pending: Bool) { log("forgetPending(\(pending))"); real.setForgetPending(pending) }
}

/// Needs you with one question open, so a summary has something to say:
/// a quiet morning leaves no card.
private func oneWaiting() -> NeedsYou {
    let asks = NeedsYou(rule: .isolated())
    _ = asks.ask(note, at: at(6, 50))
    return asks
}

/// Watching since long ago, as if the app had been running all along, so
/// the counts are known unless a test says otherwise. One question waits,
/// unless a test passes its own Needs you.
private func runner(store: BackgroundStore = scratchStore(), on: Bool = true, needsYou: NeedsYou? = oneWaiting(),
                    tasks: (any TaskEngine)? = nil, watchingSince: Date = .distantPast,
                    now: Date = at(6)) -> BackgroundRunner {
    let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: needsYou,
                                  tasks: tasks, watchingSince: watchingSince, calendar: calendar)
    if on { runner.turnOn(now: now) }
    return runner
}

private let note = ProposedAction(
    kind: .send,
    recipient: Recipient(id: "contact:sam", displayName: "Sam", handle: "sam@example.com"),
    details: "See you at 4"
)

// MARK: Scheduling, as pure functions

@Suite(.scratchFiles)
struct BackgroundPlanTests {
    @Test func theMorningIsTheNextSevenOClock() {
        #expect(BackgroundPlan.nextMorning(after: at(6, 30), calendar: calendar) == at(7))
        #expect(BackgroundPlan.nextMorning(after: at(7), calendar: calendar) == at(7, days: 1))
        #expect(BackgroundPlan.nextMorning(after: at(21), calendar: calendar) == at(7, days: 1))
    }

    @Test func aJobRunsOnlyOnceItIsDue() {
        let job = BackgroundJob(kind: .morningSummary, due: at(7))
        #expect(BackgroundPlan.decide(job, now: at(6, 59), conditions: background, calendar: calendar) == .notYet(at(7)))
        #expect(BackgroundPlan.decide(job, now: at(7), conditions: background, calendar: calendar) == .run)
        #expect(BackgroundPlan.decide(job, now: at(23, 59), conditions: .foreground, calendar: calendar) == .run)
    }

    @Test func lockedLowPowerAndShortTimeHoldItBack() {
        let job = BackgroundJob(kind: .morningSummary, due: at(7))
        let now = at(7, 5)
        func decide(_ conditions: BackgroundConditions) -> BackgroundDecision {
            BackgroundPlan.decide(job, now: now, conditions: conditions, calendar: calendar)
        }
        #expect(decide(BackgroundConditions(moment: .background, fileShut: true)) == .hold(.locked))
        #expect(decide(BackgroundConditions(moment: .background, lowPower: true)) == .hold(.lowPower))
        #expect(decide(BackgroundConditions(moment: .background, deadline: now + 1)) == .hold(.outOfTime))
        #expect(decide(BackgroundConditions(moment: .background, deadline: now + 20)) == .run)
        // A shut file comes first: nothing can be written then. That is
        // before the first unlock only; see
        // `aMomentWhoseFileOpensIsNotShutAndMakesTheSummary`.
        #expect(decide(BackgroundConditions(moment: .background, lowPower: true, fileShut: true)) == .hold(.locked))
        // With the person here, Low Power Mode doesn't hold it back.
        #expect(decide(BackgroundConditions(moment: .foreground, lowPower: true)) == .run)
    }

    @Test func aJobWhoseDayIsOverIsMissed() {
        let job = BackgroundJob(kind: .morningSummary, due: at(7))
        #expect(BackgroundPlan.decide(job, now: at(0, days: 1), conditions: .foreground, calendar: calendar) == .missed)
        let locked = BackgroundConditions(moment: .background, fileShut: true)
        #expect(BackgroundPlan.decide(job, now: at(9, days: 3), conditions: locked, calendar: calendar) == .missed)
    }

    @Test func theNextWakeIsTheSoonestJobOrALittleLaterForOneHeldBack() {
        #expect(BackgroundPlan.nextWake(for: [], now: at(6)) == nil)
        let later = BackgroundJob(kind: .morningSummary, due: at(7, days: 1))
        let due = BackgroundJob(kind: .morningSummary, due: at(7))
        #expect(BackgroundPlan.nextWake(for: [later], now: at(6)) == at(7, days: 1))
        #expect(BackgroundPlan.nextWake(for: [later, due], now: at(8)) == at(8) + BackgroundPlan.retryAfterHold)
    }
}

// MARK: The runner

@Suite(.scratchFiles)
struct BackgroundRunnerTests {
    @Test func backgroundWorkIsOffUntilThePersonTurnsItOn() throws {
        let toggle = scratchSwitch()
        /// The same file, read fresh, as the next launch reads it.
        func reread() -> FileBackgroundSwitch { FileBackgroundSwitch(fileURL: toggle.fileURL) }
        #expect(!toggle.isOn)
        let runner = BackgroundRunner(store: scratchStore(), toggle: toggle, calendar: calendar)
        #expect(runner.switchReading == .off)
        #expect(runner.queue.isEmpty)
        #expect(runner.nextWake(now: at(6)) == nil)
        #expect(runner.runDue(now: at(9), conditions: .foreground).isEmpty)

        runner.turnOn(now: at(6))
        #expect(reread().isOn)
        #expect(runner.queue.map(\.kind) == [.morningSummary])
        #expect(runner.nextWake(now: at(6)) == at(7))
        // The due time sits beside the switch, readable before the first unlock.
        #expect(reread().nextDue == at(7))

        runner.turnOff()
        #expect(!toggle.isOn)
        #expect(!reread().isOn)
        #expect(reread().nextDue == nil)
        #expect(runner.queue.isEmpty)
        #expect(runner.nextWake(now: at(6)) == nil)
    }

    /// The switch's file has no protection, so a run before the first
    /// unlock can read it, and holds only a bool, dates and a reason.
    @Test func theSwitchFileHasNoProtectionAndHoldsNothingOfThePersons() throws {
        let writes = ProtectionLog()
        let toggle = FileBackgroundSwitch(fileURL: Scratch.url("background-switch"), writer: writes.writer)
        toggle.set(true)
        toggle.setNextDue(at(7))
        toggle.setHeldBeforeLoad(BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        toggle.setForgetPending(true)
        #expect(!writes.classes.isEmpty)
        #expect(writes.classes.allSatisfy { $0 == .none })
        #expect(FileBackgroundSwitch.fileProtection == .none)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: toggle.fileURL)) as? [String: Any] ?? [:]
        #expect(Set(saved.keys) == ["on", "nextDue", "held", "forgetPending"])
        let held = saved["held"] as? [String: Any] ?? [:]
        #expect(Set(held.keys) == ["hold", "at", "count"])
    }

    /// An earlier version kept the switch in `UserDefaults`. It moves to
    /// the file once, and the old keys go.
    @Test func theSwitchMovesFromUserDefaultsOnce() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
        defaults.set(BackgroundHold.locked.rawValue, forKey: FileBackgroundSwitch.LegacyKeys.held)
        defaults.set(at(7, 1), forKey: FileBackgroundSwitch.LegacyKeys.heldAt)

        let toggle = scratchSwitch(defaults: defaults)
        #expect(toggle.isOn)
        #expect(toggle.nextDue == at(7))
        #expect(toggle.heldBeforeLoad == BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        for key in [FileBackgroundSwitch.LegacyKeys.on, FileBackgroundSwitch.LegacyKeys.nextDue,
                    FileBackgroundSwitch.LegacyKeys.held, FileBackgroundSwitch.LegacyKeys.heldAt] {
            #expect(defaults.object(forKey: key) == nil, "\(key) moved")
        }
        // The next launch reads it from the file alone.
        let next = FileBackgroundSwitch(fileURL: toggle.fileURL)
        #expect(next.isOn)
        #expect(next.nextDue == at(7))
    }

    /// A Forget everything that begins on a switch never kept here, while
    /// the old keys still say on: they go before anything is written, so no
    /// write along the way says on, and a launch after a crash between two
    /// writes never finds on that the person asked to forget.
    @Test func aForgetNeverMovesTheOldKeysOver() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
        let writes = ProtectionLog()
        let toggle = FileBackgroundSwitch(fileURL: Scratch.url("background-switch"), defaults: defaults,
                                          writer: writes.writer)
        toggle.setForgetPending(true)
        // The marker is empty; every other write is the switch's file.
        let saves = writes.payloads.filter { !$0.isEmpty }
        #expect(!saves.isEmpty)
        for save in saves {
            let fields = try JSONSerialization.jsonObject(with: save) as? [String: Any] ?? [:]
            #expect(fields["on"] as? Bool == false, "\(fields)")
            #expect(fields["forgetPending"] as? Bool == true, "the wait goes in the same write: \(fields)")
        }
        #expect(defaults.object(forKey: FileBackgroundSwitch.LegacyKeys.on) == nil)
        #expect(defaults.object(forKey: FileBackgroundSwitch.LegacyKeys.nextDue) == nil)
        #expect(!FileBackgroundSwitch(fileURL: toggle.fileURL, defaults: defaults).isOn)
    }

    /// Before the first unlock `UserDefaults` reads as empty. A launch then
    /// that writes beside the switch, as a held run does, never writes it
    /// over as off: once `UserDefaults` can be read, it still moves.
    @Test func aLaunchThatSeesNothingInUserDefaultsNeverWritesTheSwitchOff() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggle = scratchSwitch(defaults: defaults)
        #expect(!toggle.isOn, "nothing readable yet")
        toggle.setHeldBeforeLoad(BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        #expect(FileManager.default.fileExists(atPath: toggle.fileURL.path))

        // Unlocked: what the earlier version kept can be read now.
        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        #expect(toggle.isOn)
        #expect(FileBackgroundSwitch(fileURL: toggle.fileURL).isOn, "and kept in the file")
        #expect(toggle.heldBeforeLoad == BackgroundHeldRun(hold: .locked, at: at(7, 1)), "the note stayed")
    }

    /// An off the person taps before the first unlock, while `UserDefaults`
    /// reads as empty, stays off once it can be read, even with the earlier
    /// version's on still there: the off is kept in the file, and nothing
    /// moves over it, in this launch or the next.
    @Test func anOffBeforeUserDefaultsCanBeReadStaysOff() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggle = scratchSwitch(defaults: defaults)
        let runner = BackgroundRunner(store: scratchStore(), toggle: toggle, calendar: calendar)
        runner.turnOff()

        // Unlocked: what the earlier version kept can be read now.
        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
        #expect(!toggle.isOn)
        #expect(runner.switchReading == .off)
        #expect(runner.nextWake(now: at(6)) == nil)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        let next = FileBackgroundSwitch(fileURL: toggle.fileURL, defaults: defaults)
        #expect(!next.isOn, "the next launch reads the off too")
        #expect(next.nextDue == nil)
    }

    /// Turned on before `UserDefaults` can be read, the next morning is the
    /// time kept. An on, with an older time, that the earlier version kept
    /// there never changes it once it can be read.
    @Test func turningOnBeforeUserDefaultsCanBeReadKeepsItsTime() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggle = scratchSwitch(defaults: defaults)
        let runner = BackgroundRunner(store: scratchStore(), toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(9))
        #expect(toggle.nextDue == at(7, days: 1))

        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
        defaults.set(BackgroundHold.lowPower.rawValue, forKey: FileBackgroundSwitch.LegacyKeys.held)
        defaults.set(at(7, 1), forKey: FileBackgroundSwitch.LegacyKeys.heldAt)
        #expect(toggle.nextDue == at(7, days: 1))
        #expect(toggle.heldBeforeLoad == nil)
        let next = FileBackgroundSwitch(fileURL: toggle.fileURL, defaults: defaults)
        #expect(next.nextDue == at(7, days: 1))
        #expect(next.heldBeforeLoad == nil)
        #expect(runner.nextWake(now: at(9)) == at(7, days: 1))
    }

    /// The marker is left only where old keys were seen, where it has
    /// something to keep from moving. Someone who never had the earlier
    /// version gets none, and their Forget everything leaves nothing at all.
    @Test func theMarkerIsLeftOnlyWhereOldKeysWereSeen() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = scratchSwitch(defaults: defaults)
        plain.set(true)
        plain.set(false)
        #expect(!FileManager.default.fileExists(atPath: plain.markerURL.path), "nothing to keep from moving")
        plain.setForgetPending(true)
        plain.setForgetPending(false)
        #expect(!FileManager.default.fileExists(atPath: plain.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: plain.markerURL.path), "no trace at all")

        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        let moved = FileBackgroundSwitch(fileURL: Scratch.url("background-switch-moved"), defaults: defaults)
        #expect(moved.isOn)
        #expect(try Data(contentsOf: moved.markerURL).isEmpty, "there, and empty")
    }

    /// Off while the runner's file is shut can't be told from a switch
    /// that wasn't read, so it is unknown, never off.
    @Test func offBeforeTheFirstUnlockIsUnknown() throws {
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), calendar: calendar)
        #expect(runner.switchReading == .unknown)
        #expect(runner.nextWake(now: at(2)) == at(2) + BackgroundPlan.retryAfterHold, "never cancelled")
        #expect(runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
            .isEmpty)
        #expect(!runner.didItsWork(now: at(7, 1)))
        try unlock()
        #expect(runner.switchReading == .off)
        #expect(runner.nextWake(now: at(8)) == nil)
    }

    @Test func turningOnTwiceQueuesOneJob() {
        let runner = runner()
        runner.turnOn(now: at(6, 30))
        #expect(runner.queue.count == 1)
    }

    /// Nothing waited and nothing finished: no card, so Today isn't filled
    /// with the same empty line every morning. It still counts as made, so
    /// the next one counts from here, and it comes back tomorrow.
    @Test func aQuietMorningLeavesNoCardAndComesBackTomorrow() throws {
        let tasks = FixedTasks([])
        let runner = runner(needsYou: NeedsYou(rule: .isolated()), tasks: tasks)
        #expect(runner.runDue(now: at(6, 59), conditions: background).isEmpty)
        let heard = Counter()
        let watch = runner.observe { heard.add() }
        defer { runner.stopObserving(watch) }
        #expect(runner.runDue(now: at(7, 2), conditions: background).isEmpty)
        #expect(runner.results.isEmpty)
        #expect(runner.feed.items(now: at(8)).isEmpty)
        #expect(runner.queue.first?.due == at(7, days: 1))
        #expect(heard.value == 1, "the queue moved on, so the next wake follows")
        // Nothing more until tomorrow.
        #expect(runner.runDue(now: at(12), conditions: .foreground).isEmpty)

        // Tomorrow's counts from this quiet morning, not the evening before.
        tasks.tasks = [
            AgentTask(id: "a", title: "Before", step: "Done", state: .done, startedAt: at(6), updatedAt: at(6, 30)),
            AgentTask(id: "b", title: "After", step: "Done", state: .done, startedAt: at(1, days: 1),
                      updatedAt: at(3, days: 1)),
        ]
        let next = try #require(runner.runDue(now: at(7, 2, days: 1), conditions: background).first)
        guard case .morningSummary(let summary) = next.content else { Issue.record("not a summary"); return }
        #expect(summary.since == at(7, 2))
        #expect(summary.finished == 1, "the one before the quiet morning was already past")
    }

    @Test func theSummaryCountsOnlyWhatIsReallyHere() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        #expect(asks.ask(note, at: at(6, 50)) != nil)
        let tasks = FixedTasks([
            AgentTask(id: "a", title: "Find a dentist", step: "Done", state: .done, startedAt: at(1), updatedAt: at(2)),
            AgentTask(id: "b", title: "Plan the week", step: "Done", state: .done, startedAt: at(1), updatedAt: at(3)),
            AgentTask(id: "c", title: "Lunch menu", step: "Sorry", state: .failed, startedAt: at(1), updatedAt: at(4)),
            AgentTask(id: "d", title: "Book a table", step: "Waiting", state: .waitingOnYou, startedAt: at(5)),
            AgentTask(id: "e", title: "Still going", step: "Working", state: .running, startedAt: at(5)),
            // Finished the morning before: not overnight.
            AgentTask(id: "f", title: "Old one", step: "Done", state: .done, startedAt: at(6, days: -1), updatedAt: at(8, days: -1)),
        ], rule: rule)
        let runner = runner(needsYou: asks, tasks: tasks)
        let made = try #require(runner.runDue(now: at(7), conditions: background).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.waiting == 2)
        #expect(summary.finished == 2)
        #expect(summary.couldNotFinish == 1)
        #expect(summary.since == at(19, days: -1))
        #expect(summary.late == nil)

        let item = made.item(calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(item.kind == .ready)
        #expect(item.body == "2 things were waiting for you. 2 tasks finished overnight. One task couldn't finish.")
        guard case .open(let detail) = item.action else { Issue.record("no detail to read"); return }
        #expect(detail.contains(BackgroundWords.whereWaiting))
        #expect(detail.contains("I counted from 7:00\u{202F}PM yesterday.") || detail.contains("I counted from 7:00 PM yesterday."))
        // Reading never answers: the question is still open.
        #expect(asks.items(now: at(7)).count == 1)
    }

    @Test func theNextSummaryCountsFromTheLastOne() throws {
        let tasks = FixedTasks([
            AgentTask(id: "a", title: "Before", step: "Done", state: .done, startedAt: at(1), updatedAt: at(2)),
        ])
        let runner = runner(tasks: tasks)
        runner.runDue(now: at(7), conditions: background)
        tasks.tasks.append(AgentTask(id: "b", title: "After", step: "Done", state: .done,
                                     startedAt: at(1, days: 1), updatedAt: at(3, days: 1)))
        let made = try #require(runner.runDue(now: at(7, days: 1), conditions: background).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.since == at(7))
        #expect(summary.finished == 1)
    }

    // MARK: Only what it can know

    /// The app's own wiring: the same Needs you and task engine as Today,
    /// and no engine yet. Launched in the night, it didn't see the evening,
    /// but what is waiting is open now, so it says that; it never says
    /// anything about tasks. A morning with nothing waiting leaves no card.
    @Test func theAppsRunnerStatesNoCountItCantKnow() throws {
        let asks = NeedsYou(rule: .isolated())
        let store = scratchStore()
        defer { try? store.forget() }
        let toggle = InMemoryBackgroundSwitch()
        let made = BackgroundRunner.onDevice(needsYou: asks, tasks: nil, launchedAt: at(3), store: { store },
                                             toggle: { toggle }, calendar: calendar)
        let runner = try #require(made)
        #expect(runner.needsYou === asks)
        #expect(runner.tasks == nil)
        #expect(runner.watchingSince == at(3))
        runner.turnOn(now: at(3))

        #expect(runner.runDue(now: at(7), conditions: background).isEmpty, "nothing waiting, so no card")
        #expect(runner.queue.first?.due == at(7, days: 1))

        _ = asks.ask(note, at: at(6, 50, days: 1))
        let second = try #require(runner.runDue(now: at(7, days: 1), conditions: background).first)
        guard case .morningSummary(let summary) = second.content else { Issue.record("not a summary"); return }
        #expect(summary.waiting == 1)
        #expect(summary.finished == nil && summary.couldNotFinish == nil)
        let card = second.item(calendar: calendar)
        #expect(card.body == "One thing was waiting for you.")
        #expect(!(card.action.map { "\($0)" } ?? "").contains("finished"))

        #expect(BackgroundRunner.onDevice(needsYou: asks, tasks: nil,
                                          store: { throw BackgroundStore.Unavailable() },
                                          toggle: { InMemoryBackgroundSwitch() }) == nil)
        #expect(BackgroundRunner.onDevice(needsYou: asks, tasks: nil, store: { store },
                                          toggle: { throw BackgroundStore.Unavailable() }) == nil)
    }

    /// What is waiting is open now, so a launch after the window began
    /// still says it. What finished lives in memory only, and a launch
    /// after the window began can't say nothing finished, so it leaves
    /// that line out.
    @Test func aLaunchAfterTheWindowBeganStillSaysWhatIsWaiting() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = asks.ask(note, at: at(6, 50))
        let tasks = FixedTasks([
            AgentTask(id: "a", title: "Done", step: "Done", state: .done, startedAt: at(1), updatedAt: at(4)),
            AgentTask(id: "d", title: "Book a table", step: "Waiting", state: .waitingOnYou, startedAt: at(5)),
        ], rule: rule)
        let late = runner(needsYou: asks, tasks: tasks, watchingSince: at(2))
        let made = try #require(late.runDue(now: at(7), conditions: background).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.waiting == 2)
        #expect(summary.finished == nil)
        #expect(summary.couldNotFinish == nil)
        #expect(made.item(calendar: calendar).body == "2 things were waiting for you.")

        let early = runner(needsYou: asks, tasks: tasks, watchingSince: at(18, days: -1))
        let counted = try #require(early.runDue(now: at(7), conditions: background).first)
        #expect(counted.item(calendar: calendar).body == "2 things were waiting for you. One task finished overnight.")

        // With no question and no task waiting, a late launch has nothing to say.
        let quiet = runner(needsYou: NeedsYou(rule: .isolated()), tasks: FixedTasks([]), watchingSince: at(2))
        #expect(quiet.runDue(now: at(7), conditions: background).isEmpty)
    }

    /// A task waiting on a yes whose question also sits in Needs you is
    /// one thing waiting, not two.
    @Test func aTasksQuestionIsCountedOnce() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let request = try #require(asks.ask(note, at: at(6, 50)))
        let tasks = FixedTasks([
            AgentTask(id: "d", title: "Book a table", step: "Waiting", state: .waitingOnYou, question: request,
                      startedAt: at(5)),
        ], rule: rule)
        let runner = runner(needsYou: asks, tasks: tasks)
        let made = try #require(runner.runDue(now: at(7), conditions: background).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.waiting == 1)
    }

    /// After a missed day the window is longer than a night, and the words
    /// say from when rather than "overnight".
    @Test func aLongerWindowNamesTheDayRatherThanOvernight() {
        let en = Locale(identifier: "en_US")
        func line(since: Date) -> String {
            BackgroundWords.finished(2, since: since, now: at(7, days: 3), calendar: calendar, locale: en)
        }
        #expect(line(since: at(19, days: 2)) == "2 tasks finished overnight.")
        #expect(line(since: at(7, days: 2)) == "2 tasks finished since yesterday.")
        #expect(line(since: at(7)) == "2 tasks finished since Thursday.")

        let runner = runner(tasks: FixedTasks([]))
        runner.runDue(now: at(7), conditions: background)
        let made = runner.runDue(now: at(9, days: 3), conditions: .foreground)
        let summary = made.first { if case .morningSummary = $0.content { true } else { false } }
        let body = summary?.item(calendar: calendar, locale: en).body ?? ""
        #expect(body.contains("since Thursday"))
        #expect(!body.contains("overnight"))
    }

    @Test func whatItKeepsSurvivesARestartAndHoldsNoWordsOfTheTasks() throws {
        let store = scratchStore()
        defer { try? store.forget() }
        let tasks = FixedTasks([
            AgentTask(id: "a", title: "Secret dentist search", step: "Found three", state: .done,
                      startedAt: at(1), updatedAt: at(2)),
        ])
        let first = runner(store: store, tasks: tasks)
        first.runDue(now: at(7), conditions: background)
        #expect(store.hasStoredFile)

        let toggle = InMemoryBackgroundSwitch(on: true)
        let again = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        #expect(again.results == first.results)
        #expect(again.queue == first.queue)
        #expect(again.runDue(now: at(9), conditions: .foreground).isEmpty, "the morning already ran")

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("Secret"))
        #expect(!text.contains("dentist"))
        #expect(!text.contains("Found three"))
    }

    @Test func forgetEverythingStopsTheRunnerAndClearsItsQueueAndResults() throws {
        let store = scratchStore()
        let toggle = InMemoryBackgroundSwitch()
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(), calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: background)
        #expect(!runner.results.isEmpty)
        // A save cut short leaves its staged copy, which holds the cards too.
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        // And a note that a run waited, as a run before the first unlock leaves.
        toggle.setHeldBeforeLoad(BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        let heard = Counter()
        let watch = runner.observe { heard.add() }
        defer { runner.stopObserving(watch) }

        try runner.forget()
        #expect(!toggle.isOn)
        #expect(toggle.nextDue == nil)
        #expect(toggle.heldBeforeLoad == nil)
        #expect(!toggle.forgetPending, "erased, so nothing is left to try again")
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        #expect(runner.nextWake(now: at(8)) == nil)
        #expect(!store.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(heard.value == 1)
        // Nothing left to run, the next morning or ever, until turned on again.
        #expect(runner.runDue(now: at(7, days: 1), conditions: background).isEmpty)
        #expect(!store.hasStoredFile)
        #expect(BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar).results.isEmpty)
    }

    @Test func turningOffKeepsTheCardsButRunsNothingMore() {
        let runner = runner()
        runner.runDue(now: at(7), conditions: background)
        runner.turnOff()
        #expect(runner.results.count == 1)
        #expect(runner.runDue(now: at(7, days: 1), conditions: .foreground).isEmpty)
    }

    /// Turned back on weeks later, the next summary counts from the evening
    /// before it, never across the days it was off.
    @Test func turningOffForgetsWhenTheLastSummaryWas() throws {
        let runner = runner()
        runner.runDue(now: at(7), conditions: background)
        runner.turnOff()
        runner.turnOn(now: at(9, days: 20))
        let made = try #require(runner.runDue(now: at(7, days: 21), conditions: background).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.since == at(19, days: 20))
    }

    @Test func aCardCanBeTakenAway() throws {
        let runner = runner()
        let made = try #require(runner.runDue(now: at(7), conditions: background).first)
        runner.dismiss(made.id)
        #expect(runner.results.isEmpty)
    }

    // MARK: Locked, Low Power Mode and time

    @Test func lockedItWaitsAndTheCardSaysWhy() throws {
        let runner = runner()
        let locked = BackgroundConditions(moment: .background, fileShut: true)
        #expect(runner.runDue(now: at(7, 1), conditions: locked).isEmpty)
        #expect(runner.queue.first?.held == .locked)
        let made = try #require(runner.runDue(now: at(8, 30), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.locked)))
        #expect(runner.queue.first?.held == nil)
    }

    @Test func aFileThatCantBeOpenedIsNeverWrittenOver() throws {
        let (store, unlock) = try lockedStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let before = try lockedBytes(store)
        #expect(throws: BackgroundStore.Unavailable.self) { try store.load() }

        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        runner.turnOn(now: at(7, 2))
        #expect(try lockedBytes(store) == before, "kept for later, not written over the file")
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(runner.hasUnsavedChanges)
        try unlock()
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    /// A launch in the night before the first unlock: the hold is kept
    /// beside the switch, so a new process launched later, as iOS does
    /// after ending the one that ran the task, still says the run waited.
    @Test func theWaitForTheFirstUnlockOutlivesTheProcess() throws {
        let switchURL = Scratch.url("background-switch")
        let setUp = BackgroundRunner(store: scratchStore(), toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     calendar: calendar)
        setUp.turnOn(now: at(6))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: setUp.queue))

        let night = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(night.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
            .isEmpty)
        #expect(FileBackgroundSwitch(fileURL: switchURL).heldBeforeLoad
            == BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        #expect(!night.didItsWork(now: at(7, 1)), "the system hears the run didn't do its work")

        // That process ends. A new one starts, and the device is unlocked.
        let morning = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                       needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        try unlock()
        let made = try #require(morning.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(FileBackgroundSwitch(fileURL: switchURL).heldBeforeLoad == nil, "said once")
        #expect(!morning.hasUnsavedChanges)
    }

    /// The usual case: the process that held the run ends, and the next
    /// one starts after the unlock, so its first look reads the file at
    /// once. It still says the run waited, and only once.
    @Test func aFreshProcessAfterTheUnlockSaysItWaitedOnce() throws {
        let switchURL = Scratch.url("background-switch")
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        let toggle = FileBackgroundSwitch(fileURL: switchURL)
        toggle.set(true)
        toggle.setNextDue(at(7))
        let night = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        night.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
        try unlock()

        // Built after the unlock: it reads the file as soon as it looks.
        let fresh = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        let made = try #require(fresh.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(FileBackgroundSwitch(fileURL: switchURL).heldBeforeLoad == nil)

        // Said once: the next morning, in yet another process, is on time.
        let tomorrowsQuestion = NeedsYou(rule: .isolated())
        _ = tomorrowsQuestion.ask(note, at: at(6, 50, days: 1))
        let later = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: tomorrowsQuestion, watchingSince: .distantPast, calendar: calendar)
        let next = try #require(later.runDue(now: at(7, 5, days: 1), conditions: background).first)
        guard case .morningSummary(let tomorrow) = next.content else { Issue.record("not a summary"); return }
        #expect(tomorrow.late == nil)
    }

    /// The hold goes on the job as soon as the file is read, and is written
    /// there, so a launch that only reads the queue keeps it too.
    @Test func theWaitGoesOnTheJobWhenTheFileIsRead() throws {
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let night = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        night.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
        try unlock()
        let next = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        #expect(next.queue.first?.held == .locked)
        #expect(toggle.heldBeforeLoad == nil)
        #expect(BackgroundRunner(store: store, toggle: toggle, calendar: calendar).queue.first?.held == .locked)
    }

    /// A file that won't open for another reason, such as a disk error, is
    /// not shut by its protection. The moment found from it says so, no
    /// lock is claimed, then or later, and the run didn't do its work.
    @Test func aDiskErrorIsNotALock() throws {
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]),
                                              asLock: false)
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        let moment = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!moment.fileShut)
        #expect(runner.runDue(now: at(7, 1), conditions: moment).isEmpty)
        #expect(toggle.heldBeforeLoad == nil)
        #expect(!runner.didItsWork(now: at(7, 1)), "it couldn't read its file, so it did nothing")

        try unlock()
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil, "no reason claimed")
    }

    /// "Locked" is the file that can't be opened yet, not the screen. A
    /// file that opens makes a moment that is not shut, and the summary is
    /// made. No screen is locked here: nothing in the runner or the
    /// service reads the screen, which `theServiceNeverReadsTheScreenForTheLock`
    /// pins, so a phone locked again after its first unlock is this case.
    @Test func aMomentWhoseFileOpensIsNotShutAndMakesTheSummary() throws {
        let store = scratchStore()
        let runner = runner(store: store)
        #expect(store.hasStoredFile, "the queue is in the file")
        let moment = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!moment.fileShut)
        let made = try #require(runner.runDue(now: at(7, 1), conditions: moment).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil)
        #expect(runner.didItsWork(now: at(7, 1)))
    }

    /// The moment found from a store whose file is shut by its protection.
    @Test func aShutFileMakesAShutMoment() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                       due: at(7))]))
        #expect(BackgroundConditions.background(store: store, lowPower: false, deadline: nil).fileShut)
        #expect(!BackgroundConditions.background(store: scratchStore(), lowPower: false, deadline: nil).fileShut,
                "no file yet is not shut")
    }

    /// Held back or out of time, the run didn't do its work; once it ran,
    /// it did. Off, it did nothing.
    @Test func aHeldRunDidntDoItsWorkUntilItRuns() {
        let runner = runner()
        #expect(runner.didItsWork(now: at(6, 30)), "nothing due yet, nothing left undone")
        runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, lowPower: true))
        #expect(!runner.didItsWork(now: at(7, 1)))
        runner.runDue(now: at(7, 20), conditions: background)
        #expect(runner.didItsWork(now: at(7, 20)))
        runner.turnOff()
        #expect(!runner.didItsWork(now: at(7, 20)), "off, so nothing was done")
    }

    /// A long night of holds asks for time less and less often.
    @Test func manyHoldsInOneNightBackOff() {
        #expect(BackgroundPlan.retry(afterHolds: 0) == BackgroundPlan.retryAfterHold)
        #expect(BackgroundPlan.retry(afterHolds: BackgroundPlan.holdsBeforeBackingOff) == BackgroundPlan.retryAfterHold)
        #expect(BackgroundPlan.retry(afterHolds: BackgroundPlan.holdsBeforeBackingOff + 1)
            == 2 * BackgroundPlan.retryAfterHold)
        #expect(BackgroundPlan.retry(afterHolds: 100) == BackgroundPlan.longestRetry)

        let night = runner()
        let lowPower = BackgroundConditions(moment: .background, lowPower: true)
        var now = at(7, 1)
        var waits: [TimeInterval] = []
        for _ in 0..<7 {
            night.runDue(now: now, conditions: lowPower)
            let wake = night.nextWake(now: now) ?? now
            waits.append(wake.timeIntervalSince(now))
            now = wake
        }
        #expect(waits.prefix(3).allSatisfy { $0 == BackgroundPlan.retryAfterHold })
        #expect(waits == waits.sorted(), "never sooner than the one before")
        #expect(waits.last == BackgroundPlan.longestRetry)
        // Once it runs, the count starts over.
        night.runDue(now: now, conditions: background)
        #expect(night.queue.first?.holds == 0)
        // The person opening the app is no wake, and counts for nothing.
        let fresh = runner()
        fresh.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .foreground, fileShut: true))
        #expect(fresh.queue.first?.holds == 0)
    }

    /// Holds before the file can be read count too, so a night before the
    /// first unlock backs off as well.
    @Test func holdsBeforeTheFileCanBeReadBackOff() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                       due: at(7))]))
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let runner = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        let shut = BackgroundConditions(moment: .background, fileShut: true)
        var now = at(7, 1)
        for _ in 0..<6 {
            runner.runDue(now: now, conditions: shut)
            now = runner.nextWake(now: now) ?? now
        }
        #expect(toggle.heldBeforeLoad?.count == 6)
        #expect(runner.nextWake(now: now) == now + BackgroundPlan.retry(afterHolds: 6))
        #expect(BackgroundPlan.retry(afterHolds: 6) > BackgroundPlan.retryAfterHold)
    }

    @Test func lowPowerModeHoldsItBackInTheBackground() throws {
        let runner = runner()
        let lowPower = BackgroundConditions(moment: .background, lowPower: true)
        #expect(runner.runDue(now: at(7, 1), conditions: lowPower).isEmpty)
        #expect(runner.queue.first?.held == .lowPower)
        let made = try #require(runner.runDue(now: at(7, 30), conditions: background).first)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.lowPower)))
    }

    @Test func runningOutOfTimeWaitsAndSaysSo() throws {
        let runner = runner()
        let short = BackgroundConditions(moment: .background, deadline: at(7, 1) + 1)
        #expect(runner.runDue(now: at(7, 1), conditions: short).isEmpty)
        #expect(runner.queue.first?.held == .outOfTime)

        // The system took its time back before the run.
        let time = BackgroundTime()
        time.timeIsUp()
        #expect(runner.runDue(now: at(7, 20), conditions: background, time: time).isEmpty)
        #expect(runner.queue.first?.held == .outOfTime)

        let made = try #require(runner.runDue(now: at(7, 40), conditions: background, time: BackgroundTime()).first)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.outOfTime)))
    }

    /// The system may say time is up after a run has already ended. That
    /// belongs to the run that ended, so the next one, such as the catch
    /// up when the app opens, runs and never claims it ran out of time.
    @Test func aLateTimeUpNeverReachesTheNextRun() throws {
        let runner = runner()
        let first = BackgroundTime()
        #expect(runner.runDue(now: at(6, 30), conditions: background, time: first).isEmpty)
        first.timeIsUp()
        let made = try #require(runner.runDue(now: at(7, 5), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil)
    }

    /// iOS launches the app for its morning task while the phone is still
    /// locked. The file can't be read, but its queue is still there, so the
    /// runner asks to be woken again soon rather than cancel every ask.
    @Test func aColdLaunchWhileLockedKeepsAskingForTime() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true),
                                      needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(runner.nextWake(now: at(7, 1)) == at(7, 1) + BackgroundPlan.retryAfterHold)
        #expect(runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
            .isEmpty)
        #expect(runner.nextWake(now: at(7, 1)) == at(7, 1) + BackgroundPlan.retryAfterHold)

        // Off can't be told from unread while the file is shut, so even off
        // asks; once the file opens, off is off
        // (`offBeforeTheFirstUnlockIsUnknown`).
        let off = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), calendar: calendar)
        #expect(off.nextWake(now: at(7, 1)) != nil)

        try unlock()
        #expect(off.nextWake(now: at(7, 1)) == nil)
        #expect(runner.nextWake(now: at(7, 20)) == at(7, 20) + BackgroundPlan.retryAfterHold, "due and held, so soon")
        #expect(runner.runDue(now: at(7, 20), conditions: background).count == 1)
        #expect(runner.nextWake(now: at(7, 21)) == at(7, days: 1))
    }

    /// A launch while locked in the night, as when iOS prewarms the app,
    /// asks for the due time the switch keeps, not every quarter hour until
    /// unlock. A hold before the job was due held nothing back, so the card
    /// never says it waited; one at or after due does.
    @Test func aLockedLaunchAsksForTheDueTimeAndOnlyLateHoldsAreSaid() throws {
        for (holdAt, said) in [(at(2), nil), (at(7), BackgroundHold.locked), (at(7, 5), BackgroundHold.locked)] {
            let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
            let (store, unlock) = try lockedStore(saved: saved)
            defer { try? FileManager.default.removeItem(at: store.fileURL) }
            let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
            let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                          watchingSince: .distantPast, calendar: calendar)
            #expect(runner.nextWake(now: at(2)) == at(7), "the real time, not 2:15")
            let locked = BackgroundConditions(moment: .background, fileShut: true)
            #expect(runner.runDue(now: holdAt, conditions: locked).isEmpty)
            #expect(runner.nextWake(now: at(2)) == at(7))
            // Due and still locked: a little later, as for any hold.
            #expect(runner.nextWake(now: at(7, 10)) == at(7, 10) + BackgroundPlan.retryAfterHold)
            #expect(toggle.nextDue == at(7), "untouched while the file can't be read")

            try unlock()
            let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
            guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
            #expect(summary.late == said, "held at \(holdAt)")
            #expect(toggle.nextDue == at(7, days: 1), "moves on with the queue")
        }
    }

    /// With nothing kept beside the switch, as after an update from a
    /// version that didn't keep it, a locked launch still asks again soon.
    @Test func aLockedLaunchWithNoKeptTimeStillAsks() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(runner.nextWake(now: at(2)) == at(2) + BackgroundPlan.retryAfterHold)
    }

    /// Turned on while locked, the time kept is the sooner of the one
    /// already kept and the new morning, since the file's job keeps its time.
    @Test func turningOnWhileLockedKeepsTheSoonerTime() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let before = try lockedBytes(store)
        let toggle = InMemoryBackgroundSwitch(nextDue: at(7))
        let runner = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        runner.turnOn(now: at(9))
        #expect(try lockedBytes(store) == before, "never written over while it can't be read")
        #expect(toggle.nextDue == at(7))
        runner.turnOff()
        #expect(toggle.nextDue == nil)
        runner.turnOn(now: at(9))
        #expect(toggle.nextDue == at(7, days: 1))
    }

    /// Turned off while the file can't be read, it stays off once it can:
    /// the queue saved in the file doesn't come back, and turning on later
    /// starts fresh, with no stale "couldn't make" card.
    @Test func turningOffWhileLockedSticks() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7, days: -2))])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? store.forget() }
        let toggle = InMemoryBackgroundSwitch(on: true)
        let runner = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
        #expect(toggle.heldBeforeLoad != nil)
        runner.turnOff()
        #expect(runner.hasUnsavedChanges)
        #expect(toggle.heldBeforeLoad == nil, "a run that waited goes with the queue")

        try unlock()
        #expect(runner.queue.isEmpty)
        #expect(!runner.hasUnsavedChanges)
        let again = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        #expect(again.queue.isEmpty, "written over once it could be")

        runner.turnOn(now: at(9))
        #expect(runner.queue.map(\.due) == [at(7, days: 1)])
        #expect(runner.runDue(now: at(9, 30), conditions: .foreground).isEmpty)
        #expect(runner.results.isEmpty)
    }

    /// Forget everything while the file can't be read, with changes held
    /// in memory to write once it can: none of them is written back after
    /// it unlocks, however often the runner is asked to run.
    @Test func forgetEverythingWhileLockedWritesNothingBack() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let toggle = InMemoryBackgroundSwitch()
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        #expect(runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
            .isEmpty)
        #expect(runner.hasUnsavedChanges, "held in memory for when the file opens")
        #expect(toggle.heldBeforeLoad != nil)

        try runner.forget()
        #expect(!runner.hasUnsavedChanges)
        #expect(!store.hasStoredFile, "erased even while it couldn't be read")
        #expect(toggle.heldBeforeLoad == nil)

        // Unlocked: the file is gone, so there is nothing to put back, and
        // the runner has nothing of its own to write.
        try unlock()
        for hour in [8, 9] { runner.runDue(now: at(hour), conditions: .foreground) }
        #expect(!store.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(!runner.hasUnsavedChanges)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        #expect(toggle.nextDue == nil)
        // Turned on from elsewhere, as by another window, it still has
        // nothing old to write. On with nothing queued, its next look
        // queues the next morning, so on never waits for nothing: only
        // that fresh job goes in the file.
        toggle.set(true)
        runner.runDue(now: at(10), conditions: .foreground)
        #expect(runner.queue.map(\.due) == [at(7, days: 1)])
        #expect(runner.nextWake(now: at(10)) == at(7, days: 1))
        let again = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(again.queue.map(\.due) == [at(7, days: 1)])
        #expect(again.results.isEmpty)
    }

    /// Turned on while locked, a job already in the file keeps its time.
    @Test func turningOnWhileLockedKeepsTheSavedJob() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7), held: .lowPower)])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? store.forget() }
        let before = try lockedBytes(store)
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), calendar: calendar)
        runner.turnOn(now: at(7, 30))
        #expect(try lockedBytes(store) == before, "never written over while it can't be read")
        try unlock()
        #expect(runner.queue == saved.queue)
    }

    /// A run waited for the file, then it was turned off and on again, all
    /// before the file could be read. The saved job comes back with its
    /// time, but the wait belonged to the queue that was turned off, so
    /// the summary never says it came late.
    @Test func turningOnAgainAfterAHeldRunAndOffSaysNothingLate() throws {
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
        #expect(toggle.heldBeforeLoad != nil)
        runner.turnOff()
        #expect(toggle.heldBeforeLoad == nil)
        runner.turnOn(now: at(7, 2))

        try unlock()
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil)
    }

    /// A save cut short leaves its staged copy. The next save clears it
    /// first, so it never blocks a later one: the next morning's card is in
    /// the file, and the staged copy is gone.
    @Test func aStaleStagedCopyNeverBlocksLaterSaves() throws {
        let store = scratchStore()
        let runner = runner(store: store)
        runner.runDue(now: at(7), conditions: background)
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        #expect(FileManager.default.fileExists(atPath: store.stagingURL.path))

        let made = try #require(runner.runDue(now: at(7, days: 1), conditions: background).first)
        #expect(!runner.hasUnsavedChanges)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(try store.load().results.contains { $0.id == made.id })
        let next = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(next.results.first?.id == made.id)
    }

    /// Forget everything whose file can't be erased says so beside the
    /// switch. Until the file goes, no launch shows a card from it, runs
    /// its queue or writes into it, and the next look once it can be
    /// erased erases it.
    @Test func aForgetThatFailsIsTriedAgainAndShowsNothingMeanwhile() throws {
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
        let toggle = InMemoryBackgroundSwitch()
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: background)
        #expect(!runner.results.isEmpty)
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        faults.eraseFails = true

        #expect(throws: (any Error).self) { try runner.forget() }
        #expect(toggle.forgetPending)
        #expect(store.hasStoredFile, "still there")
        #expect(runner.results.isEmpty)
        let bytes = try Data(contentsOf: store.fileURL)

        // A later launch, while it still can't be erased.
        let next = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                    watchingSince: .distantPast, calendar: calendar)
        #expect(next.results.isEmpty, "none of its cards come back")
        #expect(next.queue.isEmpty)
        #expect(next.runDue(now: at(7, days: 1), conditions: .foreground).isEmpty)
        next.turnOn(now: at(9, days: 1))
        #expect(try Data(contentsOf: store.fileURL) == bytes, "nothing written into it")
        #expect(!next.didItsWork(now: at(9, days: 1)))

        // It can be erased now, and the next look does. Any look does,
        // reading the cards included, on purpose: that read is the look
        // here, so it is what this checks.
        faults.eraseFails = false
        #expect(next.results.isEmpty)
        #expect(!toggle.forgetPending)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path), "the staged copy too")
        // Turned on again meanwhile, only the fresh queue goes in.
        next.runDue(now: at(9, 30, days: 1), conditions: .foreground)
        let again = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(again.results.isEmpty)
        #expect(again.queue.map(\.due) == [at(7, days: 2)])
    }

    /// The same across launches, as iOS ends the process and starts a new
    /// one: each launch builds its switch afresh from the file, finds the
    /// Forget everything still pending there, and shows, runs and writes
    /// nothing. The first that can erase the file erases its staged copy
    /// too, and then the switch's file reads as nothing pending.
    @Test func aForgetThatFailsIsTriedAgainByALaterLaunch() throws {
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
        let switchURL = Scratch.url("background-switch")
        func launch() -> BackgroundRunner {
            BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL), needsYou: oneWaiting(),
                             watchingSince: .distantPast, calendar: calendar)
        }
        let first = launch()
        first.turnOn(now: at(6))
        first.runDue(now: at(7), conditions: background)
        #expect(!first.results.isEmpty)
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        faults.eraseFails = true
        #expect(throws: (any Error).self) { try first.forget() }
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending, "kept in the file for the next launch")
        let bytes = try Data(contentsOf: store.fileURL)

        // A later launch, while the file still can't be erased.
        let stuck = launch()
        #expect(stuck.results.isEmpty, "none of its cards come back")
        #expect(stuck.queue.isEmpty)
        #expect(stuck.runDue(now: at(7, days: 1), conditions: .foreground).isEmpty)
        #expect(!stuck.didItsWork(now: at(7, days: 1)))
        #expect(try Data(contentsOf: store.fileURL) == bytes, "nothing written into it")
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending)

        // Another, once it can be erased.
        faults.eraseFails = false
        let later = launch()
        #expect(later.results.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path), "the staged copy too")
        let fresh = FileBackgroundSwitch(fileURL: switchURL)
        #expect(!fresh.forgetPending, "read fresh from the file")
        #expect(!fresh.isOn)
        #expect(later.switchReading == .off)
    }

    /// Forget everything with the real switch, while what an earlier
    /// version kept in `UserDefaults` still says on. Read afresh, as the
    /// next launch reads it, the switch stays off, whether the forget still
    /// waits or is done, and however often the old keys come back. Once it
    /// is done the switch's file is gone too, and only the empty marker
    /// stays, which keeps the old keys from ever moving over again. While
    /// the forget waits, the file holds off and the wait, and no time.
    @Test func forgetEverythingWithTheRealSwitchStaysOffAndLeavesNoTrace() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func keepTheOldKeys() {
            defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
            defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
            defaults.set(BackgroundHold.locked.rawValue, forKey: FileBackgroundSwitch.LegacyKeys.held)
            defaults.set(at(7, 1), forKey: FileBackgroundSwitch.LegacyKeys.heldAt)
        }
        func oldKeysLeft() -> [String] {
            [FileBackgroundSwitch.LegacyKeys.on, FileBackgroundSwitch.LegacyKeys.nextDue,
             FileBackgroundSwitch.LegacyKeys.held, FileBackgroundSwitch.LegacyKeys.heldAt]
                .filter { defaults.object(forKey: $0) != nil }
        }
        let switchURL = Scratch.url("background-switch")
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
        keepTheOldKeys()
        let runner = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL, defaults: defaults),
                                      needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(runner.isOn, "moved over from the earlier version")
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: background)
        #expect(!runner.results.isEmpty)

        // The old keys are back, as if the move had never removed them, and
        // the erase fails, so the forget waits.
        keepTheOldKeys()
        faults.eraseFails = true
        #expect(throws: (any Error).self) { try runner.forget() }
        #expect(oldKeysLeft().isEmpty)
        #expect(!FileBackgroundSwitch(fileURL: switchURL, defaults: defaults).isOn)
        let waiting = try JSONSerialization.jsonObject(with: Data(contentsOf: switchURL)) as? [String: Any] ?? [:]
        #expect(Set(waiting.keys) == ["on", "forgetPending"], "no time and no held run")
        #expect(waiting["on"] as? Bool == false)

        // The old keys come back while the forget still waits. A fresh
        // read still says off, and so does a launch that can't erase the
        // file yet: off, never unknown, and it asks for no wake.
        keepTheOldKeys()
        #expect(!FileBackgroundSwitch(fileURL: switchURL, defaults: defaults).isOn)
        let stuck = BackgroundRunner(store: store,
                                     toggle: FileBackgroundSwitch(fileURL: switchURL, defaults: defaults),
                                     calendar: calendar)
        #expect(!stuck.isOn)
        #expect(stuck.switchReading == .off)
        #expect(stuck.nextWake(now: at(8)) == nil)
        #expect(stuck.results.isEmpty)
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending, "still waits")
        expectOff(switchURL, defaults: defaults, "while the forget waits")

        // Then a later launch erases it, with the old keys there again.
        keepTheOldKeys()
        faults.eraseFails = false
        let later = BackgroundRunner(store: store,
                                     toggle: FileBackgroundSwitch(fileURL: switchURL, defaults: defaults),
                                     calendar: calendar)
        // Before it looks at its file, the forget still waits, and it reads off.
        #expect(!later.isOn)
        #expect(later.switchReading == .off)
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending, "not erased until it looks")
        #expect(store.hasStoredFile)
        // Its first look erases the file, and it still reads off.
        #expect(later.results.isEmpty)
        #expect(!store.hasStoredFile)
        #expect(!later.isOn, "and once it has erased the file")
        #expect(later.switchReading == .off)
        #expect(later.nextWake(now: at(8)) == nil)
        #expect(oldKeysLeft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: switchURL.path), "no trace left")
        #expect(!FileManager.default.fileExists(atPath: FileBackgroundSwitch(fileURL: switchURL).stagingURL.path))
        let fresh = FileBackgroundSwitch(fileURL: switchURL, defaults: defaults)
        #expect(!fresh.isOn)
        #expect(!fresh.forgetPending)
        #expect(fresh.nextDue == nil)
        #expect(fresh.heldBeforeLoad == nil)
        #expect(!FileManager.default.fileExists(atPath: switchURL.path), "reading writes nothing back")
        // The marker is all that stays, and it holds nothing.
        #expect(try Data(contentsOf: fresh.markerURL).isEmpty)
        // Old keys that come back after the forget, as from an old backup,
        // never move over: no launch turns it on without a tap.
        keepTheOldKeys()
        expectOff(switchURL, defaults: defaults, "the old keys came back after the forget")

        // And when it erases at once, the same. A switch that has never
        // been kept moves the old keys over, for this part.
        let otherURL = Scratch.url("background-switch-never-kept")
        #expect(!FileManager.default.fileExists(atPath: FileBackgroundSwitch(fileURL: otherURL).markerURL.path),
                "a switch never kept, with no marker of its own")
        keepTheOldKeys()
        let again = BackgroundRunner(store: scratchStore(),
                                     toggle: FileBackgroundSwitch(fileURL: otherURL, defaults: defaults),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(again.isOn, "moved over, for this part")
        keepTheOldKeys()
        try again.forget()
        #expect(oldKeysLeft().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: otherURL.path))
        #expect(!again.isOn)
        #expect(again.switchReading == .off)
        #expect(again.nextWake(now: at(8)) == nil)
        keepTheOldKeys()
        expectOff(otherURL, defaults: defaults, "erased at once, then the old keys came back")
    }

    /// After Forget everything, the real switch keeps nothing about the
    /// person, though a run had waited and the earlier version had kept it
    /// in `UserDefaults`: no due time, no held run, no wait, no file, and
    /// none of the old keys left in `UserDefaults`, whose other keys stay.
    /// Only the empty marker is left, since old keys were seen.
    @Test func forgetEverythingLeavesTheRealSwitchClean() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FileBackgroundSwitch.LegacyKeys.on)
        defaults.set(at(7), forKey: FileBackgroundSwitch.LegacyKeys.nextDue)
        defaults.set(BackgroundHold.lowPower.rawValue, forKey: FileBackgroundSwitch.LegacyKeys.held)
        defaults.set(at(6), forKey: FileBackgroundSwitch.LegacyKeys.heldAt)
        defaults.set("kept", forKey: "another.setting")
        let switchURL = Scratch.url("background-switch")
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        let runner = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL, defaults: defaults),
                                      needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(runner.isOn)
        runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, fileShut: true))
        let before = FileBackgroundSwitch(fileURL: switchURL)
        #expect(before.heldBeforeLoad?.at == at(7, 1), "a run waited")
        #expect(before.nextDue != nil)

        try unlock()
        try runner.forget()
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        #expect(keys == ["another.setting"], "none of the old keys")
        #expect(!FileManager.default.fileExists(atPath: switchURL.path))
        #expect(!FileManager.default.fileExists(atPath: before.stagingURL.path))
        let fresh = FileBackgroundSwitch(fileURL: switchURL, defaults: defaults)
        #expect(!fresh.isOn)
        #expect(!fresh.forgetPending)
        #expect(fresh.nextDue == nil)
        #expect(fresh.heldBeforeLoad == nil)
        #expect(try Data(contentsOf: fresh.markerURL).isEmpty, "the marker, empty")
        #expect(!FileManager.default.fileExists(atPath: switchURL.path), "reading writes nothing back")
    }

    /// A fresh read of the switch, and a launch on it, read off with the
    /// old keys there, and ask for no wake.
    private func expectOff(_ switchURL: URL, defaults: UserDefaults, _ when: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!FileBackgroundSwitch(fileURL: switchURL, defaults: defaults).isOn, "\(when)",
                sourceLocation: sourceLocation)
        let launch = BackgroundRunner(store: scratchStore(),
                                      toggle: FileBackgroundSwitch(fileURL: switchURL, defaults: defaults),
                                      calendar: calendar)
        #expect(!launch.isOn, "\(when)", sourceLocation: sourceLocation)
        #expect(launch.switchReading == .off, "\(when)", sourceLocation: sourceLocation)
        #expect(launch.nextWake(now: at(8)) == nil, "\(when)", sourceLocation: sourceLocation)
    }

    /// Forget everything couldn't erase the file, and then the person turns
    /// work on, or off, once it can. The erase that waited goes before the
    /// switch moves, so it never undoes the tap: one tap, on, read on by
    /// the next launch, with the next morning queued and kept in the file.
    @Test func turningOnAfterAForgetThatFailedStaysOn() throws {
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
        let switchURL = Scratch.url("background-switch")
        let toggle = OrderedSwitch(FileBackgroundSwitch(fileURL: switchURL))
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: background)
        #expect(!runner.results.isEmpty)
        faults.eraseFails = true
        #expect(throws: (any Error).self) { try runner.forget() }
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending)

        faults.eraseFails = false
        toggle.clear()
        runner.turnOn(now: at(9))
        #expect(toggle.steps.prefix(2) == ["forgetPending(false)", "set(true)"], "the erase first")
        #expect(runner.isOn, "one tap, on")
        #expect(runner.switchReading == .on)
        let fresh = FileBackgroundSwitch(fileURL: switchURL)
        #expect(fresh.isOn, "the next launch reads on")
        #expect(!fresh.forgetPending)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(runner.queue.map(\.due) == [at(7, days: 1)])
        #expect(runner.nextWake(now: at(9)) == at(7, days: 1))
        #expect(try store.load().queue.map(\.due) == [at(7, days: 1)], "kept in the file")
        #expect(try store.load().results.isEmpty, "none of the old cards came back")
        let next = BackgroundRunner(store: store, toggle: fresh, calendar: calendar)
        #expect(next.queue.map(\.kind) == [.morningSummary])

        // And off the same way.
        faults.eraseFails = true
        #expect(throws: (any Error).self) { try runner.forget() }
        faults.eraseFails = false
        toggle.clear()
        runner.turnOff()
        #expect(toggle.steps.prefix(2) == ["forgetPending(false)", "set(false)"], "the erase first")
        #expect(!FileBackgroundSwitch(fileURL: switchURL).isOn)
        #expect(!FileBackgroundSwitch(fileURL: switchURL).forgetPending)
        #expect(runner.queue.isEmpty)
    }

    /// The same across launches, while the file still can't be erased: a
    /// launch that finds the forget waiting is turned on. Nothing goes in
    /// the old file, the tap is kept beside the switch, and the launch that
    /// can erase the file keeps it on and queues only the next morning.
    @Test func turningOnWhileAForgetWaitsStaysOnAcrossLaunches() throws {
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: faults)
        let switchURL = Scratch.url("background-switch")
        func launch() -> BackgroundRunner {
            BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL), needsYou: oneWaiting(),
                             watchingSince: .distantPast, calendar: calendar)
        }
        let first = launch()
        first.turnOn(now: at(6))
        first.runDue(now: at(7), conditions: background)
        #expect(!first.results.isEmpty)
        faults.eraseFails = true
        #expect(throws: (any Error).self) { try first.forget() }
        let bytes = try Data(contentsOf: store.fileURL)

        let stuck = launch()
        #expect(!stuck.isOn)
        stuck.turnOn(now: at(9, days: 1))
        #expect(stuck.isOn, "one tap, on")
        #expect(stuck.results.isEmpty, "none of its cards come back")
        #expect(stuck.runDue(now: at(9, 5, days: 1), conditions: .foreground).isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == bytes, "nothing written into it")
        let waiting = FileBackgroundSwitch(fileURL: switchURL)
        #expect(waiting.forgetPending, "still waits")
        #expect(waiting.isOn, "the tap is kept beside the switch")

        faults.eraseFails = false
        let later = launch()
        #expect(later.results.isEmpty, "none of the old cards")
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(later.isOn, "the erase kept the tap")
        #expect(later.switchReading == .on)
        let fresh = FileBackgroundSwitch(fileURL: switchURL)
        #expect(fresh.isOn)
        #expect(!fresh.forgetPending)
        later.runDue(now: at(9, 30, days: 1), conditions: .foreground)
        #expect(later.queue.map(\.due) == [at(7, days: 2)])
        #expect(try store.load().queue.map(\.due) == [at(7, days: 2)], "only the fresh job in the file")
        #expect(try store.load().results.isEmpty)
    }

    /// A switch file that is there but won't read, as after a disk error,
    /// can't be told from off. Through the switch's faults, so no file
    /// modes are needed and root runs it the same: unknown, never off, so
    /// nothing runs and nothing is written over it. It asks for one look,
    /// the first morning after it was found so, and none after that
    /// morning has come, so it never wakes the device all night. Turned
    /// off meanwhile, off is laid over it once it reads again.
    @Test func aSwitchThatWontReadIsUnknown() throws {
        let store = scratchStore()
        let switchURL = Scratch.url("background-switch")
        let setUp = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        setUp.turnOn(now: at(6))
        let bytes = try Data(contentsOf: switchURL)

        let faults = BackgroundSwitchFaults(readFails: true)
        let toggle = FileBackgroundSwitch(fileURL: switchURL, faults: faults)
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        #expect(!toggle.isKnown)
        #expect(!toggle.isOn)
        #expect(runner.switchReading == .unknown)
        #expect(runner.nextWake(now: at(2)) == at(7), "one look, that morning")
        #expect(runner.nextWake(now: at(4)) == at(7), "not every quarter hour")
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        #expect(runner.nextWake(now: at(7, 1)) == nil, "the morning came and it still can't read: no more")
        #expect(runner.nextWake(now: at(9, days: 1)) == nil)
        #expect(!runner.didItsWork(now: at(7, 1)))
        runner.turnOff()
        #expect(try Data(contentsOf: switchURL) == bytes, "nothing written over it")

        faults.readFails = false
        #expect(toggle.isKnown)
        #expect(runner.switchReading == .off)
        #expect(!FileBackgroundSwitch(fileURL: switchURL).isOn, "the off waited, and went in")
    }

    /// Turned on while the switch won't read, the tap is kept, not dropped:
    /// once it reads again, it is on, in this launch and the next, with the
    /// next morning queued.
    @Test func turningOnWhileTheSwitchWontReadIsKept() throws {
        let store = scratchStore()
        let switchURL = Scratch.url("background-switch")
        let setUp = FileBackgroundSwitch(fileURL: switchURL)
        setUp.set(false)
        let faults = BackgroundSwitchFaults(readFails: true)
        let toggle = FileBackgroundSwitch(fileURL: switchURL, faults: faults)
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        #expect(runner.switchReading == .unknown)
        runner.turnOn(now: at(6))
        #expect(!FileBackgroundSwitch(fileURL: switchURL).isOn, "not written while it won't read")

        faults.readFails = false
        #expect(runner.switchReading == .on)
        #expect(FileBackgroundSwitch(fileURL: switchURL).isOn, "the tap went in")
        #expect(runner.queue.map(\.due) == [at(7)])
        #expect(runner.nextWake(now: at(6)) == at(7))
    }

    /// Forget everything couldn't erase the file, and the next launch can't
    /// read the switch that says so. It never reads the file then: none of
    /// the forgotten cards come back, in the runner or in Today, and
    /// nothing the person does meanwhile writes over the file. Once the
    /// switch reads, the forget it kept goes on.
    @Test func aSwitchThatWontReadNeverBringsForgottenCardsBack() throws {
        let storeFaults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: Scratch.url("background"), faults: storeFaults)
        let switchURL = Scratch.url("background-switch")
        let first = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        first.turnOn(now: at(6))
        first.runDue(now: at(7), conditions: background)
        let card = try #require(first.results.first)
        storeFaults.eraseFails = true
        #expect(throws: (any Error).self) { try first.forget() }
        #expect(FileBackgroundSwitch(fileURL: switchURL).forgetPending)
        let bytes = try Data(contentsOf: store.fileURL)

        // The next launch: the erase still fails, and the switch won't read.
        let switchFaults = BackgroundSwitchFaults(readFails: true)
        let next = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL, faults: switchFaults),
                                    needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(next.switchReading == .unknown)
        #expect(next.results.isEmpty, "none of the forgotten cards")
        #expect(next.feed.items(now: at(8)).isEmpty)
        #expect(Feed.build(from: [next.feed], now: at(8), calendar: calendar).isEmpty, "none in Today")
        next.dismiss(card.id)
        next.turnOn(now: at(8))
        #expect(next.runDue(now: at(8), conditions: .foreground).isEmpty)
        #expect(next.results.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == bytes, "nothing written over it")

        // The switch reads again and says the forget waits: still nothing.
        switchFaults.readFails = false
        #expect(next.results.isEmpty)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
        // Once it can be erased, the next look erases it, and the tap
        // made meanwhile stays.
        storeFaults.eraseFails = false
        next.runDue(now: at(9), conditions: .foreground)
        #expect(!FileBackgroundSwitch(fileURL: switchURL).forgetPending)
        #expect(next.isOn)
        #expect(try store.load().results.isEmpty, "none of the old cards in the file")
        #expect(next.results.isEmpty)
    }

    /// An off that can't be written, as on a full disk, never comes back
    /// on. The switch isn't known meanwhile, so the runner never trusts the
    /// on the disk may still say, and the file goes, so a new launch never
    /// reads that on. Once writes go through, the next read writes the off.
    @Test func anOffThatCantBeWrittenNeverReadsOnAgain() throws {
        let store = scratchStore()
        let switchURL = Scratch.url("background-switch")
        let faults = BackgroundSwitchFaults()
        let toggle = FileBackgroundSwitch(fileURL: switchURL, faults: faults)
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        #expect(FileBackgroundSwitch(fileURL: switchURL).isOn)

        faults.writeFails = true
        runner.turnOff()
        #expect(!toggle.isOn)
        #expect(!toggle.isKnown, "the disk may still say on")
        #expect(runner.switchReading == .unknown)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        #expect(!runner.didItsWork(now: at(7, 1)))
        // A new launch, as iOS starts for the next wake.
        #expect(!FileBackgroundSwitch(fileURL: switchURL).isOn, "never reads the on from before")
        let fresh = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(fresh.switchReading != .on)
        #expect(fresh.runDue(now: at(7, 1), conditions: background).isEmpty)

        faults.writeFails = false
        #expect(toggle.isKnown, "written at the next read")
        #expect(runner.switchReading == .off)
        #expect(FileManager.default.fileExists(atPath: switchURL.path))
        #expect(!FileBackgroundSwitch(fileURL: switchURL).isOn)
        #expect(runner.nextWake(now: at(8)) == nil)
    }

    /// The same for the due time and a held run: a write that fails is
    /// tried again at the next read, so a later launch still finds them.
    @Test func aWriteThatFailsIsTriedAgain() throws {
        let switchURL = Scratch.url("background-switch")
        let faults = BackgroundSwitchFaults()
        let toggle = FileBackgroundSwitch(fileURL: switchURL, faults: faults)
        toggle.set(true)
        faults.writeFails = true
        toggle.setNextDue(at(7))
        toggle.setHeldBeforeLoad(BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        #expect(FileBackgroundSwitch(fileURL: switchURL).nextDue == nil, "not written yet")
        #expect(FileBackgroundSwitch(fileURL: switchURL).isOn, "on stays on: the file is kept")
        #expect(toggle.isKnown, "on is on, written or not")

        faults.writeFails = false
        #expect(toggle.nextDue == at(7))
        let fresh = FileBackgroundSwitch(fileURL: switchURL)
        #expect(fresh.nextDue == at(7))
        #expect(fresh.heldBeforeLoad == BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        #expect(fresh.isOn)
    }

    /// Off written beside the switch is the person's own off, even while
    /// the runner's file is shut before the first unlock: no wake is asked
    /// for. Only a switch never set can't be told from unread then
    /// (`offBeforeTheFirstUnlockIsUnknown`).
    @Test func offSetBeforeTheFirstUnlockIsOff() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                       due: at(7))]))
        let toggle = scratchSwitch()
        toggle.set(false)
        let runner = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: toggle.fileURL),
                                      calendar: calendar)
        #expect(runner.switchReading == .off)
        #expect(runner.nextWake(now: at(2)) == nil)
        #expect(!runner.didItsWork(now: at(7, 1)))
    }

    @Test func aDayThatEndedSaysItCouldntAndTodayStillRuns() throws {
        let runner = runner(tasks: FixedTasks([]))
        let locked = BackgroundConditions(moment: .background, fileShut: true)
        runner.runDue(now: at(7, 1), conditions: locked)
        runner.runDue(now: at(13), conditions: locked)

        let made = runner.runDue(now: at(9, days: 1), conditions: .foreground)
        #expect(made.count == 2)
        let missed = made[0].item(calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(missed.kind == .noticed)
        #expect(missed.title == "I couldn't make Thursday's summary")
        #expect(missed.body == BackgroundWords.missed(.locked))
        guard case .morningSummary = made[1].content else { Issue.record("today's summary didn't run"); return }
        #expect(runner.queue.first?.due == at(7, days: 2))
    }

    @Test func aMissedDayBeforeTheMorningWaitsForTheMorning() {
        let runner = runner(tasks: FixedTasks([]))
        let made = runner.runDue(now: at(5, days: 1), conditions: background)
        #expect(made.count == 1)
        #expect(made.first?.item(calendar: calendar).body == BackgroundWords.missed(nil))
        #expect(runner.queue.first?.due == at(7, days: 1))
    }

    /// Several days went by: one card names them all, and says only what
    /// is true of every one of them.
    @Test func severalMissedDaysAreNamedHonestly() throws {
        let en = Locale(identifier: "en_US")
        let runner = runner(tasks: FixedTasks([]))
        let made = runner.runDue(now: at(5, days: 3), conditions: background)
        #expect(made.count == 1)
        let card = try #require(made.first?.item(calendar: calendar, locale: en))
        #expect(card.title == "I couldn't make the summaries from Thursday to Saturday")
        #expect(card.body == BackgroundWords.missedSeveral)
        // A day missed before the first unlock says that, not the screen lock.
        #expect(BackgroundWords.missed(.locked)
            == "You hadn't unlocked since your last restart, so I couldn't look in time.")
        #expect(runner.queue.first?.due == at(7, days: 3))

        let long = BackgroundWords.missedTitle(from: at(7), through: at(7, days: 8), calendar: calendar, locale: en)
        #expect(long == "I couldn't make the last 9 summaries")
    }

    /// With no task engine, as in the app today, a day the app never ran
    /// would almost always have been quiet, and a quiet morning leaves no
    /// card. So no card claims a summary was missed. The job still moves
    /// on to this morning and runs.
    @Test func withNoTasksAMissedDayLeavesNoCard() throws {
        let runner = runner(tasks: nil)
        let locked = BackgroundConditions(moment: .background, fileShut: true)
        runner.runDue(now: at(7, 1), conditions: locked)

        #expect(runner.runDue(now: at(5, days: 1), conditions: background).isEmpty)
        #expect(runner.results.isEmpty)
        #expect(runner.queue.first?.due == at(7, days: 1))
        #expect(runner.queue.first?.held == nil)

        let made = runner.runDue(now: at(9, days: 3), conditions: .foreground)
        #expect(made.count == 1)
        guard case .morningSummary = made.first?.content else { Issue.record("today's summary didn't run"); return }
        #expect(!runner.results.contains { if case .missed = $0.content { true } else { false } })
        #expect(runner.queue.first?.due == at(7, days: 4))
    }

    @Test func oldCardsGo() {
        let runner = runner()
        for day in 0..<20 { runner.runDue(now: at(7, days: day), conditions: background) }
        #expect(runner.results.count == 8)
        #expect(runner.results.first?.madeAt == at(7, days: 19))
        #expect(BackgroundRunner.prune((0..<20).map { BackgroundResult(madeAt: at(7) + Double($0), content: .missed(
            kind: .morningSummary, due: at(7), held: nil)) }, now: at(8)).count == BackgroundPlan.maxResults)
    }

    // MARK: Never acting without a yes

    @Test func itNeverAsksWhileThePersonIsAway() {
        let asks = NeedsYou(rule: .isolated())
        let runner = runner(needsYou: asks)
        let acted = Counter()
        #expect(runner.propose(note, conditions: background, at: at(7), act: { acted.add() }) == nil)
        #expect(asks.items(now: at(7)).isEmpty)
        runner.turnOff()
        #expect(runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() }) == nil)
        #expect(acted.value == 0)
    }

    @Test func itActsOnlyAfterAYesAndOnlyOnce() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let runner = runner(needsYou: asks)
        let acted = Counter()
        let asked = runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() })
        let request = try #require(asked)
        // Waiting in Needs you, and nothing done.
        #expect(asks.items(now: at(9)).map(\.request) == [request])
        runner.runDue(now: at(9), conditions: .foreground)
        #expect(acted.value == 0)

        guard case .approved(let yes) = rule.sayYes(to: request) else { Issue.record("yes refused"); return }
        asks.approved(yes)
        #expect(acted.value == 1)
        // The same yes again does nothing.
        asks.approved(yes)
        #expect(acted.value == 1)
    }

    @Test func aNoOrATimeoutNeverActs() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: { clock.now() })
        let asks = NeedsYou(rule: rule)
        let runner = runner(needsYou: asks)
        let acted = Counter()

        let first = runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() })
        let declined = try #require(first)
        rule.withdraw(declined)
        asks.dismissed(declined)

        let second = runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() })
        let late = try #require(second)
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.sayYes(to: late) == .timedOut)
        #expect(acted.value == 0)
        #expect(asks.items(now: at(9)).isEmpty)
    }

    /// Turning it off withdraws what it asked, so a yes on a sheet still
    /// open does nothing, and so does Forget everything.
    @Test func turningOffOrForgettingWithdrawsWhatItAsked() throws {
        for forget in [false, true] {
            let rule = AskFirst.isolated()
            let asks = NeedsYou(rule: rule)
            let runner = runner(needsYou: asks)
            let acted = Counter()
            let asked = runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() })
            let request = try #require(asked)
            if forget { try runner.forget() } else { runner.turnOff() }
            #expect(asks.items(now: at(9)).isEmpty)
            #expect(rule.isClosed(request))
            #expect(rule.wasWithdrawn(request))
            #expect(rule.sayYes(to: request) == .timedOut)
            #expect(acted.value == 0)
        }
    }

    /// Even a yes already given does nothing once it is off.
    @Test func aYesAfterTurningOffNeverActs() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let toggle = InMemoryBackgroundSwitch()
        let runner = BackgroundRunner(store: scratchStore(), toggle: toggle, needsYou: asks, calendar: calendar)
        runner.turnOn(now: at(6))
        let acted = Counter()
        let asked = runner.propose(note, conditions: .foreground, at: at(9), act: { acted.add() })
        let request = try #require(asked)
        guard case .approved(let yes) = rule.sayYes(to: request) else { Issue.record("yes refused"); return }
        // Switched off another way, as from another window, before the yes lands.
        toggle.set(false)
        asks.approved(yes)
        #expect(acted.value == 0)
    }

    // MARK: Today

    @Test func resultsBecomeCardsInToday() throws {
        let runner = runner()
        let empty = Feed.build(from: [runner.feed], now: at(8), calendar: calendar)
        #expect(empty.isEmpty, "nothing made yet, so Today's empty words are still true")

        runner.runDue(now: at(7), conditions: background)
        let feed = Feed.build(from: [runner.feed], now: at(8), calendar: calendar)
        #expect(!feed.isEmpty)
        #expect(feed.groups.first?.period == .thisMorning)
        #expect(feed.groups.first?.items.first?.title == BackgroundWords.summaryTitle)
        #expect(!runner.feed.isSample)
    }

    @Test func aRunnerReadingExamplesMakesExamples() {
        let sample = BackgroundRunner(store: scratchStore(), toggle: InMemoryBackgroundSwitch(), calendar: calendar,
                                      sample: true)
        #expect(sample.feed.isSample)
        let readsSamples = BackgroundRunner(store: scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                            needsYou: NeedsYou(rule: .isolated(), isSample: true), calendar: calendar)
        #expect(readsSamples.isSample)
    }

    @Test func itTellsWatchersOfEachChange() {
        let runner = runner()
        let heard = Counter()
        let watch = runner.observe { heard.add() }
        runner.runDue(now: at(6, 30), conditions: background)
        #expect(heard.value == 0, "nothing changed before the morning")
        runner.runDue(now: at(7), conditions: background)
        #expect(heard.value == 1)
        runner.stopObserving(watch)
        runner.turnOff()
        #expect(heard.value == 1)
    }
}

// MARK: Words and the platform

@Suite(.scratchFiles)
struct BackgroundWordsTests {
    static var all: [String] {
        let quiet = MorningSummary(waiting: 0, finished: 0, couldNotFinish: 0, since: at(19, days: -1), late: nil)
        let busy = MorningSummary(waiting: 3, finished: 1, couldNotFinish: 2, since: at(19, days: -1), late: .locked)
        let unknown = MorningSummary(waiting: nil, finished: nil, couldNotFinish: nil, since: at(7, days: -3), late: nil)
        let en = Locale(identifier: "en_US")
        return [BackgroundWords.summaryTitle, BackgroundWords.whereWaiting,
                BackgroundWords.summaryBody(quiet, now: at(7), calendar: calendar),
                BackgroundWords.summaryBody(busy, now: at(7), calendar: calendar),
                BackgroundWords.summaryBody(unknown, now: at(7), calendar: calendar),
                BackgroundWords.summaryDetail(busy, now: at(7), calendar: calendar, locale: en),
                BackgroundWords.summaryDetail(unknown, now: at(7), calendar: calendar, locale: en),
                BackgroundWords.missedTitle(at(7)), BackgroundWords.settingTitle,
                BackgroundWords.missedTitle(from: at(7), through: at(7, days: 2), calendar: calendar, locale: en),
                BackgroundWords.missedTitle(from: at(7), through: at(7, days: 9), calendar: calendar, locale: en),
                BackgroundWords.missedSeveral, BackgroundWords.countedNothing,
                BackgroundWords.settingDetail(whileClosed: true, countsTasks: true),
                BackgroundWords.settingDetail(whileClosed: false, countsTasks: true),
                BackgroundWords.settingDetail(whileClosed: true, countsTasks: false),
                BackgroundWords.settingDetail(whileClosed: false, countsTasks: false),
                BackgroundWords.nextDue(at(7, days: 1), now: at(9), calendar: calendar),
                BackgroundWords.nextDue(at(7), now: at(6), calendar: calendar),
                BackgroundWords.nextDue(at(7, days: 3), now: at(9), calendar: calendar),
                BackgroundWords.nextDue(at(7), now: at(9), calendar: calendar)]
            + BackgroundHold.allCases.map(BackgroundWords.late)
            + (BackgroundHold.allCases.map(Optional.some) + [nil]).map(BackgroundWords.missed)
    }

    /// What Forget everything says about the summaries and what went with
    /// them. The cloud's lines name the private words, a promise allowed
    /// with its reason in `DevicePromise`, so these are swept for calm here
    /// and for promises there.
    static var forgetLines: [String] {
        MemoryWords.couldNotForgetSummariesLines + CloudWords.forgotAndCloudOffNotSummariesLines
            + [CloudWords.forgotNotesNotWords, CloudWords.forgotNotesAndTasksNotWords,
               MemoryWords.summariesGone, MemoryWords.summariesStayed,
               MemoryWords.forgetEverythingDetail(background: true), CloudWords.forgetEverythingWithSummariesDetail]
    }

    @Test func theWordsAreCalmAndPromiseNothingAboutTheDevice() {
        for line in Self.all + Self.forgetLines {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
            #expect(!line.contains("!"), "exclamation in: \(line)")
        }
        for line in Self.all {
            #expect(DevicePromise.found(in: line).isEmpty, "device promise in: \(line)")
        }
        #expect(Self.forgetLines.count == 18, "every form of each line")
    }

    /// "Nothing finished" never stands beside tasks that couldn't: the
    /// line that says what happened is enough, and the two would read as
    /// if they disagreed. With nothing that failed, it is still said.
    @Test func nothingFinishedIsLeftOutWhenSomeCouldnt() {
        let en = Locale(identifier: "en_US")
        let failed = MorningSummary(waiting: 1, finished: 0, couldNotFinish: 2, since: at(19, days: -1), late: nil)
        #expect(BackgroundWords.summaryBody(failed, now: at(7), calendar: calendar, locale: en)
            == "One thing was waiting for you. 2 tasks couldn't finish.")
        #expect(!BackgroundWords.summaryDetail(failed, now: at(7), calendar: calendar, locale: en)
            .contains("Nothing finished"))
        let quiet = MorningSummary(waiting: 1, finished: 0, couldNotFinish: 0, since: at(19, days: -1), late: nil)
        #expect(BackgroundWords.summaryBody(quiet, now: at(7), calendar: calendar, locale: en)
            == "One thing was waiting for you. Nothing finished overnight.")
    }

    @Test func theSwitchSaysWhatItDoesAndThatItAsksFirst() {
        for whileClosed in [true, false] {
            for countsTasks in [true, false] {
                let line = BackgroundWords.settingDetail(whileClosed: whileClosed, countsTasks: countsTasks)
                #expect(line.contains("summary"))
                #expect(line.contains("without asking you first"))
                if whileClosed {
                    // Overnight only after the first unlock since a restart,
                    // when the summary's file opens; otherwise on opening.
                    // The system may never give it time, so it tries, and
                    // never says it will.
                    #expect(line.contains("I try to make it overnight if you've unlocked since your last restart"))
                    #expect(!line.contains("I make it overnight"))
                    #expect(line.contains("otherwise when you open the app"), "says when it catches up")
                    #expect(!line.contains("when I can"))
                } else {
                    #expect(line.contains("as soon as you come back"), "says when it catches up")
                }
                // A quiet morning leaves no card, so it never promises one each day.
                #expect(!line.contains("Each morning"))
                // What finished is known only if the app ran all night, which
                // a summary made while closed almost never can say.
                #expect(line.contains("finished") == (countsTasks && !whileClosed),
                        "names what finished only with tasks to count and the app running")
            }
        }
    }

    /// The voice guide quotes the switch's line as the app says it.
    @Test func theVoiceGuideQuotesTheSwitchsLine() throws {
        let guide = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("docs/VOICE.md"), encoding: .utf8)
        let folded = guide.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(folded.contains("\"I try to make it overnight if you've unlocked since your last restart, and "
            + "otherwise when you open the app.\""))
        #expect(BackgroundWords.settingDetail(whileClosed: true, countsTasks: false)
            .contains("I try to make it overnight if you've unlocked since your last restart, and otherwise when "
                + "you open the app."))
    }

    /// When the summaries' file stayed, the line opens with what went, in
    /// plain words, and ends with the same advice as its siblings.
    @Test func aForgetThatLeftTheSummariesSaysWhatWentAndWhatToDo() {
        for line in MemoryWords.couldNotForgetSummariesLines + CloudWords.forgotAndCloudOffNotSummariesLines {
            #expect(line.hasPrefix("I "), "\(line)")
            #expect(line.contains("turned off work while you're away, but I couldn't erase your morning summaries"),
                    "\(line)")
            #expect(line.hasSuffix(" Please try Forget everything again in a moment."), "\(line)")
        }
        // Only what went is named: notes and tasks only when there were
        // some, the hidden words only when they were erased, and a comma
        // before "and turned off" once two or more are named.
        let opens: [((Bool, Bool, Bool), String)] = [
            ((false, false, false), "I turned off work while you're away"),
            ((false, false, true), "I forgot any words you asked me to hide and turned off work while you're away"),
            ((false, true, false), "I forgot your tasks and turned off work while you're away"),
            ((false, true, true),
             "I forgot your tasks and any words you asked me to hide, and turned off work while you're away"),
            ((true, false, false), "I forgot your notes and turned off work while you're away"),
            ((true, false, true),
             "I forgot your notes and any words you asked me to hide, and turned off work while you're away"),
            ((true, true, false), "I forgot your notes and tasks, and turned off work while you're away"),
            ((true, true, true),
             "I forgot your notes, tasks and any words you asked me to hide, and turned off work while you're away"),
        ]
        for ((notes, tasks, words), open) in opens {
            #expect(MemoryWords.forgotAndTurnedOff(notes: notes, tasks: tasks, words: words) == open)
            #expect(MemoryWords.couldNotForgetSummaries(notes: notes, tasks: tasks, words: words)
                == open + ", but I couldn't erase your morning summaries just now. "
                + "Please try Forget everything again in a moment.")
        }
        #expect(Set(MemoryWords.couldNotForgetSummariesLines).count == 8)
        // The cloud's forms open the same way. The private words went, and
        // the sentence after says so.
        let cloudTail: String = ", but I couldn't erase your morning summaries just now. To be sure your private "
            + "words were gone, I cleared the cloud setting too, so help from the cloud is off. Please try Forget "
            + "everything again in a moment."
        for notes in [false, true] {
            for tasks in [false, true] {
                let open = MemoryWords.forgotAndTurnedOff(notes: notes, tasks: tasks, words: false)
                #expect(CloudWords.forgotAndCloudOffNotSummaries(notes: notes, tasks: tasks) == open + cloudTail)
            }
        }
        #expect(!CloudWords.forgotAndCloudOffNotSummaries(notes: true, tasks: false).contains("tasks"))
        #expect(!CloudWords.forgotAndCloudOffNotSummaries(notes: false, tasks: true).contains("notes"))
        #expect(CloudWords.forgotNotesNotWords.hasSuffix(" Please try Forget everything again in a moment."),
                "the sibling it matches")
    }

    /// `BackgroundStore.shutError` can only be proven on a device before its
    /// first unlock, so the release checklist in AGENTS.md says how.
    @Test func theShutErrorIsAManualCheckBeforeRelease() throws {
        #expect(BackgroundStore.shutError == EPERM)
        let agents = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("AGENTS.md"), encoding: .utf8)
        let checks = try #require(agents.range(of: "## Manual checks before release"))
        let section = agents[checks.upperBound...]
        let end = section.range(of: "\n## ")?.lowerBound ?? section.endIndex
        #expect(section[..<end].contains("`BackgroundStore.shutError` is `EPERM`"))
    }

    @Test func theNextOneSaysWhichDay() {
        #expect(BackgroundWords.nextDue(at(7), now: at(6), calendar: calendar, locale: Locale(identifier: "en_US"))
            .hasSuffix("today."))
        #expect(BackgroundWords.nextDue(at(7, days: 1), now: at(9), calendar: calendar, locale: Locale(identifier: "en_US"))
            .hasSuffix("tomorrow."))
    }

    /// The system refuses identifiers its Info.plist doesn't list, and the
    /// plist comes from project.yml, where the bundle identifier fills in.
    @Test func theIdentifiersAreListedForTheSystem() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("- $(PRODUCT_BUNDLE_IDENTIFIER)\(BackgroundIdentifiers.refreshSuffix)"))
        #expect(project.contains("BGTaskSchedulerPermittedIdentifiers:"))
        #expect(project.contains("UIBackgroundModes:"))
        #expect(project.contains("- fetch"))
        #expect(!project.contains("- processing"), "one refresh task is enough for a short count")
        #expect(BackgroundIdentifiers.refresh(bundleIdentifier: "org.example.app") == "org.example.app.background.refresh")
        #expect(BackgroundIdentifiers.mac(bundleIdentifier: "org.example.app") == "org.example.app.background.mac")
    }

    /// The summary's file opens once the device has been unlocked since it
    /// started, so a run in the night can write it. The notes and the
    /// private words keep the strictest class. On iPhone and iPad each store
    /// writes its staged copy with these options, and the rename that makes
    /// it the file keeps the class. Chat isn't kept on disk at all
    /// (`theChatIsNeverKeptOnDisk` in PebbleUITests).
    @Test func eachFileKeepsItsProtectionClass() {
        #expect(BackgroundStore.fileProtection == .completeUntilFirstUserAuthentication)
        #expect(MemoryStore.fileProtection == .complete)
        #expect(CloudHelpFileStore.fileProtection == .complete)

        func protection(_ type: FileProtectionType) -> Data.WritingOptions {
            Data.WritingOptions.staged(type, protecting: true).intersection(.fileProtectionMask)
        }
        #expect(protection(BackgroundStore.fileProtection) == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(protection(MemoryStore.fileProtection) == .completeFileProtection)
        #expect(protection(CloudHelpFileStore.fileProtection) == .completeFileProtection)
        #expect(protection(FileBackgroundSwitch.fileProtection) == .noFileProtection)
        for type in [BackgroundStore.fileProtection, MemoryStore.fileProtection, CloudHelpFileStore.fileProtection,
                     FileBackgroundSwitch.fileProtection] {
            #expect(Data.WritingOptions.staged(type, protecting: true).contains(.withoutOverwriting))
            #expect(Data.WritingOptions.staged(type, protecting: false) == .withoutOverwriting, "the Mac has no classes")
        }
    }

    /// Each class maps to its own writing option, so a swapped case in
    /// `staged(_:protecting:)` fails here, whichever store uses it.
    @Test func eachClassWritesWithItsOwnOption() {
        let expected: [(FileProtectionType, Data.WritingOptions)] = [
            (.complete, .completeFileProtection),
            (.completeUnlessOpen, .completeFileProtectionUnlessOpen),
            (.completeUntilFirstUserAuthentication, .completeFileProtectionUntilFirstUserAuthentication),
            (.none, .noFileProtection),
        ]
        for (type, option) in expected {
            let options = Data.WritingOptions.staged(type, protecting: true)
            #expect(options.intersection(.fileProtectionMask) == option, "\(type.rawValue)")
            #expect(options == [.withoutOverwriting, option], "\(type.rawValue)")
        }
    }

    /// Each store's own save asks for its own class, through the write it
    /// really makes, so a save that named another class would fail here.
    @Test func eachSaveAsksForItsOwnProtectionClass() throws {
        let summaries = ProtectionLog()
        let store = BackgroundStore(fileURL: Scratch.url("background"), writer: summaries.writer)
        let runner = runner(store: store)
        runner.runDue(now: at(7), conditions: background)
        #expect(!summaries.classes.isEmpty)
        #expect(summaries.classes.allSatisfy { $0 == .completeUntilFirstUserAuthentication })
        #expect(store.hasStoredFile, "the real write ran")

        let notes = ProtectionLog()
        let memory = MemoryStore(fileURL: Scratch.url("memory"), writer: notes.writer)
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        #expect(notes.classes == [.complete])
        #expect(memory.notes().count == 1)

        let words = ProtectionLog()
        let cloud = CloudHelpFileStore(fileURL: Scratch.url("cloud-help"), writer: words.writer)
        try cloud.save(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        #expect(words.classes == [.complete])
        #expect(try cloud.load().privateWords == ["lemon cake"])
    }

    /// A summary made beside notes and private words carries none of their
    /// text, in its file or on its card, even when the same words sit in a
    /// question and a task it counts: only counts and times go in.
    @Test func aSummaryCopiesNothingFromTheNotesOrThePrivateWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = ["Marigold clinic", "Zephyrine", "Juniper Lane"]
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Appointment at \(secrets[0]) on Friday.", source: .toldMe)
        let words = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try words.save(CloudHelpSettings(isOn: false, privateWords: [secrets[1], secrets[2]]))

        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = asks.ask(ProposedAction(kind: .send,
                                    recipient: Recipient(id: "c:z", displayName: secrets[1], handle: "z@example.com"),
                                    details: "Call \(secrets[0]) about \(secrets[2])"), at: at(6, 50))
        let tasks = FixedTasks([
            AgentTask(id: "a", title: "Book \(secrets[0])", step: "Asked \(secrets[1])", state: .done,
                      startedAt: at(1), updatedAt: at(2)),
        ], rule: rule)
        let store = BackgroundStore(fileURL: folder.appendingPathComponent("background.json"))
        let runner = runner(store: store, needsYou: asks, tasks: tasks)
        let made = try #require(runner.runDue(now: at(7), conditions: background).first)

        // Lowercased on both sides, so a copy in other capitals is caught too.
        let file = try String(contentsOf: store.fileURL, encoding: .utf8).lowercased()
        let card = made.item(calendar: calendar, locale: Locale(identifier: "en_US"))
        let shown = [card.title, card.body, card.action.map { "\($0)" } ?? ""].joined(separator: " ").lowercased()
        let pieces = secrets.flatMap { $0.split(separator: " ").map(String.init) }
        for secret in (secrets + pieces).map({ $0.lowercased() }) {
            #expect(!file.contains(secret), "\(secret) in the summary's file")
            #expect(!shown.contains(secret), "\(secret) on the card")
        }
        #expect(card.body.contains("One thing was waiting for you."), "it did count them")
    }

    /// Nothing a question holds, nor a note or a private word, reaches the
    /// summary's file, a staged copy of it, or the switch's file, through a
    /// question `propose` asked, a summary, or a run held before the first
    /// unlock. Every byte either store wrote is read raw, each staged copy
    /// included, and each file left on disk.
    @Test func theSummaryAndSwitchFilesCopyNothingOfThePersons() throws {
        let folder = Scratch.url("raw").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seeded = ["Marigold clinic", "Zephyrine"]
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Appointment at \(seeded[0]) on Friday.", source: .toldMe)
        let words = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try words.save(CloudHelpSettings(isOn: false, privateWords: [seeded[1]]))

        let summaryWrites = ProtectionLog()
        let faults = BackgroundStoreFaults()
        let store = BackgroundStore(fileURL: folder.appendingPathComponent("background.json"),
                                    writer: summaryWrites.writer, faults: faults)
        let switchWrites = ProtectionLog()
        let switchURL = folder.appendingPathComponent("background-switch.json")
        let asks = NeedsYou(rule: .isolated())
        let runner = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL,
                                                                                writer: switchWrites.writer),
                                      needsYou: asks, watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        #expect(runner.propose(note, conditions: .foreground, at: at(6, 30), act: {}) != nil)
        #expect(runner.runDue(now: at(7), conditions: background).count == 1, "the summary counted the question")

        // The next night, a fresh launch before the first unlock holds the run.
        faults.openError = BackgroundStore.shutError
        let night = BackgroundRunner(store: store, toggle: FileBackgroundSwitch(fileURL: switchURL,
                                                                               writer: switchWrites.writer),
                                     needsYou: asks, watchingSince: .distantPast, calendar: calendar)
        #expect(night.runDue(now: at(7, 1, days: 1), conditions: BackgroundConditions(moment: .background,
                                                                                      fileShut: true)).isEmpty)
        #expect(FileBackgroundSwitch(fileURL: switchURL).heldBeforeLoad != nil, "the held run was kept")
        faults.openError = nil
        night.runDue(now: at(8, days: 1), conditions: .foreground)

        #expect(!summaryWrites.payloads.isEmpty && !switchWrites.payloads.isEmpty, "both were written")
        var raw = summaryWrites.payloads + switchWrites.payloads
        let toggle = FileBackgroundSwitch(fileURL: switchURL)
        for url in [store.fileURL, store.stagingURL, switchURL, toggle.stagingURL, toggle.markerURL]
        where FileManager.default.fileExists(atPath: url.path) {
            raw.append(try Data(contentsOf: url))
        }
        let text = raw.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n").lowercased()
        let pieces: [String] = seeded.flatMap { $0.split(separator: " ").map(String.init) }
        let asked: [String?] = [note.details, note.recipient.handle, note.recipient.displayName]
        let secrets: [String] = asked.compactMap { $0 } + ["See you"] + seeded + pieces
        #expect(secrets.count == 9, "the details, the handle and the name, each there to look for")
        for secret in secrets.map({ $0.lowercased() }) {
            #expect(!text.contains(secret), "\(secret) on disk")
        }
    }

    /// A test gated on running as someone other than root would skip, and
    /// the suite stay green, wherever tests run as root. The lock and erase
    /// fakes go through `BackgroundStoreFaults` instead, and the few tests
    /// that still need file modes use the traits in `FileModes.swift`, which
    /// fail in CI rather than skip. So nothing else asks who it runs as, by
    /// any of the ways a test could, and nothing else turns a test on or off
    /// by a condition of its own.
    @Test func noTestSkipsQuietlyAsRoot() throws {
        let tests = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Tests")
        let asks = try NSRegularExpression(pattern: #"\bget(e)?uid\b|\buserName\b|\bNSUserName\b|\.enabled\(\s*if:|\.disabled\(\s*if:"#)
        let asking = try SwiftSource.files(under: tests).filter { file in
            let code = String(SwiftSource(file.text).code)
            return asks.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
        #expect(asking.map(\.name) == ["TestScratch/FileModes.swift"])
        // The sweep would catch each way.
        for way in ["getuid() != 0", "geteuid() == 0", "ProcessInfo.processInfo.userName == \"root\"",
                    "@Test(.enabled(if: x))", "@Test(.disabled(if: x))", "NSUserName()"] {
            #expect(asks.firstMatch(in: way, range: NSRange(way.startIndex..., in: way)) != nil, "\(way)")
        }
    }

    /// `.fileModesHoldOrCI` alone would run as root in CI and pass or fail
    /// by chance, so each test or suite given it is given `.failsAsRoot`
    /// in the same list. And CI is found under `xcodebuild` too, which
    /// passes the test only variables named `TEST_RUNNER_` something.
    @Test func everyFileModesTestFailsAsRoot() throws {
        let tests = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Tests")
        var lists = 0
        for file in try SwiftSource.files(under: tests) where file.name != "TestScratch/FileModes.swift" {
            let code = String(SwiftSource(file.text).code)
            let uses = code.components(separatedBy: ".fileModesHoldOrCI").count - 1
            let traits = Self.traitLists(in: code).filter { $0.contains(".fileModesHoldOrCI") }
            #expect(traits.count == uses, "\(file.name): .fileModesHoldOrCI outside a @Test or @Suite")
            for list in traits {
                lists += 1
                #expect(list.contains(".failsAsRoot"), "\(file.name): \(list)")
            }
        }
        #expect(lists > 0, "the sweep found the tests it is for")
        // In the code, not a comment. `FileModesTests` checks the detector
        // itself finds CI by either name.
        let modes = SwiftSource(try String(contentsOf: tests.appendingPathComponent("TestScratch/FileModes.swift"),
                                           encoding: .utf8))
        for name in ["TEST_RUNNER_CI", "CI"] {
            let read = modes.literals.contains { literal in
                literal.text == name && String(modes.code[..<literal.offset]).hasSuffix("environment[")
            }
            #expect(read, "\(name) read from the environment in code")
        }
    }

    /// The traits given each `@Test(` and `@Suite(`, up to its closing parenthesis.
    private static func traitLists(in code: String) -> [String] {
        let characters = Array(code)
        var lists: [String] = []
        for marker in ["@Test(", "@Suite("] {
            var from = code.startIndex
            while let found = code.range(of: marker, range: from..<code.endIndex) {
                var index = code.distance(from: code.startIndex, to: found.upperBound)
                var depth = 1
                let start = index
                while index < characters.count, depth > 0 {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                lists.append(String(characters[start..<max(start, index - 1)]))
                from = found.upperBound
            }
        }
        return lists
    }

    /// The showcase's store keeps nothing anywhere, so no launch leaves a
    /// file: what it holds lives in that one store's memory, as its file
    /// would hold it, and no other store, in this launch or the next, sees
    /// it. Told it won't erase, it keeps what it holds through a forget,
    /// as a real file would, so the showcase can show what that leaves.
    @Test func theShowcaseStoreWritesNothing() throws {
        let store = BackgroundStore.memoryOnly()
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                      calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: .foreground)
        #expect(runner.results.count == 1)
        #expect(store.hasStoredFile, "held in memory, as a file")
        #expect(try store.load().results.count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        let other = BackgroundStore.memoryOnly()
        #expect(!other.hasStoredFile, "nothing kept anywhere another store could find")
        #expect(try other.load() == .empty)
        try runner.forget()
        #expect(!store.hasStoredFile)
        #expect(try store.load() == .empty)

        let stuck = BackgroundStore.memoryOnly(faults: BackgroundStoreFaults(eraseFails: true))
        let held = BackgroundRunner(store: stuck, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                    calendar: calendar)
        held.turnOn(now: at(6))
        held.runDue(now: at(7), conditions: .foreground)
        #expect(throws: (any Error).self) { try held.forget() }
        #expect(stuck.hasStoredFile, "kept, as a file that won't erase is")
        #expect(held.results.isEmpty)
    }
}
