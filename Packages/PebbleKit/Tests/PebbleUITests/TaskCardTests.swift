#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// A monotonic clock tests can move forward.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += .milliseconds(Int64(seconds * 1000)); lock.unlock() }
}

/// Live task cards on the Today feed: where they sit, what they offer, what
/// VoiceOver hears, and that Approve goes only through the question sheet.
@MainActor
struct TaskCardTests {
    private func model(_ engine: LocalFakeEngine, clock: Clock = Clock()) -> FeedModel {
        FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                  now: { ShowcaseScene.morning }, clock: clock.now)
    }

    private func render(_ model: FeedModel, size: CGSize, scheme: ColorScheme = .light,
                        text: DynamicTypeSize = .large) throws -> CGImage {
        let view = NavigationStack {
            FeedView(model: model, look: .startingPoint, onTalk: { _ in }, onChat: {})
        }
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, text)
            .frame(width: size.width, height: size.height))
        return try #require(renderer.cgImage)
    }

    nonisolated static let scenes: [ShowcaseScene] = [.taskRunning, .taskRetrying, .taskWaiting, .taskDone]

    /// Each scene once per size, light and dark taking turns. Kept to a
    /// handful: rendering holds the main actor, and timing tests share it.
    @Test(arguments: scenes)
    func eachSceneRendersAtEachSize(scene: ShowcaseScene) throws {
        let sizes = [
            CGSize(width: 393, height: 852),   // iPhone 17 Pro
            CGSize(width: 1032, height: 1376), // iPad Pro 13-inch, portrait
            CGSize(width: 1376, height: 1032), // iPad Pro 13-inch, landscape
            CGSize(width: 320, height: 1032),  // Slide Over
        ]
        for (index, size) in sizes.enumerated() {
            let engine = ShowcaseScene.sampleTasks(scene, rule: .isolated())
            let image = try render(model(engine), size: size, scheme: index.isMultiple(of: 2) ? .light : .dark)
            #expect(image.width == Int(size.width * 2) || image.width == Int(size.width))
        }
    }

    /// The biggest text sizes, where the buttons stack.
    @Test(arguments: [DynamicTypeSize.accessibility3, .accessibility5])
    func cardsRenderAtTheLargestTextSizes(text: DynamicTypeSize) throws {
        for scene in [ShowcaseScene.taskWaiting, .taskRunning] {
            let engine = ShowcaseScene.sampleTasks(scene, rule: .isolated())
            _ = try render(model(engine), size: CGSize(width: 393, height: 852), text: text)
        }
        let engine = ShowcaseScene.sampleTasks(.taskWaiting, rule: .isolated())
        _ = try render(model(engine), size: CGSize(width: 1032, height: 1376), text: text)
    }

    @Test func eachSceneShowsItsState() throws {
        func dentist(_ scene: ShowcaseScene) -> AgentTask? {
            ShowcaseScene.sampleTasks(scene, rule: .isolated()).tasks.first { $0.title == SampleTasks.dentistTitle }
        }
        #expect(dentist(.taskRunning)?.state == .running)
        #expect(dentist(.taskRetrying)?.state == .retrying)
        #expect(dentist(.taskRetrying)?.step == "That page was slow, so I'm trying another way.")
        #expect(dentist(.taskWaiting)?.waitsForApproval == true)
        #expect(dentist(.taskDone)?.state == .done)
        let waiting = ShowcaseScene.sampleTasks(.taskWaiting, rule: .isolated())
        #expect(waiting.tasks.first { $0.title == SampleTasks.lunchTitle }?.isStuck == true)
        // The running scene is a calm moment: no one is needed.
        let running = model(ShowcaseScene.sampleTasks(.taskRunning, rule: .isolated()))
        #expect(running.feed.needsYou.isEmpty)
        #expect(running.feed.working.count == 2)
    }

    @Test func cardsSitWhereTheyBelong() throws {
        let waiting = model(ShowcaseScene.sampleTasks(.taskWaiting, rule: .isolated()))
        #expect(waiting.feed.needsYou.count == 2)
        #expect(waiting.feed.working.isEmpty)
        let done = model(ShowcaseScene.sampleTasks(.taskDone, rule: .isolated()))
        #expect(done.feed.needsYou.isEmpty && done.feed.working.isEmpty)
        let finished = done.feed.groups.flatMap(\.items).compactMap(\.task)
        #expect(finished.count == 2)
        #expect(finished.allSatisfy { $0.state == .done })
    }

    // MARK: Buttons

    @Test func approveShowsOnlyWhileWaitingOnAYes() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        func actions() -> [TaskCard.Action] { TaskCard(task: engine.task(id)!, time: "9:40 AM").actions }
        #expect(actions() == [.redirect, .stop])
        engine.advance(by: 27)
        #expect(engine.task(id)?.state == .stalled)
        #expect(actions() == [.redirect, .stop])
        engine.advance(by: 20)
        #expect(actions() == [.approval, .redirect, .stop])
        engine.stop(id)
        #expect(actions().isEmpty)
    }

    @Test func aStuckCardOffersTryAgainNotApprove() {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.lunch)
        engine.advance(by: 66)
        #expect(TaskCard(task: engine.task(id)!, time: "").actions == [.retry, .redirect, .stop])
    }

    @Test func aDoneCardOpensItsResult() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        let task = try #require(engine.task(id))
        #expect(TaskCard(task: task, time: "").actions == [.open])
        let model = model(engine)
        model.open(task)
        guard case .open(let text) = model.reading?.action else { Issue.record("not opened"); return }
        #expect(text == SampleTasks.plan.result)
    }

    // MARK: VoiceOver

    @Test func theCardReadsStepAndProgress() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 3)
        let card = TaskCard(task: try #require(engine.task(id)), time: "9:40 AM")
        #expect(card.spoken == "Working on it. Find a dentist near you open Saturdays. Looking at dentists near you. 9:40 AM")
        #expect(card.spokenValue == "13 percent done")
        engine.stop(id)
        #expect(TaskCard(task: try #require(engine.task(id)), time: "").spokenValue == nil)
    }

    @Test func stepChangesAreAnnouncedPolitelyAndTicksAreNot() throws {
        let clock = Clock()
        let engine = LocalFakeEngine(rule: .isolated())
        let model = model(engine, clock: clock)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        let id = engine.start(SampleTasks.dentist)
        heard.removeAll()
        // Ticks inside the first step: progress moves, nothing is said.
        for _ in 0..<5 {
            engine.advance(by: 1)
            clock.advance(1)
        }
        #expect(heard.isEmpty)
        // The step changes: said once, politely.
        engine.advance(by: 1)
        clock.advance(1)
        #expect(heard == [TaskAnnouncer.Line(text: "Find a dentist near you open Saturdays. Checking which ones open on Saturdays", urgent: false)])
        for _ in 0..<15 {
            engine.advance(by: 1)
            clock.advance(1)
        }
        #expect(heard.count == 1)
        // Waiting on the person is said straight away.
        engine.advance(by: 30)
        clock.advance(30)
        #expect(heard.last?.urgent == true)
        #expect(engine.task(id)?.waitsForApproval == true)
    }

    // MARK: Approve goes through the sheet, and only once

    @Test func approveOpensTheSameQuestionSheet() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        let task = try #require(engine.task(id))
        model.review(task)
        let request = try #require(model.reviewing)
        #expect(request == task.question)
        #expect(model.rule === rule)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .approved)
        #expect(model.reviewing == nil)
        #expect(engine.task(id)?.state == .running)
        #expect(model.feed.needsYou.isEmpty)
        // The sheet going away afterwards changes nothing.
        model.closedQuestion(request)
        engine.advance(by: 4)
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.wrapUp == nil)
    }

    @Test func aTimedOutTaskQuestionCantBeApproved() throws {
        let clock = Clock()
        let rule = AskFirst.isolated(now: clock.now)
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        clock.advance(AskFirst.defaultWindow + 1)
        var approved = false
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { _ in approved = true }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .timedOut)
        #expect(!approved)
        #expect(sheet.footnote == ConfirmationWords.expired)
        model.refresh()
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.wrapUp?.notDone == ["hold a Saturday visit"])
    }

    @Test func notNowOnATaskQuestionSkipsThatStep() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.cancel() == .closed)
        #expect(rule.isClosed(request))
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.wrapUp?.notDone == ["hold a Saturday visit"])
    }

    @Test func redirectAndStopNeverOpenASheet() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        let task = try #require(engine.task(id))
        #expect(model.redirect(task, with: "Only ones near the school"))
        #expect(model.reviewing == nil)
        model.stop(try #require(engine.task(id)))
        #expect(model.reviewing == nil)
        #expect(engine.task(id)?.state == .stopped)
        #expect(model.feed.needsYou.isEmpty)
    }

    /// An engine that asks through a rule other than the feed's can't open
    /// the sheet: its question is never pinned, and the sheet only ever
    /// uses the feed's rule.
    @Test func aTaskAskingThroughAnotherRuleCantOpenTheSheet() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                                  details: "Running late")
        _ = try #require(asks.ask(note))
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, now: { ShowcaseScene.morning })
        let task = try #require(engine.task(id))
        #expect(task.waitsForApproval)
        #expect(!model.feed.needsYou.contains { $0.id == id })
        model.review(task)
        model.perform(TaskFeed.item(task), talk: { _ in })
        #expect(model.reviewing == nil)
        #expect(model.rule === rule)
        let question = try #require(model.feed.needsYou.first { $0.request != nil })
        model.perform(question, talk: { _ in })
        #expect(model.reviewing == question.request)
    }

    /// A task card from anywhere but the feed's engine shows nothing and
    /// opens nothing, even with a real question inside.
    @Test func aCardPosingAsATaskCantAsk() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        struct Posing: FeedSource {
            let item: FeedItem
            func items(now: Date) -> [FeedItem] { [item] }
        }
        let posing = TaskFeed.item(try #require(engine.tasks.first))
        let model = FeedModel(sources: [Posing(item: posing)], needsYou: NeedsYou(rule: rule),
                              now: { ShowcaseScene.morning })
        #expect(model.feed.isEmpty)
        model.perform(posing, talk: { _ in })
        model.review(try #require(posing.task))
        #expect(model.reviewing == nil)
    }

    /// Scripted tasks are examples: the note says so even with no other
    /// example cards, and a result opened from one carries the label.
    @Test func sampleTasksAreLabelledAsExamples() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                              now: { ShowcaseScene.morning })
        #expect(model.isSample)
        model.open(try #require(engine.task(id)))
        let reading = try #require(model.reading)
        #expect(model.isSample(reading))
        // Real cards beside them never get the label.
        let plain = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), now: { ShowcaseScene.morning })
        #expect(!plain.isSample)
        #expect(!plain.isSample(reading))
    }

    @Test func calmMotionHoldsStillWithReduceMotion() {
        #expect(Motion.sweep(at: 0, reduceMotion: true) == Motion.sweep(at: 1.3, reduceMotion: true))
        #expect(Motion.sweep(at: 0, reduceMotion: false) != Motion.sweep(at: 1.3, reduceMotion: false))
        #expect(Motion.breath(at: 0.4, reduceMotion: true) == 1)
        #expect(Motion.progress(reduceMotion: true) == nil)
        #expect(Motion.progress(reduceMotion: false) != nil)
    }

    @Test func theLiveShowcasePlaysInRealTime() {
        let engine = ShowcaseScene.liveTasks(rule: .isolated())
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine, drivesTasks: true)
        #expect(model.drivesTasks)
        model.tick(7)
        #expect(engine.now == 7)
        #expect(engine.tasks.count == SampleTasks.all.count)
    }
}
#endif
