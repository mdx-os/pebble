#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
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

    private func runner(on: Bool, needsYou: NeedsYou? = nil) -> BackgroundRunner {
        let store = BackgroundStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("background-ui-\(UUID().uuidString).json"))
        let runner = BackgroundRunner(store: store, toggle: InMemoryBackgroundSwitch(), needsYou: needsYou,
                                      calendar: Self.calendar)
        if on { runner.turnOn(now: Self.at(6)) }
        return runner
    }

    private func model(_ runner: BackgroundRunner, needsYou: NeedsYou = NeedsYou(rule: .isolated()),
                       now: @escaping () -> Date) -> FeedModel {
        FeedModel(sources: [EmptyFeedSource()], needsYou: needsYou, place: .onDevice, background: runner,
                  calendar: Self.calendar, now: now)
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
        #expect(card.kind == .did)
        #expect(!model.isSample(card))
    }

    /// Away from the screen, Today's refresh leaves background work to the
    /// platform's own run, which knows if the device is locked.
    @Test func todayRunsNothingWhileTheAppIsAway() {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(8) }
        model.inFront = false
        model.refresh()
        #expect(runner.results.isEmpty)
        model.inFront = true
        model.refresh()
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
        let asks = NeedsYou(rule: .isolated())
        asks.ask(ProposedAction(kind: .send,
                                recipient: Recipient(id: "c:1", displayName: "Sam", handle: "sam@example.com"),
                                details: "See you at 4"), at: Self.at(6, 50))
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

    /// Off until the person turns it on. On, it says when the next is due.
    @Test func theSwitchIsOffUntilTurnedOnAndSaysWhenTheNextIsDue() {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.backgroundOn)
        #expect(memory.backgroundNext == nil)

        memory.setBackground(true)
        #expect(runner.isOn)
        #expect(memory.backgroundOn)
        #expect(runner.queue.first?.due == Self.at(7, days: 1))
        #expect(memory.backgroundNext == BackgroundWords.nextDue(Self.at(7, days: 1), now: Self.at(9)))

        memory.setBackground(false)
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(memory.backgroundNext == nil)
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
