#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import Testing
@testable import PebbleUI

/// Background work as Today and the memory screen show it: the cards it
/// leaves, the catch up when the app opens, the switch, and Forget everything.
@MainActor
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

    private func scratchStore() -> BackgroundStore {
        BackgroundStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("background-ui-\(UUID().uuidString).json"))
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
        MemoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-ui-\(UUID().uuidString).json"))
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

    /// Forget everything turns background work off and its cards go.
    @Test func forgetEverythingClearsTheCardsAndTurnsItOff() throws {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(9) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        model.perform(card) { _ in }

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner,
                                 now: { Self.at(9) }, onForgetEverything: { model.forgetEverything() })
        #expect(memory.backgroundOn)
        memory.forgetEverything()
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
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

        memory.forgetEverything()
        #expect(runner.results.isEmpty)
        #expect(!runner.store.hasStoredFile)
        #expect(!memory.hasSomethingToForget)
        #expect(memory.status == MemoryWords.forgotten)
    }

    /// If the summaries' file can't be erased, the line says so rather
    /// than read as done, and Forget everything stays to try again.
    /// Root ignores file permissions, so the file would be erased and the
    /// test would pass without showing anything.
    @Test(.enabled(if: geteuid() != 0, "file permissions don't hold for root"))
    func aSummaryFileThatCantBeErasedIsSaid() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let runner = runner(on: true, store: BackgroundStore(fileURL: folder.appendingPathComponent("background.json")))
        #expect(runner.store.hasStoredFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(memory.hasSomethingToForget)
        memory.forgetEverything()
        #expect(!runner.isOn, "off even so")
        #expect(memory.status == MemoryWords.couldNotForgetSummaries)
        #expect(memory.hasSomethingToForget, "still there, so it can be tried again")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        memory.forgetEverything()
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!memory.hasSomethingToForget)
    }

    /// With the private words too, each step runs whatever the others did:
    /// the notes can't be erased here, but the summaries and the words go,
    /// and the line says exactly that.
    @Test(.enabled(if: geteuid() != 0, "file permissions don't hold for root"))
    func forgetEverythingSaysWhatWentWithTheWordsAndSummaries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("memory-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let runner = runner(on: true)
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        var wordsForgotten = false
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { wordsForgotten = true; return .privateWords },
                                 background: runner, now: { Self.at(9) })
        memory.forgetEverything()
        #expect(memory.status == CloudWords.forgotWordsNotNotes + " " + MemoryWords.summariesGone)
        #expect(wordsForgotten)
        #expect(!runner.isOn)
        #expect(runner.results.isEmpty)
        #expect(!runner.store.hasStoredFile)
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

    /// The app wires no task engine yet, so the line under the switch, read
    /// as the person turns it on, doesn't promise what finished. With an
    /// engine, it does.
    @Test func theSwitchPromisesWhatFinishedOnlyWithTasksToCount() throws {
        let app = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("private let tasks: (any TaskEngine)? = nil"), "the app wires no engine yet")
        #expect(app.contains("BackgroundRunner.onDevice(needsYou: asks, tasks: tasks)"))

        let store = scratchStore()
        defer { try? store.forget() }
        let wired = try #require(BackgroundRunner.onDevice(needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                                           store: { store }, toggle: InMemoryBackgroundSwitch()))
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
    @Test func theMemoryScreenFollowsTheRunner() async {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.backgroundOn)
        #expect(!memory.hasSomethingToForget)

        // Another window turns it on and Today makes a card.
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        for _ in 0..<100 where !memory.hasSomethingToForget { await Task.yield() }
        #expect(memory.backgroundOn)
        #expect(memory.backgroundNext != nil)
        #expect(memory.hasSomethingToForget)
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
        #expect(runner.results.count == 2)
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice, background: runner,
                              now: { morning })
        #expect(model.isSample)
        for group in model.feed.groups {
            for item in group.items { #expect(model.isSample(item)) }
        }
    }
}
#endif
