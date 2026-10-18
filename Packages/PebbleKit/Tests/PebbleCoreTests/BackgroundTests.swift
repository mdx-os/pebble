import Foundation
@testable import PebbleCore
import SourceScan
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
    BackgroundStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("background-\(UUID().uuidString).json"))
}

extension Trait where Self == ConditionTrait {
    /// Root reads a file at mode 0o000 anyway, so the lock can't be faked.
    static var fakesALock: Self { .enabled(if: geteuid() != 0, "file permissions don't hold for root") }
}

/// A file that is there but can't be opened, as before the first unlock: a
/// regular file at mode 0o000. `saved` is what the file holds, or a few
/// bytes of its own. A rename can still replace a file like this, so a
/// runner that wrote while it shouldn't would change its bytes.
private func lockedStore(saved: BackgroundState? = nil) throws -> (BackgroundStore, unlock: () throws -> Void) {
    let store = scratchStore()
    if let saved {
        try store.save(saved)
    } else {
        try Data("locked".utf8).write(to: store.fileURL)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
    #expect(!store.canOpen)
    return (store, {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
    })
}

/// The bytes of a locked store's file, read without leaving it unlocked.
private func lockedBytes(_ store: BackgroundStore) throws -> Data {
    let path = store.fileURL.path
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path) }
    return try Data(contentsOf: store.fileURL)
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
        #expect(decide(BackgroundConditions(moment: .background, locked: true)) == .hold(.locked))
        #expect(decide(BackgroundConditions(moment: .background, lowPower: true)) == .hold(.lowPower))
        #expect(decide(BackgroundConditions(moment: .background, deadline: now + 1)) == .hold(.outOfTime))
        #expect(decide(BackgroundConditions(moment: .background, deadline: now + 20)) == .run)
        // Locked comes first: nothing can be written then.
        #expect(decide(BackgroundConditions(moment: .background, lowPower: true, locked: true)) == .hold(.locked))
        // With the person here, Low Power Mode doesn't hold it back.
        #expect(decide(BackgroundConditions(moment: .foreground, lowPower: true)) == .run)
    }

    @Test func aJobWhoseDayIsOverIsMissed() {
        let job = BackgroundJob(kind: .morningSummary, due: at(7))
        #expect(BackgroundPlan.decide(job, now: at(0, days: 1), conditions: .foreground, calendar: calendar) == .missed)
        let locked = BackgroundConditions(moment: .background, locked: true)
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

struct BackgroundRunnerTests {
    @Test func backgroundWorkIsOffUntilThePersonTurnsItOn() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggle = UserDefaultsBackgroundSwitch(defaults: defaults)
        #expect(!toggle.isOn)
        let runner = BackgroundRunner(store: scratchStore(), toggle: toggle, calendar: calendar)
        #expect(runner.queue.isEmpty)
        #expect(runner.nextWake(now: at(6)) == nil)
        #expect(runner.runDue(now: at(9), conditions: .foreground).isEmpty)

        runner.turnOn(now: at(6))
        #expect(UserDefaultsBackgroundSwitch(defaults: defaults).isOn)
        #expect(runner.queue.map(\.kind) == [.morningSummary])
        #expect(runner.nextWake(now: at(6)) == at(7))
        // The due time sits beside the switch, readable while locked.
        #expect(UserDefaultsBackgroundSwitch(defaults: defaults).nextDue == at(7))

        runner.turnOff()
        #expect(!toggle.isOn)
        #expect(UserDefaultsBackgroundSwitch(defaults: defaults).nextDue == nil)
        #expect(runner.queue.isEmpty)
        #expect(runner.nextWake(now: at(6)) == nil)
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
                                             toggle: toggle, calendar: calendar)
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
                                          store: { throw BackgroundStore.Unavailable() }) == nil)
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
        let heard = Counter()
        let watch = runner.observe { heard.add() }
        defer { runner.stopObserving(watch) }

        try runner.forget()
        #expect(!toggle.isOn)
        #expect(toggle.nextDue == nil)
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
        let locked = BackgroundConditions(moment: .background, locked: true)
        #expect(runner.runDue(now: at(7, 1), conditions: locked).isEmpty)
        #expect(runner.queue.first?.held == .locked)
        let made = try #require(runner.runDue(now: at(8, 30), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.locked)))
        #expect(runner.queue.first?.held == nil)
    }

    @Test(.fakesALock) func aFileThatCantBeOpenedIsNeverWrittenOver() throws {
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
    @Test(.fakesALock) func theWaitForTheFirstUnlockOutlivesTheProcess() throws {
        let suite = "background-switch-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setUp = BackgroundRunner(store: scratchStore(), toggle: UserDefaultsBackgroundSwitch(defaults: defaults),
                                     calendar: calendar)
        setUp.turnOn(now: at(6))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: setUp.queue))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        let night = BackgroundRunner(store: store, toggle: UserDefaultsBackgroundSwitch(defaults: defaults),
                                     needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(night.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, locked: true))
            .isEmpty)
        #expect(UserDefaultsBackgroundSwitch(defaults: defaults).heldBeforeLoad
            == BackgroundHeldRun(hold: .locked, at: at(7, 1)))
        #expect(night.isHeldBack(now: at(7, 1)), "the system hears the run didn't do its work")

        // That process ends. A new one starts, and the device is unlocked.
        let morning = BackgroundRunner(store: store, toggle: UserDefaultsBackgroundSwitch(defaults: defaults),
                                       needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        try unlock()
        let made = try #require(morning.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(UserDefaultsBackgroundSwitch(defaults: defaults).heldBeforeLoad == nil, "said once")
        #expect(!morning.hasUnsavedChanges)
    }

    /// The hold goes on the job as soon as the file is read, and is written
    /// there, so a launch that only reads the queue keeps it too.
    @Test(.fakesALock) func theWaitGoesOnTheJobWhenTheFileIsRead() throws {
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let night = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        night.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, locked: true))
        try unlock()
        let next = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        #expect(next.queue.first?.held == .locked)
        #expect(toggle.heldBeforeLoad == nil)
        #expect(BackgroundRunner(store: store, toggle: toggle, calendar: calendar).queue.first?.held == .locked)
    }

    /// A file that won't open while the device isn't locked is some other
    /// trouble, such as a disk error. No lock is claimed for it, then or later.
    @Test(.fakesALock) func aDiskErrorIsNotALock() throws {
        let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
        let (store, unlock) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary,
                                                                                            due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        #expect(toggle.heldBeforeLoad == nil)
        #expect(!runner.isHeldBack(now: at(7, 1)))

        try unlock()
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == nil, "no reason claimed")
    }

    /// Held back or out of time, the run didn't do its work; once it ran,
    /// it did.
    @Test func aHeldRunIsHeldBackUntilItRuns() {
        let runner = runner()
        #expect(!runner.isHeldBack(now: at(6, 30)), "nothing due yet")
        runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, lowPower: true))
        #expect(runner.isHeldBack(now: at(7, 1)))
        runner.runDue(now: at(7, 20), conditions: background)
        #expect(!runner.isHeldBack(now: at(7, 20)))
        runner.turnOff()
        #expect(!runner.isHeldBack(now: at(7, 20)))
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
    @Test(.fakesALock) func aColdLaunchWhileLockedKeepsAskingForTime() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true),
                                      needsYou: oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        #expect(runner.nextWake(now: at(7, 1)) == at(7, 1) + BackgroundPlan.retryAfterHold)
        #expect(runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, locked: true))
            .isEmpty)
        #expect(runner.nextWake(now: at(7, 1)) == at(7, 1) + BackgroundPlan.retryAfterHold)

        // Off stays off, locked or not.
        let off = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), calendar: calendar)
        #expect(off.nextWake(now: at(7, 1)) == nil)

        try unlock()
        #expect(runner.nextWake(now: at(7, 20)) == at(7, 20) + BackgroundPlan.retryAfterHold, "due and held, so soon")
        #expect(runner.runDue(now: at(7, 20), conditions: background).count == 1)
        #expect(runner.nextWake(now: at(7, 21)) == at(7, days: 1))
    }

    /// A launch while locked in the night, as when iOS prewarms the app,
    /// asks for the due time the switch keeps, not every quarter hour until
    /// unlock. A hold before the job was due held nothing back, so the card
    /// never says it waited; one at or after due does.
    @Test(.fakesALock) func aLockedLaunchAsksForTheDueTimeAndOnlyLateHoldsAreSaid() throws {
        for (holdAt, said) in [(at(2), nil), (at(7), BackgroundHold.locked), (at(7, 5), BackgroundHold.locked)] {
            let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
            let (store, unlock) = try lockedStore(saved: saved)
            defer { try? FileManager.default.removeItem(at: store.fileURL) }
            let toggle = InMemoryBackgroundSwitch(on: true, nextDue: at(7))
            let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                          watchingSince: .distantPast, calendar: calendar)
            #expect(runner.nextWake(now: at(2)) == at(7), "the real time, not 2:15")
            let locked = BackgroundConditions(moment: .background, locked: true)
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
    @Test(.fakesALock) func aLockedLaunchWithNoKeptTimeStillAsks() throws {
        let (store, _) = try lockedStore(saved: BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))]))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(runner.nextWake(now: at(2)) == at(2) + BackgroundPlan.retryAfterHold)
    }

    /// Turned on while locked, the time kept is the sooner of the one
    /// already kept and the new morning, since the file's job keeps its time.
    @Test(.fakesALock) func turningOnWhileLockedKeepsTheSoonerTime() throws {
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
    @Test(.fakesALock) func turningOffWhileLockedSticks() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7, days: -2))])
        let (store, unlock) = try lockedStore(saved: saved)
        defer { try? store.forget() }
        let toggle = InMemoryBackgroundSwitch(on: true)
        let runner = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        runner.turnOff()
        #expect(runner.hasUnsavedChanges)

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
    @Test(.fakesALock) func forgetEverythingWhileLockedWritesNothingBack() throws {
        let saved = BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: at(7))])
        let (store, _) = try lockedStore(saved: saved)
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let toggle = InMemoryBackgroundSwitch()
        let runner = BackgroundRunner(store: store, toggle: toggle, needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        #expect(runner.runDue(now: at(7, 1), conditions: BackgroundConditions(moment: .background, locked: true))
            .isEmpty)
        #expect(runner.hasUnsavedChanges, "held in memory for when the file opens")

        try runner.forget()
        #expect(!runner.hasUnsavedChanges)
        #expect(!store.hasStoredFile, "erased even while it couldn't be read")

        // Unlocked: the file is gone, so there is nothing to put back, and
        // the runner has nothing of its own to write.
        for hour in [8, 9] { runner.runDue(now: at(hour), conditions: .foreground) }
        #expect(!store.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(!runner.hasUnsavedChanges)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        #expect(toggle.nextDue == nil)
        // Turned on from elsewhere, as by another window, it still has
        // nothing old to write: only the fresh queue goes in the file.
        toggle.set(true)
        runner.runDue(now: at(10), conditions: .foreground)
        #expect(!store.hasStoredFile, "nothing changed, so nothing written")
        let again = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(again.queue.isEmpty)
        #expect(again.results.isEmpty)
    }

    /// Turned on while locked, a job already in the file keeps its time.
    @Test(.fakesALock) func turningOnWhileLockedKeepsTheSavedJob() throws {
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

    @Test func aDayThatEndedSaysItCouldntAndTodayStillRuns() throws {
        let runner = runner(tasks: FixedTasks([]))
        let locked = BackgroundConditions(moment: .background, locked: true)
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
        let locked = BackgroundConditions(moment: .background, locked: true)
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

    @Test func theWordsAreCalmAndPromiseNothingAboutTheDevice() {
        for line in Self.all {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
            #expect(!line.contains("!"), "exclamation in: \(line)")
            #expect(DevicePromise.found(in: line).isEmpty, "device promise in: \(line)")
        }
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
                    #expect(line.contains("overnight if you've unlocked since your last restart"))
                    #expect(line.contains("otherwise when you open the app"), "says when it catches up")
                    #expect(!line.contains("when I can"))
                } else {
                    #expect(line.contains("as soon as you come back"), "says when it catches up")
                }
                // A quiet morning leaves no card, so it never promises one each day.
                #expect(!line.contains("Each morning"))
                #expect(line.contains("finished") == countsTasks, "names what finished only with tasks to count")
            }
        }
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
    /// it the file keeps the class. Chat isn't kept on disk at all.
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
        for type in [BackgroundStore.fileProtection, MemoryStore.fileProtection] {
            #expect(Data.WritingOptions.staged(type, protecting: true).contains(.withoutOverwriting))
            #expect(Data.WritingOptions.staged(type, protecting: false) == .withoutOverwriting, "the Mac has no classes")
        }
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

        let file = try String(contentsOf: store.fileURL, encoding: .utf8)
        let card = made.item(calendar: calendar, locale: Locale(identifier: "en_US"))
        let shown = [card.title, card.body, card.action.map { "\($0)" } ?? ""].joined(separator: " ")
        let pieces = secrets.flatMap { $0.split(separator: " ").map(String.init) }
        for secret in secrets + pieces {
            #expect(!file.contains(secret), "\(secret) in the summary's file")
            #expect(!shown.contains(secret), "\(secret) on the card")
        }
        #expect(card.body.contains("One thing was waiting for you."), "it did count them")
    }

    /// The showcase's store keeps nothing anywhere, so no launch leaves a file.
    @Test func theShowcaseStoreWritesNothing() throws {
        let store = BackgroundStore.memoryOnly()
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                      calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: .foreground)
        #expect(runner.results.count == 1)
        #expect(!store.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path))
        #expect(try store.load() == .empty)
    }
}
