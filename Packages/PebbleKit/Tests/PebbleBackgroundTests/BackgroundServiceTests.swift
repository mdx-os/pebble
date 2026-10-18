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
        let asks = oneWaiting()
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: asks,
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        let scheduler = RecordingScheduler()
        let service = BackgroundService(runner: runner, scheduler: scheduler, clock: { at(7, 1) })
        let conditions = BackgroundConditions.background(store: store, lowPower: false, deadline: at(7, 1) + 20)
        #expect(!conditions.fileShut)
        #expect(service.run(now: at(7, 1), conditions: conditions, time: BackgroundTime()))
        #expect(runner.results.count == 1)
        #expect(scheduler.asks.last == at(7, days: 1), "asks for tomorrow before it can be suspended")

        // The next morning, with time enough: the system taking its time
        // back is all that differs between the two runs below, so the one
        // out of time fails for that and nothing else.
        let tomorrow = at(7, 1, days: 1)
        let enough = BackgroundConditions.background(store: store, lowPower: false, deadline: tomorrow + 20)
        let cards = runner.results
        let queued = runner.queue
        let time = BackgroundTime()
        time.timeIsUp()
        #expect(!service.run(now: tomorrow, conditions: enough, time: time), "out of time, it says so to the system")
        #expect(runner.results == cards, "no half made card")
        #expect(runner.queue.map(\.due) == queued.map(\.due), "the morning's job still waits")
        #expect(runner.queue.first?.held == .outOfTime)
        #expect(!scheduler.asks.isEmpty)

        _ = asks.ask(ProposedAction(kind: .send, recipient: Recipient(id: "contact:sam", displayName: "Sam",
                                                                      handle: "sam@example.com"),
                                    details: "See you at 5"), at: at(6, 50, days: 1))
        #expect(service.run(now: tomorrow + 60, conditions: BackgroundConditions.background(
            store: store, lowPower: false, deadline: tomorrow + 80), time: BackgroundTime()), "with its time, it runs")
        #expect(runner.results.count == cards.count + 1)
        #expect(runner.queue.first?.due == at(7, days: 2))
    }

    /// Forget everything turns work while away off, and that means no more
    /// asks to be woken: the ask is cancelled, and none is made again.
    @Test(.timeLimit(.minutes(1))) func forgetEverythingCancelsTheWake() async throws {
        let store = scratchStore()
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: oneWaiting(),
                                      watchingSince: .distantPast, calendar: calendar)
        runner.turnOn(now: at(6))
        let scheduler = RecordingScheduler()
        let service = BackgroundService(runner: runner, scheduler: scheduler, clock: { at(6, 30) })
        service.start()
        #expect(scheduler.asks == [at(7)])
        #expect(scheduler.cancels == 0)

        try runner.forget()
        // The service hears of it on a later turn of the main actor. A
        // service that never hears ends the wait at the time limit.
        while scheduler.cancels == 0, !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
        #expect(scheduler.cancels == 1)
        #expect(scheduler.asks == [at(7)], "nothing asked since")
        #expect(!service.run(now: at(7, 1), conditions: BackgroundConditions.background(
            store: store, lowPower: false, deadline: at(7, 1) + 20), time: BackgroundTime()))
        #expect(scheduler.asks == [at(7)], "a wake that still comes asks for none")
    }

    /// The service finds the lock by trying the file, through the one
    /// helper the tests drive, and nothing in PebbleBackground, the runner,
    /// or the app's own sources, where the system's task arrives, reads the
    /// screen or protected data.
    @Test func theServiceNeverReadsTheScreenForTheLock() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let sources = root.appendingPathComponent("Packages/PebbleKit/Sources")
        let target = try SwiftSource.files(under: sources.appendingPathComponent("PebbleBackground"))
        #expect(target.map(\.name).contains("BackgroundService.swift"), "the sweep sees the target")
        let app = try SwiftSource.files(under: root.appendingPathComponent("App/Sources"))
        #expect(app.map(\.name).contains("PebbleApp.swift"), "the sweep sees the app")
        let runner = try String(contentsOf: sources.appendingPathComponent("PebbleCore/Background.swift"),
                                encoding: .utf8)
        for (name, text) in target.map({ ("PebbleBackground/" + $0.name, $0.text) }) + [("Background", runner)]
            + app.map({ ("App/" + $0.name, $0.text) }) {
            let code = String(SwiftSource(text).code)
            for screen in ["isProtectedDataAvailable", "protectedDataWillBecomeUnavailable",
                           "protectedDataDidBecomeAvailable", "applicationState"] {
                #expect(!code.contains(screen), "\(screen) in \(name)")
            }
        }
        let service = try #require(target.first { $0.name == "BackgroundService.swift" })
        #expect(service.text.contains(".background(store:"))
    }

    /// A Release build never reads the seed: its whole file is Debug only,
    /// and nothing outside `#if DEBUG` in the app or the packages names it
    /// or its launch argument.
    @Test func releaseIgnoresTheSeed() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let sources = root.appendingPathComponent("Packages/PebbleKit/Sources")
        let seed = try String(contentsOf: sources.appendingPathComponent("PebbleBackground/BackgroundSeed.swift"),
                              encoding: .utf8)
        let lines = seed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.first == "#if DEBUG")
        #expect(lines.last == "#endif")
        #expect(lines.filter { $0.hasPrefix("#") }.count == 2, "one block, with no #else")

        let files = try SwiftSource.files(under: root.appendingPathComponent("App/Sources")).map { ("App/" + $0.name, $0.text) }
            + SwiftSource.files(under: sources).map { ($0.name, $0.text) }
        var named = 0
        for (name, text) in files where name != "PebbleBackground/BackgroundSeed.swift" {
            named += text.contains("BackgroundSeed") ? 1 : 0
            let release = Self.outsideDebug(String(SwiftSource(text).code))
            #expect(!release.contains("BackgroundSeed"), "\(name) reads the seed outside #if DEBUG")
            #expect(!SwiftSource(text).literals.contains { $0.text.contains(Self.seedKey) },
                    "\(name) spells the seed's launch argument")
        }
        #expect(named > 0, "the app does read it in Debug")
    }

    /// The seed's launch argument, written here so this file builds in
    /// Release, where the seed isn't. `theSeedKeyIsTheSeeds` pins it.
    static let seedKey = "pebbleBackgroundSeed"

    #if DEBUG
    @Test func theSeedKeyIsTheSeeds() {
        #expect(Self.seedKey == BackgroundSeed.launchKey)
    }
    #endif

    /// The lines of `code` a Release build compiles: everything but the
    /// `#if DEBUG` branches. Other conditions are taken as compiled. Each
    /// directive is read without what trails it, so `#if DEBUG // why`
    /// is `#if DEBUG`.
    static func outsideDebug(_ code: String) -> String {
        var stack: [Bool] = []
        var kept: [Substring] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(whereSeparator: \.isWhitespace)
            let directive = words.first.map(String.init) ?? ""
            let condition = words.dropFirst().first.map(String.init)
            switch directive {
            case "#if":
                stack.append(condition == "DEBUG" && words.count == 2)
            case "#elseif":
                // A later branch of `#if DEBUG` is compiled where DEBUG isn't.
                if !stack.isEmpty { stack[stack.count - 1] = false }
            case "#else":
                // The other branch of `#if DEBUG` is what Release compiles.
                if !stack.isEmpty { stack[stack.count - 1] = false }
            case "#endif":
                _ = stack.popLast()
            default:
                if !stack.contains(true) { kept.append(line) }
            }
        }
        return kept.joined(separator: "\n")
    }

    /// The reading of directives, on the forms it has to tell apart.
    @Test func outsideDebugReadsEachDirective() {
        let code = """
            a
            #if DEBUG
            b
            #elseif os(iOS)
            c
            #else
            d
            #endif
            #if DEBUG
            e
            #endif
            #if DEBUG && os(iOS)
            f
            #endif
            g
            """
        let kept = Self.outsideDebug(String(SwiftSource(code + "\n#if DEBUG // a reason\nh\n#endif").code))
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(kept == ["a", "c", "d", "f", "g"])
    }

    #if DEBUG
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

        // Opened again, it keeps what the launch before kept, and seeds nothing.
        seeded.toggle.set(true)
        try seeded.store.save(.empty)
        defaults.set("again", forKey: BackgroundSeed.launchKey)
        let again = try #require(BackgroundSeed.launched(defaults: defaults, folder: folder))
        #expect(again.toggle.isOn)
        #expect(try again.store.load() == .empty, "nothing seeded over it")

        defaults.removeObject(forKey: BackgroundSeed.launchKey)
        #expect(BackgroundSeed.launched(defaults: defaults, folder: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
    #endif
}
