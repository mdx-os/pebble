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

private func runner(store: BackgroundStore = scratchStore(), on: Bool = true, needsYou: NeedsYou? = nil,
                    tasks: (any TaskEngine)? = nil, now: Date = at(6)) -> BackgroundRunner {
    let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: needsYou,
                                  tasks: tasks, calendar: calendar)
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
        let suite = "pebble.background.test.\(UUID().uuidString)"
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

        runner.turnOff()
        #expect(!toggle.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.nextWake(now: at(6)) == nil)
    }

    @Test func turningOnTwiceQueuesOneJob() {
        let runner = runner()
        runner.turnOn(now: at(6, 30))
        #expect(runner.queue.count == 1)
    }

    @Test func aQuietMorningSaysSoAndComesBackTomorrow() throws {
        let runner = runner()
        #expect(runner.runDue(now: at(6, 59), conditions: background).isEmpty)
        let made = runner.runDue(now: at(7, 2), conditions: background)
        #expect(made.count == 1)
        #expect(runner.queue.first?.due == at(7, days: 1))
        let item = try #require(runner.feed.items(now: at(8)).first)
        #expect(item.kind == .did)
        #expect(item.title == BackgroundWords.summaryTitle)
        #expect(item.body == "Nothing was waiting for you. Nothing finished overnight.")
        #expect(item.action == nil)
        // Nothing more until tomorrow.
        #expect(runner.runDue(now: at(12), conditions: .foreground).isEmpty)
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
        let runner = BackgroundRunner(store: store, toggle: toggle, calendar: calendar)
        runner.turnOn(now: at(6))
        runner.runDue(now: at(7), conditions: background)
        #expect(!runner.results.isEmpty)
        let heard = Counter()
        let watch = runner.observe { heard.add() }
        defer { runner.stopObserving(watch) }

        try runner.forget()
        #expect(!toggle.isOn)
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        #expect(runner.nextWake(now: at(8)) == nil)
        #expect(!store.hasStoredFile)
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

    @Test func aFileThatCantBeOpenedIsNeverWrittenOver() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        // A folder where the file should be reads like a file that is locked.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        #expect(throws: BackgroundStore.Unavailable.self) { try store.load() }

        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)
        runner.turnOn(now: at(7, 2))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.fileURL.path).isEmpty)
        #expect(runner.hasUnsavedChanges, "kept for later, not written over the file")
    }

    @Test func aRunWhileTheFileIsLockedIsRememberedForTheCard() throws {
        let store = scratchStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let setUp = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), calendar: calendar)
        setUp.turnOn(now: at(6))
        let saved = try Data(contentsOf: store.fileURL)

        // A new launch in the night, with the file locked.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(on: true), calendar: calendar)
        #expect(runner.runDue(now: at(7, 1), conditions: background).isEmpty)

        // Unlocked again.
        try FileManager.default.removeItem(at: store.fileURL)
        try saved.write(to: store.fileURL)
        let made = try #require(runner.runDue(now: at(8), conditions: .foreground).first)
        guard case .morningSummary(let summary) = made.content else { Issue.record("not a summary"); return }
        #expect(summary.late == .locked)
        #expect(!runner.hasUnsavedChanges)
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
        runner.timeIsUp()
        #expect(runner.runDue(now: at(7, 20), conditions: background).isEmpty)
        #expect(runner.queue.first?.held == .outOfTime)

        let made = try #require(runner.runDue(now: at(7, 40), conditions: background).first)
        #expect(made.item(calendar: calendar).body.hasSuffix(BackgroundWords.late(.outOfTime)))
    }

    @Test func aDayThatEndedSaysItCouldntAndTodayStillRuns() throws {
        let runner = runner()
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
        let runner = runner()
        let made = runner.runDue(now: at(5, days: 2), conditions: background)
        #expect(made.count == 1)
        #expect(made.first?.item(calendar: calendar).body == BackgroundWords.missed(nil))
        #expect(runner.queue.first?.due == at(7, days: 2))
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
        return [BackgroundWords.summaryTitle, BackgroundWords.whereWaiting,
                BackgroundWords.summaryBody(quiet), BackgroundWords.summaryBody(busy),
                BackgroundWords.summaryDetail(busy, now: at(7), calendar: calendar, locale: Locale(identifier: "en_US")),
                BackgroundWords.missedTitle(at(7)), BackgroundWords.settingTitle,
                BackgroundWords.settingDetail(whileClosed: true), BackgroundWords.settingDetail(whileClosed: false),
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
        for line in [BackgroundWords.settingDetail(whileClosed: true), BackgroundWords.settingDetail(whileClosed: false)] {
            #expect(line.contains("summary"))
            #expect(line.contains("without asking you first"))
            #expect(line.contains("as soon as you"), "says when it catches up")
        }
    }

    @Test func theNextOneSaysWhichDay() {
        #expect(BackgroundWords.nextDue(at(7), now: at(6), calendar: calendar, locale: Locale(identifier: "en_US"))
            .hasSuffix("today."))
        #expect(BackgroundWords.nextDue(at(7, days: 1), now: at(9), calendar: calendar, locale: Locale(identifier: "en_US"))
            .hasSuffix("tomorrow."))
    }

    /// The system refuses identifiers its Info.plist doesn't list, and the
    /// plist comes from project.yml.
    @Test func theIdentifiersAreListedForTheSystem() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        for id in [BackgroundIdentifiers.refresh, BackgroundIdentifiers.processing] {
            #expect(project.contains("- \(id)"), "project.yml doesn't list \(id)")
        }
        #expect(project.contains("BGTaskSchedulerPermittedIdentifiers:"))
        #expect(project.contains("UIBackgroundModes:"))
        #expect(project.contains("- fetch"))
        #expect(project.contains("- processing"))
    }
}
