#if canImport(SwiftUI)
import Combine
import Foundation
import PebbleBackground
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import TestScratch
import Testing
@testable import PebbleUI

/// Stands in for the system's notifications, for Forget everything: holds
/// the nudges still to show, and counts the forgets that reach it.
private final class ForgetNotifier: QuestionNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String]
    private var forgot = 0

    init(waiting: [String]) { held = waiting }

    var waiting: [String] { lock.lock(); defer { lock.unlock() }; return held }
    var forgets: Int { lock.lock(); defer { lock.unlock() }; return forgot }

    func permission() async -> NudgePermission { .notDetermined }
    func requestPermission() async -> Bool { false }
    func post(_ nudge: QuestionNudge, after delay: TimeInterval) {
        lock.lock(); held.append(nudge.id); lock.unlock()
    }
    func remove(_ ids: [String]) { lock.lock(); held.removeAll { ids.contains($0) }; lock.unlock() }
    func removeAll() { lock.lock(); held = []; lock.unlock() }
    func forget() { lock.lock(); held = []; forgot += 1; lock.unlock() }
    func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {}
}

/// Background work as Today and the memory screen show it: the cards it
/// leaves, the catch up when the app opens, the switch, and Forget everything.
@MainActor
@Suite(.scratchFiles)
struct BackgroundFeedTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }

    static let note = ProposedAction(kind: .send,
                                     recipient: Recipient(id: "c:1", displayName: "Sam", handle: "sam@example.com"),
                                     details: "See you at 4")

    /// Needs you with one question open, so a summary has something to
    /// say: a quiet morning leaves no card.
    static func oneWaiting() -> NeedsYou {
        let asks = NeedsYou(rule: .isolated())
        asks.ask(note, at: at(6, 50))
        return asks
    }

    private func scratchStore(faults: BackgroundStoreFaults? = nil) -> BackgroundStore {
        BackgroundStore(fileURL: Scratch.url("background-ui"), faults: faults)
    }

    private func runner(on: Bool, needsYou: NeedsYou? = BackgroundFeedTests.oneWaiting(),
                        store: BackgroundStore? = nil) -> BackgroundRunner {
        let runner = BackgroundRunner(store: store ?? scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                      needsYou: needsYou, watchingSince: .distantPast, calendar: Self.calendar)
        if on { runner.turnOn(now: Self.at(6)) }
        return runner
    }

    /// Today's model, in front unless a test says otherwise, as the scene
    /// tells it once it is active.
    private func model(_ runner: BackgroundRunner, needsYou: NeedsYou = NeedsYou(rule: .isolated()),
                       inFront: Bool = true, now: @escaping () -> Date) -> FeedModel {
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: needsYou, place: .onDevice, background: runner,
                              calendar: Self.calendar, now: now)
        model.inFront = inFront
        return model
    }

    private func scratchMemory() -> MemoryStore {
        MemoryStore(fileURL: Scratch.url("memory-ui"))
    }

    /// The system may never wake the app. Opening it makes the summary
    /// that was due, and it shows in Today at once.
    @Test func openingTheAppCatchesUpOnASummaryThatWasDue() throws {
        let runner = runner(on: true)
        var now = Self.at(6, 30)
        let model = model(runner) { now }
        model.refresh()
        #expect(model.feed.isEmpty, "not due yet")

        now = Self.at(8, 15)
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        #expect(card.title == BackgroundWords.summaryTitle)
        #expect(card.kind == .ready)
        #expect(!model.isSample(card))
    }

    /// Away from the screen, Today's refresh leaves background work to the
    /// platform's own run, which knows if the device is locked. A fresh
    /// model counts as away until the scene says it is active, since a
    /// scene may be built during a launch in the background.
    @Test func todayRunsNothingUntilTheSceneIsActive() async {
        let runner = runner(on: true)
        let fresh = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: .isolated()), place: .onDevice,
                              background: runner, calendar: Self.calendar, now: { Self.at(8) })
        #expect(!fresh.inFront)
        fresh.refresh()
        // The loop that keeps Today fresh refreshes at once, and runs nothing either.
        let loop = Task { await fresh.keepFresh(sleep: { _ in throw CancellationError() }) }
        await loop.value
        #expect(runner.results.isEmpty)
        #expect(runner.queue.first?.held == nil, "nothing claimed as held for a run it never tried")

        fresh.inFront = true
        fresh.refresh()
        #expect(runner.results.count == 1)
    }

    /// While nothing has been made, Today's empty words are still the
    /// ones it always says, and they stay true: nothing here claims work
    /// done in the background until a card shows it.
    @Test func theEmptyWordsStayTrueUntilACardIsMade() {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(6) }
        #expect(model.feed.isEmpty)
        #expect(FeedWords.empty == "It's just us for now. Write to me below, and I'll answer in the chat.")
        runner.runDue(now: Self.at(7), conditions: .foreground)
        model.refresh()
        #expect(!model.feed.isEmpty, "a real card, so the empty words are no longer shown")
    }

    /// A summary with something in it opens to read, in the usual reader.
    @Test func aSummaryWithSomethingInItOpensToRead() throws {
        let asks = Self.oneWaiting()
        let runner = runner(on: true, needsYou: asks)
        let model = model(runner, needsYou: asks) { Self.at(7, 5) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        #expect(card.kind == .ready)
        model.perform(card) { _ in }
        #expect(model.reading?.id == card.id)
        #expect(model.feed.needsYou.count == 1, "the question still waits for its answer")
    }

    /// A save cut short leaves a staged copy beside the file. Forget
    /// everything has to erase it too.
    private func leaveAStagedCopy(_ store: BackgroundStore) throws {
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        #expect(FileManager.default.fileExists(atPath: store.stagingURL.path))
    }

    private func expectNoSummaryFiles(_ store: BackgroundStore, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!store.hasStoredFile, sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path), sourceLocation: sourceLocation)
    }

    /// Forget everything turns background work off and its cards go.
    @Test func forgetEverythingClearsTheCardsAndTurnsItOff() throws {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(9) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        model.perform(card) { _ in }
        try leaveAStagedCopy(runner.store)

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner,
                                 now: { Self.at(9) }, onForgetEverything: { model.forgetEverything() })
        #expect(memory.backgroundOn)
        memory.forgetEverything()
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(model.feed.isEmpty)
        #expect(model.reading == nil)
        #expect(!memory.backgroundOn)
        #expect(memory.backgroundNext == nil)
        // Today refreshing later never makes another.
        model.refresh()
        #expect(model.feed.isEmpty)
    }

    /// With no notes at all, morning summaries can still be removed: Forget
    /// everything shows while background work has a file or cards, and
    /// goes once they are gone.
    @Test func forgetEverythingShowsForSummariesWithoutNotes() throws {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.hasStoredFile)
        #expect(!memory.hasSomethingToForget, "nothing here yet")

        memory.setBackground(true)
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        memory.setBackground(false)
        memory.refresh()
        #expect(!runner.results.isEmpty, "turning off keeps the cards")
        #expect(!memory.hasStoredFile)
        #expect(memory.hasSomethingToForget)
        try leaveAStagedCopy(runner.store)

        memory.forgetEverything()
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(!memory.hasSomethingToForget)
        #expect(memory.status == MemoryWords.forgotten)
    }

    /// Forget everything goes in one order, each step whatever the one
    /// before did: background work first, so its questions are withdrawn
    /// and nothing runs while the rest goes, then the tasks, the notes and
    /// the private words.
    @Test func forgetEverythingGoesInOrder() throws {
        let notes = scratchMemory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let log = StepLog(notes: notes)
        let asks = Self.oneWaiting()
        let runner = runner(on: true, needsYou: asks)
        let proposed = runner.propose(Self.note, conditions: .foreground, at: Self.at(9), act: {})
        let asked = try #require(proposed)
        // However often the runner tells its watchers, and from whichever
        // turn, "background" is logged once: the first time its question
        // is seen withdrawn.
        let heard = Counter()
        let watch = runner.observe {
            heard.add()
            if asks.rule.wasWithdrawn(asked) { log.stepOnce("background") }
        }
        defer { runner.stopObserving(watch) }
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { log.step("private words"); return .privateWords },
                                 background: runner, now: { Self.at(9) },
                                 onForgetEverything: {
                                     #expect(heard.value > 0, "the runner told its watchers before the tasks went")
                                     log.step("tasks")
                                     return .none
                                 })
        memory.forgetEverything()
        log.step("done")
        #expect(log.steps == ["background", "tasks", "notes", "private words", "done"])
    }

    /// Another window's Today with a summary open to read: Forget
    /// everything in this window takes its card away, and the open summary
    /// closes with it there too.
    @Test func anOpenSummaryInAnotherWindowClosesOnForget() async throws {
        let runner = runner(on: true)
        let other = model(runner) { Self.at(9) }
        other.refresh()
        let card = try #require(other.feed.groups.first?.items.first)
        other.perform(card) { _ in }
        #expect(other.reading?.id == card.id)

        let here = model(runner) { Self.at(9) }
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner,
                                 now: { Self.at(9) }, onForgetEverything: { here.forgetEverything() })
        memory.forgetEverything()
        await other.settled()
        #expect(other.reading == nil, "closed in the other window too")
        #expect(other.feed.isEmpty)
    }

    /// A card from somewhere else stays open: only a summary whose card
    /// went closes.
    @Test func onlyAGoneSummaryCloses() async throws {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(9) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        model.perform(card) { _ in }
        runner.turnOff()
        await model.settled()
        #expect(model.reading?.id == card.id, "turning off keeps the cards, so it stays open")
        #expect(card.id.hasPrefix(BackgroundFeed.idPrefix))
        // Today's code names the prefix only through `BackgroundFeed`.
        let feedView = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/FeedView.swift"), encoding: .utf8)
        #expect(!SwiftSource(feedView).literals.contains { $0.text.hasPrefix("background") })
    }

    /// The question before Forget everything names work while away only
    /// while it is on or has summaries to erase, so it promises only what
    /// the tap will do. The screen asks it with that.
    @Test func theForgetQuestionNamesWorkWhileAwayOnlyWhenThereIsSome() throws {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.forgetNamesBackground, "off, with nothing stored")
        memory.setBackground(true)
        #expect(memory.forgetNamesBackground, "on")
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        memory.setBackground(false)
        #expect(memory.forgetNamesBackground, "off, but with summaries to erase")
        memory.forgetEverything()
        #expect(!memory.forgetNamesBackground)
        #expect(MemoryView.forgetEverythingDetail(for: nil, background: memory.forgetNamesBackground)
            == MemoryWords.forgetEverythingDetail(background: false))

        let view = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/MemoryView.swift"), encoding: .utf8)
        let code = String(SwiftSource(view).code)
        #expect(code.contains("ForgetEverythingDialog(cloud: cloud, background: model.forgetNamesBackground"))
    }

    /// The showcase's screen after Forget everything couldn't erase the
    /// summaries runs a real Forget everything, so it shows what that
    /// leaves: work while away off, its cards gone, Forget everything still
    /// there to try again, and the line for what went.
    @Test func theShowcaseShowsWhatAFailedForgetLeaves() {
        let (model, cloud) = ShowcaseScene.summariesStayedModel(at: ShowcaseScene.morning)
        #expect(model.background?.isOn == false)
        #expect(model.background?.results.isEmpty == true, "its cards went from memory")
        #expect(model.hasSomethingToForget, "the summaries stayed, so it can be tried again")
        #expect(model.notes.isEmpty)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(model.status == MemoryWords.couldNotForgetSummaries(notes: true, tasks: false, words: true))
    }

    /// With nothing of background work to forget, its summaries are not
    /// said to go, and nothing erased means no "forgotten" tap: the line
    /// and the tap agree.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func theForgottenTapNeedsSomethingErased() throws {
        let folder = Scratch.url("memory-ro").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let runner = runner(on: false)
        let memory = MemoryModel(store: notes, place: .onDevice, alsoForget: { throw CocoaError(.fileWriteNoPermission) },
                                 background: runner, now: { Self.at(9) })
        #expect(!memory.hasBackgroundToForget)
        memory.forgetEverything()
        #expect(memory.status == MemoryWords.couldNotForget)
        #expect(memory.forgottenCount == 0)

        // With cards to forget, they go, the line says so, and it taps.
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        memory.refresh()
        memory.forgetEverything()
        #expect(memory.status == MemoryModel.forgotLine(notesGone: false, rest: .some(nil), tasksGone: false,
                                                        summaries: .erased))
        #expect(memory.status?.contains(MemoryWords.summariesGone) == true)
        #expect(memory.forgottenCount == 1)
    }

    /// Turned on but never run, the file holds only the queue. Forget
    /// everything erases it, but no summary was made, so none is said to
    /// be gone. Once one was made, it is, even after an erase that failed
    /// took the cards from the screen first.
    @Test func aQueueAloneHasNoSummariesToSayAreGone() throws {
        let faults = BackgroundStoreFaults()
        let runner = runner(on: true, store: scratchStore(faults: faults))
        #expect(runner.store.hasStoredFile, "the queue is in the file")
        #expect(runner.results.isEmpty)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice,
                                 alsoForget: { throw CocoaError(.fileWriteNoPermission) },
                                 background: runner, now: { Self.at(9) })
        #expect(memory.hasSomethingToForget)
        memory.forgetEverything()
        #expect(memory.status == CloudWords.forgotNotesNotWords)
        #expect(memory.status?.contains(MemoryWords.summariesGone) == false)
        expectNoSummaryFiles(runner.store)

        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        faults.eraseFails = true
        memory.forgetEverything()
        #expect(runner.results.isEmpty, "the cards went from the screen")
        faults.eraseFails = false
        memory.forgetEverything()
        #expect(memory.status == MemoryModel.forgotLine(notesGone: true, rest: .some(nil), tasksGone: false,
                                                        summaries: .erased))
        #expect(memory.status?.contains(MemoryWords.summariesGone) == true)
    }

    /// If the summaries' file can't be erased, the line says so rather
    /// than read as done, and Forget everything stays to try again.
    @Test func aSummaryFileThatCantBeErasedIsSaid() throws {
        let faults = BackgroundStoreFaults()
        let toggle = InMemoryBackgroundSwitch()
        let asks = Self.oneWaiting()
        let runner = BackgroundRunner(store: scratchStore(faults: faults), toggle: toggle, needsYou: asks,
                                      watchingSince: .distantPast, calendar: Self.calendar)
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        #expect(toggle.nextDue != nil)
        let proposed = runner.propose(Self.note, conditions: .foreground, at: Self.at(9), act: {})
        let asked = try #require(proposed)
        #expect(runner.store.hasStoredFile)
        faults.eraseFails = true

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(memory.hasSomethingToForget)
        memory.forgetEverything()
        // Work while you're away is off and its cards are gone either way.
        #expect(!runner.isOn, "off even so")
        #expect(runner.results.isEmpty)
        #expect(runner.queue.isEmpty)
        #expect(toggle.nextDue == nil)
        #expect(asks.rule.wasWithdrawn(asked), "a yes on a sheet still open does nothing")
        #expect(!asks.items(now: Self.at(9)).contains { $0.request == asked })
        #expect(memory.status == MemoryWords.couldNotForgetSummaries(notes: false, tasks: false, words: false))
        #expect(memory.status == "I turned off work while you're away, but I couldn't erase "
                + "your morning summaries just now. Please try Forget everything again in a moment.",
                "no notes, no tasks and no hidden words went, so it names none")
        #expect(memory.hasSomethingToForget, "still there, so it can be tried again")

        faults.eraseFails = false
        memory.forgetEverything()
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!memory.hasSomethingToForget)
        expectNoSummaryFiles(runner.store)
    }

    /// The summaries go first, and when their file can't be erased every
    /// later step still runs: the note, the tasks and the private words all
    /// go, and the line says only the summaries stayed.
    @Test func aSummaryFileThatCantBeErasedStopsNothingElse() throws {
        let faults = BackgroundStoreFaults()
        let runner = runner(on: true, store: scratchStore(faults: faults))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        #expect(runner.store.hasStoredFile)
        faults.eraseFails = true

        let notes = scratchMemory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        #expect(!engine.tasks.isEmpty)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                             place: .onDevice, background: runner, calendar: Self.calendar, now: { Self.at(9) })
        var wordsForgotten = 0
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { wordsForgotten += 1; return .privateWords },
                                 background: runner, now: { Self.at(9) },
                                 onForgetEverything: { feed.forgetEverything() })
        memory.forgetEverything()

        #expect(runner.store.hasStoredFile, "the summaries' file stayed")
        #expect(notes.notes().isEmpty, "the note went")
        #expect(!notes.hasStoredFile)
        #expect(engine.tasks.isEmpty, "the tasks went")
        #expect(wordsForgotten == 1, "the private words step ran")
        #expect(memory.status == "I forgot your notes, tasks and any words you asked me to hide, and turned off work "
                + "while you're away, but I couldn't erase your morning summaries just now. Please try Forget "
                + "everything again in a moment.", "names everything that went")
        #expect(!runner.isOn)
    }

    /// Background work and Needs you, both with something kept on disk:
    /// the summaries' file and the switch's, and the saved tasks, receipts
    /// and a nudge still to show.
    private struct BothKept {
        let runner: BackgroundRunner
        let toggle: FileBackgroundSwitch
        let store: TaskStore
        let tasksURL: URL
        let notifier: ForgetNotifier
        let engine: LocalFakeEngine
        let feed: FeedModel
    }

    private func bothKept(faults: BackgroundStoreFaults? = nil) throws -> BothKept {
        let toggle = FileBackgroundSwitch(fileURL: Scratch.url("background-switch-ui"))
        let runner = BackgroundRunner(store: scratchStore(faults: faults), toggle: toggle, needsYou: Self.oneWaiting(),
                                      watchingSince: .distantPast, calendar: Self.calendar)
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        #expect(runner.store.hasStoredFile)
        #expect(FileManager.default.fileExists(atPath: toggle.fileURL.path))

        // A task said yes to, with its receipt, and a task still asking,
        // kept in Needs you's own file.
        let tasksURL = Scratch.url("tasks-ui")
        let store = TaskStore(fileURL: tasksURL, forgetMarker: Scratch.url("tasks-forgotten-ui"))
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.at(9))
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let question = try #require(engine.tasks.first?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw CancellationError() }
        _ = engine.resume(engine.tasks[0].id, with: approval)
        engine.advance(by: 4)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        store.keep(engine)
        #expect(!store.receipts.isEmpty)
        #expect(!store.tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tasksURL.path))
        let notifier = ForgetNotifier(waiting: ["a nudge still to show"])
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: { "Pip" })
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: engine,
                             place: .onDevice, flow: flow, background: runner, calendar: Self.calendar,
                             now: { Self.at(9) })
        return BothKept(runner: runner, toggle: toggle, store: store, tasksURL: tasksURL, notifier: notifier,
                        engine: engine, feed: feed)
    }

    /// PERMANENT GUARD. One Forget everything, from the memory screen as the
    /// home screen wires it, clears background work and everything Needs
    /// you keeps while the app is closed: the summaries and the switch's
    /// file, and the saved tasks, receipts and nudges.
    @Test func forgetEverythingClearsBackgroundWorkAndWhatNeedsYouKeeps() async throws {
        let kept = try bothKept()
        let notes = scratchMemory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let memory = HomeView.memoryModel(store: notes, place: .onDevice, background: kept.runner,
                                          onForgetEverything: { kept.feed.forgetEverything() })
        memory.forgetEverything()
        await kept.feed.settled()

        // Background work.
        #expect(!kept.runner.isOn)
        #expect(kept.runner.results.isEmpty)
        expectNoSummaryFiles(kept.runner.store)
        #expect(!FileManager.default.fileExists(atPath: kept.toggle.fileURL.path), "the switch's file went too")
        // Needs you.
        #expect(kept.store.receipts.isEmpty)
        #expect(kept.store.tasks.isEmpty)
        #expect(!kept.store.holdsSomething)
        #expect(!FileManager.default.fileExists(atPath: kept.tasksURL.path))
        #expect(kept.notifier.forgets == 1)
        #expect(kept.notifier.waiting.isEmpty, "no nudge is left to show")
        #expect(kept.engine.tasks.isEmpty)
        // And what the screens say.
        #expect(kept.feed.feed.isEmpty)
        #expect(!kept.feed.hasSomethingToForget)
        #expect(!memory.hasSomethingToForget)
        #expect(memory.status == MemoryWords.forgotten)
    }

    /// When the summaries' file can't be erased, Needs you's part still
    /// goes, and the line names both: what went, and that the summaries
    /// stayed.
    @Test func aSummaryFileThatCantBeErasedStillClearsWhatNeedsYouKeeps() async throws {
        let faults = BackgroundStoreFaults()
        let kept = try bothKept(faults: faults)
        faults.eraseFails = true
        let memory = HomeView.memoryModel(store: scratchMemory(), place: .onDevice, background: kept.runner,
                                          onForgetEverything: { kept.feed.forgetEverything() })
        memory.forgetEverything()
        await kept.feed.settled()

        #expect(kept.runner.store.hasStoredFile, "the summaries' file stayed")
        #expect(!kept.runner.isOn)
        #expect(kept.store.receipts.isEmpty)
        #expect(kept.store.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: kept.tasksURL.path))
        #expect(kept.notifier.waiting.isEmpty)
        #expect(memory.status == MemoryWords.couldNotForgetSummaries(notes: false, tasks: true, words: false))
        #expect(memory.hasSomethingToForget, "the summaries can be tried again")

        faults.eraseFails = false
        memory.forgetEverything()
        expectNoSummaryFiles(kept.runner.store)
        #expect(memory.status == MemoryWords.forgotten)
    }

    /// With the private words too, each step runs whatever the others did:
    /// the notes can't be erased here, but the summaries and the words go,
    /// and the line says exactly that.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func forgetEverythingSaysWhatWentWithTheWordsAndSummaries() throws {
        let folder = Scratch.url("memory-ro").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let runner = runner(on: true)
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        try leaveAStagedCopy(runner.store)
        var wordsForgotten = false
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { wordsForgotten = true; return .privateWords },
                                 background: runner, now: { Self.at(9) })
        memory.forgetEverything()
        #expect(memory.status == "Your private words are gone, but I couldn't erase your notes just now. "
                + MemoryWords.summariesGone + " Please try Forget everything again in a moment.")
        #expect(wordsForgotten)
        #expect(!runner.isOn)
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(notes.notes().count == 1)
    }

    /// Off until the person turns it on. On, it says when the next is due,
    /// and VoiceOver hears it, since that line appears away from the switch.
    @Test func theSwitchIsOffUntilTurnedOnAndSaysWhenTheNextIsDue() {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        var heard: [String] = []
        memory.announce = { heard.append($0) }
        #expect(!memory.backgroundOn)
        #expect(memory.backgroundNext == nil)

        memory.setBackground(true)
        #expect(runner.isOn)
        #expect(memory.backgroundOn)
        #expect(runner.queue.first?.due == Self.at(7, days: 1))
        let next = BackgroundWords.nextDue(Self.at(7, days: 1), now: Self.at(9))
        #expect(memory.backgroundNext == next)
        #expect(heard == [next])

        memory.setBackground(false)
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(memory.backgroundNext == nil)
        #expect(heard == [next], "nothing more to say when it turns off")
    }

    /// The line under the switch is said again while the screen stays
    /// open: at the due time, so "today" never stays up past it, and at
    /// midnight, when "tomorrow" becomes "today". The screen waits for that
    /// moment each time it moves.
    @Test func theNextLineFollowsTheClockWhileTheScreenIsOpen() async throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let morning = BackgroundPlan.morning(of: Date(), calendar: calendar)
        let runner = BackgroundRunner(store: scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                      needsYou: Self.oneWaiting(), watchingSince: .distantPast, calendar: calendar)
        var now = morning - 60 * 60
        runner.turnOn(now: now)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { now })
        #expect(memory.backgroundNext == BackgroundWords.nextDue(morning, now: now))
        #expect(memory.backgroundNextChange == morning)

        var slept: [TimeInterval] = []
        await memory.refreshBackgroundAtNextChange { seconds in
            slept.append(seconds)
            now += seconds
        }
        #expect(slept == [60 * 60])
        #expect(memory.backgroundNext == BackgroundWords.nextDue(morning, now: now))
        #expect(memory.backgroundNext?.hasSuffix("today.") == false, "never today once the time has come")

        // Late in the evening, after the morning's look, tomorrow is named
        // until midnight, then today.
        runner.runDue(now: now, conditions: .foreground)
        let tomorrow = try #require(runner.queue.first?.due)
        now = calendar.startOfDay(for: tomorrow) - 60
        memory.refreshBackground()
        #expect(memory.backgroundNext?.hasSuffix("tomorrow.") == true)
        #expect(memory.backgroundNextChange == calendar.startOfDay(for: tomorrow))
        await memory.refreshBackgroundAtNextChange { now += $0 }
        #expect(memory.backgroundNext?.hasSuffix("today.") == true)
        #expect(memory.backgroundNextChange == tomorrow)

        let view = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/MemoryView.swift"), encoding: .utf8)
        let code = String(SwiftSource(view).code)
        #expect(code.contains(".task(id: model.backgroundNextChange) { await model.refreshBackgroundAtNextChange() }"))
        #expect(code.contains(".task(id: model.setting.nextChange) { await model.refreshAtNextChange() }"))
    }

    /// With no notes store, the screen shown in its place still has the
    /// switch and a way to forget the summaries whenever a runner was
    /// built: they keep their own file. Forgetting them there turns work
    /// while away off, erases the file and says so, and leaves the tasks.
    @Test func withNoNotesTheSwitchAndTheSummariesStay() throws {
        let faults = BackgroundStoreFaults()
        let runner = runner(on: false, store: scratchStore(faults: faults))
        let setting = BackgroundSettingModel(runner: runner, now: { Self.at(6) })
        var heard: [String] = []
        setting.announce = { heard.append($0) }
        #expect(!setting.setting.isOn)
        #expect(!setting.setting.hasSomethingToForget)

        setting.set(true)
        #expect(runner.isOn)
        let next = BackgroundWords.nextDue(Self.at(7), now: Self.at(6))
        #expect(setting.setting.next == next)
        #expect(heard == [next])
        runner.runDue(now: Self.at(7), conditions: .foreground)
        setting.refresh()
        #expect(setting.setting.hasSomethingToForget)

        faults.eraseFails = true
        setting.forget()
        #expect(!runner.isOn)
        #expect(setting.status == MemoryWords.couldNotForgetSummariesAlone)
        #expect(setting.forgottenCount == 0)
        #expect(setting.setting.hasSomethingToForget, "still there to try again")
        faults.eraseFails = false
        setting.forget()
        #expect(setting.status == MemoryWords.summariesGone)
        #expect(setting.forgottenCount == 1)
        #expect(!setting.setting.hasSomethingToForget)
        expectNoSummaryFiles(runner.store)
        #expect(heard.suffix(2) == [MemoryWords.couldNotForgetSummariesAlone, MemoryWords.summariesGone])

        // The home screen hands its runner to the screen with no notes,
        // which shows the section whenever it has one.
        let root = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI")
        let home = SwiftSource(try String(contentsOf: root.appendingPathComponent("HomeView.swift"), encoding: .utf8))
        let fallback = try #require(home.calls(named: ["MemoryUnavailableView"]).first)
        #expect(fallback.arguments.contains("background: background"))
        let memory = String(SwiftSource(try String(contentsOf: root.appendingPathComponent("MemoryView.swift"),
                                                   encoding: .utf8)).code)
        let shown = try #require(memory.range(of: "if let background {"), "shown whenever there is a runner")
        #expect(memory[shown.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("BackgroundFallbackSection(model: BackgroundSettingModel(runner: background))"))
        try smokeRender(MemoryUnavailableView(hasTasks: true, background: runner, onForgetTasks: {})
            .frame(width: 393, height: 852))
    }

    /// The app wires no task engine yet, so the line under the switch, read
    /// as the person turns it on, doesn't promise what finished. With an
    /// engine, it does. The app's wiring comes from `BackgroundWiring.app`,
    /// the same factory this reads.
    @Test func theSwitchPromisesWhatFinishedOnlyWithTasksToCount() throws {
        let store = scratchStore()
        defer { try? store.forget() }
        let asks = NeedsYou(rule: .isolated())
        let wiring = BackgroundWiring.app(needsYou: asks, store: { store }, toggle: { InMemoryBackgroundSwitch() })
        #expect(wiring.tasks == nil, "the app wires no engine yet")
        let wired = try #require(wiring.service.runner)
        #expect(wired.tasks == nil, "the runner counts the same tasks as Today")
        #expect(wired.needsYou === asks)
        let asTheAppHasIt = MemoryModel(store: scratchMemory(), place: .onDevice, background: wired)
        #expect(!asTheAppHasIt.backgroundDetail.contains("finished"))
        #expect(asTheAppHasIt.backgroundDetail
            == BackgroundWords.settingDetail(whileClosed: BackgroundRow.runsWhileClosed, countsTasks: false))

        let rule = AskFirst.isolated()
        let withTasks = BackgroundRunner(store: scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                         needsYou: NeedsYou(rule: rule), tasks: LocalFakeEngine(rule: rule))
        let counting = MemoryModel(store: scratchMemory(), place: .onDevice, background: withTasks)
        #expect(counting.backgroundDetail.contains("what finished overnight"))
    }

    /// The memory screen follows the runner: turned on in another window,
    /// or a card made in Today, it shows here without waiting to come back.
    @Test(.timeLimit(.minutes(1))) func theMemoryScreenFollowsTheRunner() async {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.backgroundOn)
        #expect(!memory.hasSomethingToForget)

        // Another window turns it on and Today makes a card. The screen
        // hears of it on a later turn of the main actor; this waits for
        // that, however long the machine takes.
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        var watch: AnyCancellable?
        await withCheckedContinuation { (heard: CheckedContinuation<Void, Never>) in
            watch = memory.$hasBackgroundToForget.first { $0 }.sink { _ in heard.resume() }
        }
        watch?.cancel()
        #expect(memory.backgroundOn)
        #expect(memory.backgroundNext != nil)
        #expect(memory.hasSomethingToForget)
    }

    /// VoiceOver reads a summary or missed card as one thought, and the
    /// body is in it, not only the title: the detail behind the card is
    /// for reading, the body is what the card says.
    @Test func theCardsSpokenTextIncludesItsBody() {
        let summary = BackgroundResult(madeAt: Self.at(7), content: .morningSummary(MorningSummary(
            waiting: 1, finished: nil, couldNotFinish: nil, since: Self.at(19, days: -1), late: .locked)))
        let missed = BackgroundResult(madeAt: Self.at(7), content: .missed(kind: .morningSummary,
                                                                           due: Self.at(7, days: -1), held: .lowPower))
        let several = BackgroundResult(madeAt: Self.at(7), content: .missed(
            kind: .morningSummary, due: Self.at(7, days: -3), held: nil, through: Self.at(7, days: -1)))
        for result in [summary, missed, several] {
            let item = result.item(calendar: Self.calendar)
            #expect(!item.body.isEmpty)
            for isSample in [false, true] {
                let spoken = FeedCard(item: item, time: "7:00 AM", isSample: isSample, perform: {}).spoken
                #expect(spoken.contains(item.title))
                #expect(spoken.contains(item.body), "the body is read too: \(spoken)")
            }
        }
    }

    /// The notes and the private words are the only words of the person's
    /// kept on disk, each with the strictest protection, and the summary
    /// copies neither (`theSummaryAndSwitchFilesCopyNothingOfThePersons`
    /// reads their bytes). The chat is kept nowhere: no file that can hold
    /// it, found by what its code names in the packages and the app, writes
    /// a file, encodes it, or puts it in `UserDefaults` or scene storage,
    /// but for the passes below, each with its reason. The one
    /// `UserDefaults` the chat screen touches keeps the agent's name.
    @Test func theChatIsNeverKeptOnDisk() throws {
        let keeping = ["write(to", "FileManager", "createFile", "FileHandle", "AppStorage", "SceneStorage",
                       "JSONEncoder", "PropertyListEncoder", "NSKeyedArchiver", "UserDefaults.", "UserDefaults(",
                       "BackgroundStore", "MemoryStore", "CloudHelpFileStore"]
        var found: [String] = []
        let files = try Self.chatFiles()
        for file in files {
            for word in keeping where file.code.contains(word) {
                let pass = Self.keepsNoChat["\(file.name): \(word)"]
                #expect(pass != nil, "\(word) in \(file.name), which can hold the chat")
                found.append("\(file.name): \(word)")
            }
        }
        // Every pass is still needed and says why, so none outlives its reason.
        for (place, reason) in Self.keepsNoChat {
            #expect(found.contains(place), "no longer needed: \(place)")
            #expect(reason.count > 40, "say why: \(place)")
        }
        for name in ["PebbleModel/Conversation.swift", "PebbleModel/ModelClient.swift", "PebbleModel/CloudModel.swift",
                     "PebbleUI/ChatView.swift", "PebbleUI/Composer.swift", "PebbleUI/HomeView.swift"] {
            #expect(files.contains { $0.name == name }, "the sweep finds \(name)")
        }
        let chatView = try #require(files.first { $0.name == "PebbleUI/ChatView.swift" })
        #expect(chatView.code.contains("UserDefaultsAgentNameStore()"), "the name, and only the name")
    }

    /// Where a file that can hold the chat names something that keeps
    /// words on disk, and why that is never the chat. By file and word.
    static let keepsNoChat: [String: String] = [
        "PebbleModel/CloudModel.swift: JSONEncoder":
            "CloudRequest.encoded turns the request into bytes in memory, for the preview and for the one ephemeral "
            + "session that sends it. The file writes nothing: no write(to, FileManager or UserDefaults, which this "
            + "same sweep checks.",
        "PebbleModel/MLXChatModel.swift: FileManager":
            "MLXChatModel checks that the model folder holds its config, tokenizer and weights before MLX reads them. "
            + "It only reads that folder; the chat goes to the weights in memory and is never written.",
        "PebbleModel/OnDeviceModel.swift: FileManager":
            "OnDeviceModel looks at the model folder's files and sizes to choose a model at launch and after a "
            + "download. It reads no chat and writes nothing.",
        "PebbleUI/CloudHelpView.swift: MemoryStore":
            "CloudHelp reads the notes' store to build the redactor, so names from the notes are taken out of a "
            + "cloud request. It only reads the notes; it never hands the store a chat.",
        "PebbleUI/HomeView.swift: MemoryStore":
            "The home screen hands the notes' store to the memory screen and to CloudHelp, the same one for both. "
            + "Only the memory screen writes notes the person adds; no chat goes in.",
        "PebbleUI/ShowcaseScene.swift: MemoryStore":
            "The showcase, Debug only, fills scratch notes stores with sample notes for its screens. Its sample "
            + "chats are made in memory and never put in a store.",
        "PebbleUI/ShowcaseScene.swift: FileManager":
            "The showcase, Debug only, names scratch files in the temporary folder for its sample notes, and an "
            + "empty scratch folder for the model download row, whose fetcher fails every request. No chat is "
            + "written to either.",
        "PebbleUI/ShowcaseScene.swift: UserDefaults(":
            "The showcase, Debug only, uses a throwaway UserDefaults suite for the look it shows, emptied each "
            + "launch. It holds no chat.",
        "PebbleUI/ShowcaseScene.swift: UserDefaults.":
            "The showcase, Debug only, reads two of its own launch arguments from UserDefaults.standard: whether "
            + "to keep its sample asks and how long to hold a scene. It only reads them and writes no chat.",
        "PebbleUI/ShowcaseScene.swift: BackgroundStore":
            "The showcase, Debug only, runs background work on BackgroundStore.memoryOnly, which writes nothing "
            + "anywhere and holds only counts and times.",
    ]

    /// Every source that can hold chat text, in the packages and the app,
    /// found by what its code names, not from a list. The competitor
    /// watch never sees a chat.
    static func chatFiles() throws -> [(name: String, code: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let package = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App/Sources"))
        let chatWords = ["ChatTurn", "Conversation", "ModelClient", "CloudRequest", "ChatController", "messages"]
        return (package.map { ($0.name, $0.text) } + app.map { ("App/" + $0.name, $0.text) })
            .filter { !$0.0.hasPrefix("PebblePulse/") && !$0.0.hasPrefix("pulse/") }
            .map { (name: $0.0, code: String(SwiftSource($0.1).code)) }
            .filter { file in chatWords.contains(where: file.code.contains) }
    }

    /// Nor does the chat reach the disk another way. Every source in the
    /// app's packages and the app itself, found by what it names, not
    /// from a list, writes nothing to the system log, which keeps it on
    /// disk, and the one session that sends a chat to the cloud keeps no
    /// cache. Only the competitor watch, which never sees a chat, prints.
    @Test func theChatNeverReachesTheLogOrACache() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let sources = root.appendingPathComponent("Packages/PebbleKit/Sources")
        let logging = try NSRegularExpression(pattern: #"\b(Logger|os_log|os_signpost|NSLog|print|debugPrint|dump|OSLog)\b"#)
        let everyFile = try SwiftSource.files(under: sources).map { ($0.name, $0.text) }
            + SwiftSource.files(under: root.appendingPathComponent("App/Sources")).map { ("App/" + $0.name, $0.text) }
        #expect(everyFile.contains { $0.0 == "App/PebbleApp.swift" }, "the app's own sources are swept")
        for (name, text) in everyFile where !name.hasPrefix("PebblePulse/") && !name.hasPrefix("pulse/") {
            let code = String(SwiftSource(text).code)
            let range = NSRange(code.startIndex..., in: code)
            // No logging anywhere a chat could pass through, which is every
            // file but the competitor watch's.
            #expect(logging.firstMatch(in: code, range: range) == nil, "logging in \(name)")
        }
        let chatFiles = try Self.chatFiles()
        for file in chatFiles {
            #expect(!file.code.contains("URLSession.shared"), "a shared session, with its cache, in \(file.name)")
            #expect(!file.code.contains("URLCache"), "a response cache in \(file.name)")
            #expect(!file.code.contains("URLSessionConfiguration.default"), "a default session in \(file.name)")
        }
        for name in ["PebbleModel/ModelClient.swift", "PebbleModel/CloudModel.swift", "PebbleUI/ChatView.swift"] {
            #expect(chatFiles.contains { $0.name == name }, "the sweep finds \(name)")
        }
        // The cloud session: ephemeral, with no cache at all.
        let cloud = String(SwiftSource(try String(contentsOf: sources.appendingPathComponent("PebbleModel/CloudModel.swift"),
                                                  encoding: .utf8)).code)
        #expect(cloud.components(separatedBy: "URLSession(").count == 2, "one session is made, in makeSession")
        let session = URLSessionCloudTransport.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(cloud.contains("URLSessionConfiguration.ephemeral"))
    }

    /// Forget everything names work while away only where there is a switch for it.
    @Test func forgetEverythingNamesBackgroundWorkOnlyWhenThereIsSome() {
        #expect(MemoryWords.forgetEverythingDetail(background: true).contains("work while you're away"))
        #expect(!MemoryWords.forgetEverythingDetail(background: false).contains("away"))
    }

    /// No runner, no switch: the memory screen is as it was.
    @Test func withoutARunnerThereIsNoSwitch() {
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice)
        #expect(memory.background == nil)
        memory.setBackground(true)
        #expect(!memory.backgroundOn)
    }

    /// The showcase's runner is an example, and says so on every card.
    @Test func theShowcaseSummaryIsAnExample() {
        let morning = ShowcaseScene.morning
        let asks = ShowcaseScene.sampleQuestion(at: morning)
        let runner = ShowcaseScene.sampleBackground(on: true, needsYou: asks, played: true, at: morning)
        #expect(runner.isSample)
        // Only the summary: with no tasks, as in the app, a missed day leaves no card.
        #expect(runner.results.count == 1)
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice, background: runner,
                              now: { morning })
        #expect(model.isSample)
        for group in model.feed.groups {
            for item in group.items { #expect(model.isSample(item)) }
        }
    }
}

/// Counts calls, from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The steps of Forget everything as they happen, from any thread. The
/// notes have no hook of their own, so their erase is logged when the next
/// step finds their file gone.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private let notes: MemoryStore
    private var notesThere: Bool
    private var list: [String] = []

    init(notes: MemoryStore) {
        self.notes = notes
        notesThere = notes.hasStoredFile
    }

    func step(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if notesThere, !notes.hasStoredFile {
            notesThere = false
            list.append("notes")
        }
        list.append(name)
    }

    /// `step`, unless `name` was logged already.
    func stepOnce(_ name: String) {
        let logged = lock.withLock { list.contains(name) }
        if !logged { step(name) }
    }

    var steps: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
#endif
