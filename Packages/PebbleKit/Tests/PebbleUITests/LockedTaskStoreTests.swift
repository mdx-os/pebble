#if canImport(SwiftUI)
import Foundation
import PebbleBackground
import PebbleCore
import PebbleModel
import TestScratch
import Testing
@testable import PebbleUI

/// A clock the tests move by hand, for the engine and its rule.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var instant = ContinuousClock.now

    init(_ date: Date) { self.date = date }

    func now() -> Date { lock.withLock { date } }
    func instantNow() -> ContinuousClock.Instant { lock.withLock { instant } }

    func set(_ next: Date) {
        lock.withLock {
            instant += .milliseconds(Int64(next.timeIntervalSince(date) * 1000))
            date = next
        }
    }
}

/// The task store keeps full protection, so it opens only while the
/// device is unlocked. Background work never changes a task while it is
/// shut and writes none of a task's content anywhere else: a change waits
/// to be worked out again once it opens, and nothing is held in memory
/// meanwhile. The morning summary counts what the engine finished from the
/// store, and says so when it can't be opened.
@MainActor
@Suite(.scratchFiles)
struct LockedTaskStoreTests {
    /// The app's runner keeps the time where it runs.
    static let calendar = Calendar.current

    /// `hour` o'clock on a fixed day, `days` after it.
    static func at(_ hour: Int, days: Int = 0) -> Date {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        return calendar.date(byAdding: DateComponents(day: days, hour: hour), to: day)!
    }

    let folder: URL
    let notes: MemoryStore
    private let clock = HandClock(LockedTaskStoreTests.at(20, days: -1))
    let rule: AskFirst
    let toggle: FileBackgroundSwitch

    init() throws {
        folder = try #require(Scratch.folder)
        notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        rule = AskFirst.isolated(now: clock.instantNow)
        toggle = FileBackgroundSwitch(fileURL: folder.appendingPathComponent("background-switch.json"))
        try notes.remember("Dentist on Thursday at 3", at: clock.now() - 3_600, source: .toldMe)
        try notes.remember("Sam's birthday is May 14", at: clock.now() - 7_200, source: .toldMe)
    }

    var tasksFile: URL { folder.appendingPathComponent("tasks.json") }

    /// What the app opens at launch, as `PebbleApp` does: the one task
    /// store, the engine over it, and the runner wired to that engine.
    func launch(faults: TaskStoreFaults? = nil) throws -> (TaskStore, DeviceTaskEngine, BackgroundRunner) {
        let store = TaskStore(fileURL: tasksFile, forgetMarker: folder.appendingPathComponent("pending/tasks-forgotten"),
                              faults: faults)
        let engine = OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, store: store, rule: rule,
                                          pace: nil, clock: clock.now)
        let wiring = BackgroundWiring.app(
            needsYou: NeedsYou(rule: rule), tasks: engine,
            store: { BackgroundStore(fileURL: self.folder.appendingPathComponent("background.json")) },
            toggle: { self.toggle })
        let runner = try #require(wiring.service.runner)
        return (store, engine, runner)
    }

    /// Runs the digest to its question.
    func ask(_ engine: DeviceTaskEngine) throws -> (String, ConfirmationRequest) {
        let id = engine.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        let question = try #require(engine.tasks.first { $0.id == id }?.question)
        return (id, question)
    }

    /// Runs the digest and keeps it.
    func keep(_ engine: DeviceTaskEngine) throws {
        let (id, question) = try ask(engine)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw CancellationError() }
        #expect(engine.resume(id, with: approval) == .proceeding)
    }

    /// Every file in the folder, by path, with its bytes.
    func files() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let names = try #require(FileManager.default.subpathsOfDirectory(atPath: folder.path) as [String]?)
        for name in names {
            var isFolder: ObjCBool = false
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                continue
            }
            out[name] = try Data(contentsOf: url)
        }
        return out
    }

    /// The engine's tasks as the store's file holds them, by id and state.
    func onDisk() throws -> [String: String] {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tasksFile)) as? [String: Any])
        let device = json["device"] as? [String: Any]
        let tasks = device?["tasks"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            (task["id"] as? String).map { ($0, task["state"] as? String ?? "") }
        })
    }

    /// Turns work while away on the evening before, while unlocked.
    func turnOn(_ runner: BackgroundRunner) {
        runner.turnOn(now: clock.now())
    }

    /// A run the system gives while the app is closed and the screen is
    /// locked after the first unlock: the summary's file opens, the task
    /// store doesn't.
    static let lockedNight = BackgroundConditions(moment: .background, deadline: at(7, days: 0) + 20)

    // MARK: The owner's rule

    /// PERMANENT GUARD. A background run while the task store is shut
    /// makes no write to it, and no other file gets anything of a task's:
    /// the digest question that ran out overnight is not settled, the
    /// running engine changes nothing, and only the summary's own files,
    /// which hold counts, dates and kinds, change.
    @Test func aRunWhileTheStoreIsShutWritesNoTask() throws {
        let faults = TaskStoreFaults()
        let (store, engine, runner) = try launch(faults: faults)
        turnOn(runner)
        let (id, question) = try ask(engine)
        let shown = engine.tasks
        // The device locks with the question waiting, and stays locked
        // past the question's time and the morning.
        faults.shut = true
        let before = try files()
        clock.set(Self.at(7, days: 0) + 5)
        engine.refresh()
        engine.runPending()
        engine.questionClosed(question)
        runner.runDue(now: clock.now(), conditions: Self.lockedNight)

        let after = try files()
        #expect(after["tasks.json"] == before["tasks.json"], "no write to the task store")
        // A hidden file or one about tasks, in any folder.
        let taskish = { (path: String) in
            path.split(separator: "/").contains { $0.hasPrefix(".") } || path.contains("tasks")
        }
        #expect(Set(after.keys.filter(taskish)) == Set(before.keys.filter(taskish)), "no staged copy, no other task file")
        #expect(Set(after.keys).subtracting(before.keys).isSubset(of: ["background.json"]))
        for (name, data) in after where name != "tasks.json" && name != "memory.json" {
            let text = String(decoding: data, as: UTF8.self)
            for word in [id, "device-task", DigestTask.title, DigestWords.askLine, "Dentist", "Sam", question.id.uuidString] {
                #expect(!text.contains(word), "\(name) holds \(word)")
            }
        }
        #expect(engine.tasks == shown, "nothing changed in memory either, to write later")
        #expect(store.deviceTasks()?.file?.tasks.map(\.id) == [id])
        #expect(runner.results.count == 1, "the summary itself is still made")
    }

    /// PERMANENT GUARD. Once the device unlocks, what was put off is worked
    /// out again from what is there: the same engine settles the question
    /// that ran out, and the store shows it.
    @Test func afterUnlockTheChangeIsWorkedOutAgainAndWritten() throws {
        let faults = TaskStoreFaults()
        let (_, engine, _) = try launch(faults: faults)
        let (id, question) = try ask(engine)
        faults.shut = true
        clock.set(Self.at(7, days: 0))
        engine.refresh()
        #expect(try onDisk()[id] == TaskState.waitingOnYou.rawValue)
        faults.shut = false
        engine.refresh()
        #expect(rule.isClosed(question))
        let ended = try #require(engine.tasks.first { $0.id == id })
        #expect(ended.state == .done)
        #expect(ended.step == TaskWords.timedOut(DigestTask.saveTodo))
        #expect(try onDisk()[id] == TaskState.done.rawValue, "the store shows it")
    }

    /// PERMANENT GUARD. A launch killed between the locked run and the
    /// unlock loses nothing, since nothing waited in its memory: a fresh
    /// launch after the unlock works the change out from the store and
    /// writes it, and the notes are as they were.
    @Test func aLaunchKilledBeforeTheUnlockLosesNothing() throws {
        let faults = TaskStoreFaults()
        var first: (TaskStore, DeviceTaskEngine, BackgroundRunner)? = try launch(faults: faults)
        let (id, question) = try ask(try #require(first?.1))
        let notesBefore = notes.notes()
        faults.shut = true
        clock.set(Self.at(7, days: 0))
        first?.1.refresh()
        first?.1.questionClosed(question)
        first?.2.runDue(now: clock.now(), conditions: Self.lockedNight)
        #expect(try onDisk()[id] == TaskState.waitingOnYou.rawValue, "the locked run wrote nothing")
        // Killed while still locked.
        first = nil

        let (_, engine, runner) = try launch()
        let back = try #require(engine.tasks.first { $0.id == id })
        #expect(back.state == .stopped)
        #expect(back.step == DigestWords.stoppedWhenClosed)
        #expect(back.question == nil)
        #expect(try onDisk()[id] == TaskState.stopped.rawValue, "written once the store opened")
        #expect(notes.notes() == notesBefore, "nothing kept without a yes")
        #expect(rule.isClosed(question))
        // And it stays so: a later launch reads the same.
        let (_, again, _) = try launch()
        #expect(again.tasks.first { $0.id == id }?.updatedAt == back.updatedAt)
        _ = runner
    }

    /// PERMANENT GUARD. The task store is written with full protection,
    /// opened only while the device is unlocked. Only the summary's file
    /// opens from the first unlock on, and it holds counts, dates and kinds.
    @Test func theTaskStoreIsFullyProtectedAndOnlyTheSummaryIsNot() {
        let mask: Data.WritingOptions = [.completeFileProtection, .completeFileProtectionUnlessOpen,
                                         .completeFileProtectionUntilFirstUserAuthentication, .noFileProtection]
        #expect(TaskStore.fileWriting(protected: true).intersection(mask) == .completeFileProtection)
        #expect(BackgroundStore.fileProtection == .completeUntilFirstUserAuthentication)
        #expect(FileBackgroundSwitch.fileProtection == FileProtectionType.none)
    }

    // MARK: The morning summary

    /// A fresh launch in the morning, as the system's run usually is,
    /// counts the digests the engine finished overnight from the store:
    /// the one still on Today and the one whose card was put away.
    @Test func aFreshRunnerCountsTheDigestsThatFinished() throws {
        let (_, engine, runner) = try launch()
        turnOn(runner)
        try keep(engine)
        clock.set(Self.at(21, days: -1))
        let dismissed = try #require(engine.tasks.first)
        #expect(engine.dismiss(dismissed.id))
        try keep(engine)
        #expect(engine.tasks.map(\.state) == [.done])

        clock.set(Self.at(7, days: 0) + 5)
        let (_, _, fresh) = try launch()
        #expect(fresh.watchingSince > Self.at(19, days: -1), "a launch that watched none of the night")
        let made = fresh.runDue(now: clock.now(), conditions: Self.lockedNight)
        guard case .morningSummary(let summary)? = made.first?.content else {
            Issue.record("no summary")
            return
        }
        #expect(summary.finished == 2)
        #expect(summary.couldNotFinish == 0)
        #expect(!summary.tasksLocked)
        #expect(BackgroundWords.summaryBody(summary, now: clock.now(), calendar: Self.calendar)
            .contains("2 tasks finished overnight."))
    }

    /// With the store shut, nothing about tasks is counted, not even zero,
    /// and the card says why.
    @Test func aShutStoreIsSaidSoNotCountedAsNone() throws {
        let (_, engine, runner) = try launch()
        turnOn(runner)
        try keep(engine)

        clock.set(Self.at(7, days: 0) + 5)
        let (_, _, fresh) = try launch(faults: TaskStoreFaults(shut: true))
        let made = fresh.runDue(now: clock.now(), conditions: Self.lockedNight)
        guard case .morningSummary(let summary)? = made.first?.content else {
            Issue.record("no summary")
            return
        }
        #expect(summary.tasksLocked)
        #expect(summary.finished == nil)
        #expect(summary.couldNotFinish == nil)
        let body = BackgroundWords.summaryBody(summary, now: clock.now(), calendar: Self.calendar)
        #expect(body.contains(BackgroundWords.tasksLocked))
        #expect(!body.contains("finished overnight"))
        #expect(!body.contains(BackgroundWords.countedNothing))
        let detail = BackgroundWords.summaryDetail(summary, now: clock.now(), calendar: Self.calendar, locale: .current)
        #expect(detail.contains(BackgroundWords.tasksLocked))
    }

    // MARK: Forget everything

    /// One tap takes the notes, the engine's tasks, the asks, the receipts
    /// and the summaries, and says so. When the summaries and the tasks
    /// can't be erased, the line says that of both, never that they went.
    /// An earlier launch, gone now, that kept a digest and made a summary.
    func earlierLaunchKeptADigestAndASummary() throws {
        let (_, engine, runner) = try launch()
        turnOn(runner)
        try keep(engine)
        clock.set(Self.at(7, days: 0) + 5)
        #expect(runner.runDue(now: clock.now(), conditions: .foreground).count == 1)
    }

    @Test(.fileModesHoldOrCI, .failsAsRoot, arguments: [false, true])
    func forgetEverythingTakesEveryPartAndSaysWhatStayed(failing: Bool) throws {
        try earlierLaunchKeptADigestAndASummary()
        let marker = folder.appendingPathComponent("pending/tasks-forgotten")
        let device = TaskStore(fileURL: tasksFile, forgetMarker: marker).deviceTasks()?.file
        #expect(device?.tasks.count == 1)
        // And the Needs you flow kept an ask and a receipt beside it.
        let ask = SavedTask(id: "task:dentist", title: "Find a dentist near you open Saturdays", step: 1,
                            phase: .waiting, askedAt: clock.now() - 60, startedAt: clock.now() - 120)
        let receipt = Receipt(action: ProposedAction(kind: .sharePersonalInfo,
                                                     recipient: Recipient(id: "maple", displayName: "Maple Dental",
                                                                          handle: "hello@mapledental.example"),
                                                     details: "Your name and phone number"),
                              taskTitle: ask.title, approvedAt: clock.now() - 600, endedAt: clock.now() - 590,
                              outcome: .done, isSample: false)
        var state = TaskStore.State(tasks: [ask], receipts: [receipt])
        state.device = device
        try JSONEncoder().encode(state).write(to: tasksFile)

        // This launch, as the app wires it.
        let reopened = TaskStore(fileURL: tasksFile, forgetMarker: marker)
        let fresh = OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, store: reopened,
                                         rule: rule, pace: nil, clock: clock.now)
        let summaries = BackgroundStoreFaults(eraseFails: failing)
        let background = BackgroundRunner(
            store: BackgroundStore(fileURL: folder.appendingPathComponent("background.json"), faults: summaries),
            toggle: toggle, needsYou: NeedsYou(rule: rule), tasks: fresh)
        #expect(reopened.tasks.map(\.id) == [ask.id])
        #expect(reopened.receipts.map(\.id) == [receipt.id])
        #expect(!fresh.tasks.isEmpty)
        #expect(!background.results.isEmpty)
        let flow = NeedsYouFlow(store: reopened, notifier: nil, agentName: { "Pip" })
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: fresh,
                             place: .onDevice, flow: flow, background: background)
        let memory = HomeView.memoryModel(store: notes, place: .onDevice, background: background,
                                          onForgetEverything: { feed.forgetEverything() },
                                          othersStored: { feed.tasksStored })
        if failing {
            // The task store's folder won't let its file go either.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        memory.forgetEverything()

        #expect(fresh.tasks.isEmpty)
        #expect(reopened.tasks.isEmpty)
        #expect(reopened.receipts.isEmpty)
        #expect(background.results.isEmpty)
        #expect(!background.isOn)
        let status = try #require(memory.status)
        if failing {
            #expect(status.contains(TaskWords.tasksStayed), "\(status)")
            #expect(status.hasSuffix("again in a moment."), "\(status)")
            #expect(status.components(separatedBy: "again in a moment").count == 2, "asked once: \(status)")
            #expect(status.contains("couldn't erase your morning summaries"), "\(status)")
            #expect(!status.hasPrefix(MemoryWords.forgotten), "\(status)")
            // Once the folder lets go again, a fresh launch finds nothing
            // that went, or still offers Forget everything for what stayed.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            let next = TaskStore(fileURL: tasksFile, forgetMarker: marker)
            let again = OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, store: next, rule: rule,
                                             pace: nil, clock: clock.now)
            let nothingBack = next.tasks.isEmpty && next.receipts.isEmpty && next.deviceTasks()?.file == nil
                && again.tasks.isEmpty
            let feedAgain = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: again,
                                      place: .onDevice, flow: NeedsYouFlow(store: next, notifier: nil, agentName: { "Pip" }))
            #expect(nothingBack || feedAgain.tasksStored, "what stayed came back with no Forget everything for it")
        } else {
            #expect(status == MemoryWords.forgotten)
            #expect(notes.notes().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: tasksFile.path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("background.json").path))
            let next = TaskStore(fileURL: tasksFile, forgetMarker: marker)
            #expect(next.tasks.isEmpty && next.receipts.isEmpty && next.deviceTasks()?.file == nil)
        }
    }

    // MARK: Before the first read

    /// PERMANENT GUARD. With no task file yet, a locked device still takes
    /// no change: the first task waits for the unlock like any other.
    @Test func withNoFileYetALockedDeviceTakesNoChange() throws {
        let faults = TaskStoreFaults(shut: true)
        let (store, engine, _) = try launch(faults: faults)
        #expect(!FileManager.default.fileExists(atPath: tasksFile.path))
        #expect(store.isShut)
        #expect(engine.start(DigestTask.request).isEmpty)
        #expect(engine.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tasksFile.path), "nothing written while locked")
        faults.shut = false
        #expect(!store.isShut)
        #expect(!engine.start(DigestTask.request).isEmpty)
        #expect(FileManager.default.fileExists(atPath: tasksFile.path))
    }

    /// The same found by trying, with no stand in: a file with the task
    /// store's protection that can't be made beside it means shut.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func withNoFileYetAFolderThatTakesNoFileIsShut() throws {
        let store = TaskStore(fileURL: tasksFile, forgetMarker: folder.appendingPathComponent("pending/tasks-forgotten"))
        #expect(!store.isShut)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(store.isShut)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".") }, "no probe left: \(names)")
    }

    /// A file an earlier version kept with less than full protection gets
    /// full protection once it is read. One that won't open is left alone.
    @Test func aFileWithLessProtectionGetsFullProtectionOnceRead() throws {
        try earlierLaunchKeptADigestAndASummary()
        let marker = folder.appendingPathComponent("pending/tasks-forgotten")
        let faults = TaskStoreFaults(shut: true, protection: .completeUntilFirstUserAuthentication)
        let store = TaskStore(fileURL: tasksFile, forgetMarker: marker, faults: faults)
        #expect(store.deviceTasks() == nil)
        #expect(faults.protection == .completeUntilFirstUserAuthentication)
        faults.shut = false
        #expect(store.deviceTasks()?.file?.tasks.count == 1)
        #expect(faults.protection == .complete)
    }

    /// A start tapped after the unlock, before anything else read the
    /// store, reads it first and starts. One the store still refuses says
    /// so on Today rather than vanish.
    @Test func aStartBeforeTheLateReadReadsFirstOrSaysItCouldNot() throws {
        try earlierLaunchKeptADigestAndASummary()
        let faults = TaskStoreFaults(shut: true)
        let (_, engine, _) = try launch(faults: faults)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: engine,
                             place: .onDevice)
        var heard: [TaskAnnouncer.Line] = []
        feed.announce = { heard.append($0) }
        feed.start(DigestTask.request)
        #expect(engine.tasks.isEmpty)
        #expect(feed.couldNotStart == TaskWords.couldNotStart)
        #expect(heard.map(\.text) == [TaskWords.couldNotStart])
        faults.shut = false
        feed.start(DigestTask.request)
        #expect(feed.couldNotStart == nil)
        #expect(engine.tasks.contains { $0.isActive && $0.title == DigestTask.title })
        #expect(engine.tasks.contains { $0.state == .done }, "the earlier launch's digest came back too")
    }

    /// Counting the endings may be the first read after an unlock. It is
    /// a change like any other: observers hear the tasks that came back,
    /// and a question an earlier engine left open for them is withdrawn.
    @Test func countingTheEndingsAfterAnUnlockIsAChangeLikeAnyOther() throws {
        let (_, first, _) = try launch()
        let (id, question) = try ask(first)
        let faults = TaskStoreFaults(shut: true)
        let (_, second, _) = try launch(faults: faults)
        #expect(second.tasks.isEmpty)
        let heard = Snapshots()
        let watch = second.observe { heard.add($0) }
        defer { watch.cancel() }
        faults.shut = false
        guard case .kept = second.endings else {
            Issue.record("not counted")
            return
        }
        #expect(rule.isClosed(question))
        #expect(heard.last?.tasks.first { $0.id == id }?.state == .stopped)
        #expect(try onDisk()[id] == TaskState.stopped.rawValue)
        _ = first
    }

    /// A note forgotten while the task store is shut can't be looked for,
    /// so it is never called gone. Its line goes once the store opens.
    @Test func aNoteForgottenWhileTheStoreIsShutIsNeverCalledGone() throws {
        let faults = TaskStoreFaults()
        let (_, engine, _) = try launch(faults: faults)
        try keep(engine)
        faults.shut = true
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .mayHaveStayed)
        #expect(notes.notes().contains { $0.text.contains("Sam's birthday") })
        faults.shut = false
        engine.refresh()
        #expect(!notes.notes().contains { $0.text.contains("Sam's birthday") })
        #expect(notes.notes().contains { $0.text == DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)" })
    }
}

/// Every snapshot an observer was told, from any thread.
private final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TaskSnapshot] = []

    func add(_ snapshot: TaskSnapshot) { lock.withLock { all.append(snapshot) } }
    var last: TaskSnapshot? { lock.withLock { all.last } }
}
#endif
