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
                  place: .onDevice, now: { ShowcaseScene.morning }, clock: clock.now)
    }

    private func render(_ model: FeedModel, size: CGSize, scheme: ColorScheme = .light,
                        text: DynamicTypeSize = .large) throws -> CGImage {
        let view = NavigationStack {
            FeedView(model: model, look: .startingPoint, onTalk: { _ in })
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
        func actions(pinned: Bool = true) -> [TaskCard.Action] {
            TaskCard(task: engine.task(id)!, time: "9:40 AM", canApprove: pinned).actions
        }
        #expect(actions() == [.redirect, .stop])
        engine.advance(by: 27)
        #expect(engine.task(id)?.state == .stalled)
        #expect(actions() == [.redirect, .stop])
        engine.advance(by: 20)
        #expect(actions() == [.approval, .redirect, .stop])
        // Not pinned in Needs you: the waiting line, and no button that does nothing.
        #expect(actions(pinned: false) == [.redirect, .stop])
        engine.stop(id)
        #expect(actions() == [.dismiss])
    }

    /// The engine asked through another rule, so its question is never
    /// pinned. The card shows no Approve, and says it is waiting.
    @Test func noApproveWhenTheQuestionIsAskedThroughAnotherRule() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: engine,
                              place: .onDevice, now: { ShowcaseScene.morning })
        let item = try #require(model.feed.working.first { $0.id == id })
        let task = try #require(item.task)
        #expect(task.waitsForApproval)
        #expect(!model.canApprove(task))
        let card = TaskCard(task: task, time: "", canApprove: model.canApprove(task))
        #expect(!card.actions.contains(.approval))
        guard case .ask(_, let askLine) = SampleTasks.dentist.steps[3].kind else { Issue.record("not an ask"); return }
        #expect(task.step == askLine)
        model.review(task)
        #expect(model.reviewing == nil)
    }

    /// The rule closed the question before the engine settled it. Approve
    /// goes at once, and comes back for no one.
    @Test func noApproveOnceTheQuestionClosesBeforeTheEngineNotices() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        let pinned = try #require(model.feed.needsYou.first { $0.id == id }?.task)
        #expect(model.canApprove(pinned))
        #expect(TaskCard(task: pinned, time: "", canApprove: model.canApprove(pinned)).actions.first == .approval)
        let question = try #require(pinned.question)
        rule.withdraw(question)
        // The engine hasn't looked again, so it still thinks it waits.
        #expect(engine.task(id)?.waitsForApproval == true)
        // The feed on screen still has it pinned, but the button goes.
        #expect(model.feed.needsYou.contains { $0.id == id })
        #expect(!model.canApprove(pinned))
        #expect(!TaskCard(task: pinned, time: "", canApprove: model.canApprove(pinned)).actions.contains(.approval))
        // A feed built now has it in Working on it, still without Approve.
        let fresh = self.model(engine)
        #expect(!fresh.feed.needsYou.contains { $0.id == id })
        let card = try #require(fresh.feed.working.first { $0.id == id }?.task)
        #expect(card.waitsForApproval)
        #expect(!fresh.canApprove(card))
        #expect(!TaskCard(task: card, time: "", canApprove: fresh.canApprove(card)).actions.contains(.approval))
        // A tap on a stale Approve opens nothing, and looks again, so the
        // task settles and its card says why.
        model.review(pinned)
        #expect(model.reviewing == nil)
        #expect(engine.task(id)?.waitsForApproval == false)
        #expect(model.cardState(id).note == TaskWords.questionTimedOut)
        fresh.review(card)
        #expect(fresh.reviewing == nil)
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
        #expect(TaskCard(task: task, time: "").actions == [.open, .dismiss])
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
        #expect(card.spoken == "On it. Find a dentist near you open Saturdays. Looking at dentists near you. 9:40 AM")
        #expect(card.spokenValue == "13 percent done")
        engine.stop(id)
        #expect(TaskCard(task: try #require(engine.task(id)), time: "").spokenValue == nil)
    }

    /// The heading and the card's label differ, so VoiceOver never says
    /// "Working on it" twice in a row.
    @Test func theRunningLabelIsNotTheHeading() {
        #expect(TaskState.running.label != TaskWords.workingHeading)
    }

    /// The feed card has no live progress; the card reads it from the model.
    @Test func theCardReadsLiveProgressFromTheModel() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        let model = model(engine)
        let item = try #require(model.feed.working.first { $0.id == id }?.task)
        let live = model.liveProgress(id)
        engine.advance(by: 3)
        let card = TaskCard(task: item, time: "", progress: live)
        #expect(card.spokenValue == "13 percent done")
        #expect(model.liveProgress(id) === live)
    }

    // MARK: A tick never republishes the feed

    @Test func aTickDoesNotChangeTheFeed() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        let model = model(engine)
        let live = model.liveProgress(id)
        var published = 0
        let watch = model.$feed.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        let before = model.feed
        for _ in 0..<5 { engine.advance(by: 1) }
        #expect(model.feed == before)
        #expect(published == 0)
        #expect(abs((live.value.fraction ?? 0) - 5.0 / 24) < 0.001)
        // A new step is a real change.
        engine.advance(by: 1)
        #expect(model.feed != before)
        #expect(published == 1)
    }

    /// A snapshot that arrives after a newer one is dropped, so neither the
    /// feed nor VoiceOver goes back in time.
    @Test func aLateSnapshotIsDropped() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let model = model(engine)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        let old = TaskSnapshot(sequence: 0, tasks: engine.tasks)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 6)
        let now = model.feed
        let said = heard
        #expect(now.working.contains { $0.id == id })
        model.tasksChanged(old)
        #expect(model.feed == now)
        #expect(heard == said)
    }

    // MARK: Letting go

    @Test func anEndedCardCanBeCleared() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        let model = model(engine)
        let task = try #require(engine.task(id))
        model.open(task)
        #expect(model.reading != nil)
        model.dismiss(task)
        #expect(engine.task(id) == nil)
        #expect(model.reading == nil)
        #expect(!model.feed.groups.flatMap(\.items).contains { $0.id == id })
        // A task still going can't be cleared away.
        let going = engine.start(SampleTasks.dentist)
        model.dismiss(try #require(engine.task(going)))
        #expect(engine.task(going) != nil)
    }

    @Test func forgetEverythingInMemoryForgetsTasksToo() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        engine.start(SampleTasks.plan)
        let model = model(engine)
        let task = try #require(engine.task(id))
        model.review(task)
        let question = try #require(model.reviewing)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-forget-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let memory = MemoryModel(store: store, place: .onDevice, onForgetEverything: { model.forgetTasks() })
        memory.newNote = "Prefers mornings"
        memory.add()
        memory.forgetEverything()
        #expect(memory.notes.isEmpty)
        #expect(engine.tasks.isEmpty)
        #expect(model.feed.needsYou.isEmpty && model.feed.working.isEmpty)
        #expect(model.reviewing == nil)
        #expect(rule.isClosed(question))
    }

    /// The notes couldn't be opened, so there is no Forget everything. The
    /// screen in its place still forgets every task.
    @Test func theMemoryFallbackForgetsTasks() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        engine.redirect(engine.start(SampleTasks.plan), with: "Keep Friday free")
        let model = model(engine)
        let question = try #require(engine.task(id)?.question)
        #expect(model.hasTasks)
        let fallback = MemoryUnavailableView(hasTasks: model.hasTasks, onForgetTasks: { model.forgetTasks() })
        _ = try #require(ImageRenderer(content: fallback.frame(width: 393, height: 852)).cgImage)
        fallback.forgetTasks()
        #expect(engine.tasks.isEmpty)
        #expect(!model.hasTasks)
        #expect(model.feed.needsYou.isEmpty && model.feed.working.isEmpty)
        #expect(rule.isClosed(question))
    }

    // MARK: A card keeps what it was doing across sections

    /// The dentist task is reading reviews, a breath before it asks. The
    /// person opens Change course and types. The task reaches its ask step
    /// and its card moves from Working on it to Needs you: a new view.
    @Test func aCardMovingToNeedsYouKeepsItsFieldWordsAndFocus() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 40)
        let model = model(engine)
        #expect(model.feed.working.contains { $0.id == id })
        let state = model.cardState(id)
        state.openField()
        // What the card does once the field is on screen.
        #expect(state.takeFocus() == .field)
        state.pendingKeyboard = false
        state.typing = true
        state.hasVoiceOver = true
        state.words = "Only ones near the school"
        engine.advance(by: 5)
        let moved = try #require(model.feed.needsYou.first { $0.id == id }?.task)
        #expect(moved.state == .waitingOnYou)
        #expect(!model.feed.working.contains { $0.id == id })
        // The same state, words and open field, whatever view draws it.
        #expect(model.cardState(id) === state)
        #expect(state.redirecting)
        #expect(state.words == "Only ones near the school")
        // VoiceOver goes to the summary in its new place, and the keyboard
        // goes back to the field.
        #expect(state.pendingFocus == .summary)
        #expect(state.pendingKeyboard)
        let card = TaskCard(task: moved, time: "", state: model.cardState(id), canApprove: model.canApprove(moved))
        #expect(card.actions == [.approval, .stop])
        _ = try render(model, size: CGSize(width: 393, height: 852))
        // The words still send.
        #expect(model.redirect(moved, with: state.words))
        #expect(engine.task(id)?.history.last?.text == TaskWords.changedCourse("hold a Saturday visit"))
    }

    /// A task that ends with the field open closes it, clears the words,
    /// and sends VoiceOver to the summary in its new place.
    @Test func aTaskThatEndsClosesItsFieldAndKeepsFocus() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        let model = model(engine)
        let state = model.cardState(id)
        state.openField()
        _ = state.takeFocus()
        state.words = "Keep Friday free"
        engine.stop(id)
        #expect(model.feed.groups.flatMap(\.items).contains { $0.id == id })
        #expect(!state.redirecting)
        #expect(state.words.isEmpty)
        #expect(state.pendingFocus == .summary)
        #expect(!state.pendingKeyboard)
    }

    /// VoiceOver was on a card's button with no field open. The task
    /// finishes and the card moves to a time group: focus follows it.
    @Test func voiceOverFollowsACardThatMoves() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        let other = engine.start(SampleTasks.lunch)
        let model = model(engine)
        let state = model.cardState(id)
        state.hasVoiceOver = true
        let quiet = model.cardState(other)
        // Ticks and new steps in place ask for nothing.
        engine.advance(by: 6)
        #expect(state.pendingFocus == nil)
        engine.advance(by: 60)
        #expect(engine.task(id)?.state == .done)
        #expect(state.pendingFocus == .summary)
        #expect(!state.pendingKeyboard)
        // The card VoiceOver wasn't on, though it moved to Needs you, asks for nothing.
        #expect(model.feed.needsYou.contains { $0.id == other })
        #expect(quiet.pendingFocus == nil)
    }

    @Test func aClearedTaskLetsGoOfItsCardState() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        let model = model(engine)
        let state = model.cardState(id)
        state.words = "Keep Friday free"
        engine.advance(by: 30)
        model.dismiss(try #require(engine.task(id)))
        #expect(model.cardState(id) !== state)
        #expect(model.cardState(id).words.isEmpty)
    }

    /// The oldest ended tasks are let go. One whose result is open to read
    /// closes with it.
    @Test func readingClosesWhenItsTaskIsLetGo() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        let model = model(engine)
        model.open(try #require(engine.task(id)))
        #expect(model.reading?.id == id)
        for _ in 0..<(LocalFakeEngine.endedLimit - 1) {
            engine.start(SampleTasks.plan)
            engine.advance(by: 30)
        }
        #expect(engine.task(id) != nil)
        #expect(model.reading?.id == id)
        engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        #expect(engine.task(id) == nil)
        #expect(model.reading == nil)
    }

    /// A reader for something other than a task stays open.
    @Test func readingANonTaskCardIsLeftAlone() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let model = model(engine)
        let ready = try #require(model.feed.groups.flatMap(\.items).first { $0.task == nil && $0.kind == .ready })
        model.perform(ready, talk: { _ in })
        #expect(model.reading?.id == ready.id)
        engine.start(SampleTasks.plan)
        engine.advance(by: 30)
        #expect(model.reading?.id == ready.id)
    }

    /// A yes the task couldn't use did nothing. The card says so, and so
    /// does VoiceOver, until the task moves on.
    @Test func aYesThatDoesNotGoThroughSaysSo() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let script = TaskScript(title: "Hold it", steps: [
            .init("Asking", kind: .ask(SampleTasks.holdVisit, askLine: "May I?"), duration: 2, todo: "hold it"),
            .init("Tidying", duration: 5, todo: "tidy up"),
        ], doneLine: "Done.")
        let id = engine.start(script)
        let model = model(engine)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        guard case .approved(let yes) = rule.sayYes(to: request) else { Issue.record("yes refused"); return }
        // Closed somewhere else before the yes reached the task.
        rule.withdraw(request)
        model.approved(yes)
        let state = model.cardState(id)
        #expect(state.note == TaskWords.yesNotUsed)
        #expect(heard.contains(TaskAnnouncer.Line(text: TaskWords.yesNotUsed, urgent: true)))
        #expect(engine.task(id)?.history.contains { $0.mark == .approved } == false)
        // Gone once the task moves on.
        engine.advance(by: 6)
        #expect(engine.task(id)?.state == .done)
        #expect(state.note == nil)
        // A yes that goes through leaves no note.
        let again = engine.start(script)
        model.review(try #require(engine.task(again)))
        let next = try #require(model.reviewing)
        guard case .approved(let good) = rule.sayYes(to: next) else { Issue.record("yes refused"); return }
        model.approved(good)
        #expect(model.cardState(again).note == nil)
    }

    /// Change course asks for focus on the field, taken once the field is
    /// on screen, not in the tap that adds it.
    @Test func changeCourseDefersFocusToTheField() {
        let state = TaskCardState()
        state.openField()
        #expect(state.redirecting)
        #expect(state.pendingFocus == .field)
        #expect(state.pendingKeyboard)
        #expect(state.takeFocus() == .field)
        #expect(state.takeFocus() == nil)
        state.words = "x"
        state.closeField()
        #expect(state.words.isEmpty && !state.redirecting)
        #expect(state.pendingFocus == .summary)
    }

    /// A yes for a question opened from a task card goes back to that task,
    /// even after it moved on, and never to `NeedsYou`.
    @Test func aTaskYesGoesBackToItsTask() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let asks = NeedsYou(rule: rule)
        let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                                  details: "Running late")
        let noteQuestion = try #require(asks.ask(note))
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice, now: { ShowcaseScene.morning })
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .approved)
        #expect(engine.task(id)?.history.last?.mark == .approved)
        // The feed's own question is untouched.
        #expect(model.feed.needsYou.contains { $0.request == noteQuestion })
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
        model.review(task)
        #expect(model.reviewing != nil)
        #expect(model.redirect(task, with: "Only ones near the school"))
        #expect(model.reviewing == nil)
        // The ask step is left undone, not asked again as it was.
        #expect(engine.task(id)?.waitsForApproval == false)
        #expect(model.feed.needsYou.isEmpty)
        let other = engine.start(SampleTasks.plan)
        model.stop(try #require(engine.task(other)))
        #expect(model.reviewing == nil)
        #expect(engine.task(other)?.state == .stopped)
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
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice, now: { ShowcaseScene.morning })
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
                              place: .onDevice, now: { ShowcaseScene.morning })
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
                              place: .onDevice, now: { ShowcaseScene.morning })
        #expect(model.isSample)
        model.open(try #require(engine.task(id)))
        let reading = try #require(model.reading)
        #expect(model.isSample(reading))
        // Real cards beside them never get the label.
        let plain = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), place: .onDevice,
                              now: { ShowcaseScene.morning })
        #expect(!plain.isSample)
        #expect(!plain.isSample(reading))
    }

    /// Each scripted task's card carries the Example tag, read first, so a
    /// dentist hold that shares a name and phone never reads as real.
    @Test func sampleTaskCardsCarryTheExampleTag() throws {
        let engine = ShowcaseScene.sampleTasks(.taskWaiting, rule: .isolated())
        let model = model(engine)
        let items = model.feed.needsYou.filter { $0.task != nil }
        #expect(!items.isEmpty)
        for item in items {
            let task = try #require(item.task)
            #expect(model.isSample(item))
            let card = TaskCard(task: task, time: "9:40 AM", isSample: model.isSample(item))
            #expect(card.spoken.hasPrefix("\(FeedWords.exampleMarker). "))
        }
        // A real task card never says it.
        let plain = TaskCard(task: try #require(engine.tasks.first), time: "9:40 AM")
        #expect(!plain.spoken.contains(FeedWords.exampleMarker))
        _ = try render(model, size: CGSize(width: 393, height: 852))
    }

    /// Example questions name reserved places, never a site someone may own.
    @Test func sampleHandlesAreReservedNames() throws {
        #expect(SampleTasks.holdVisit.recipient.handle == "mapledental.example")
        let question = try #require(ShowcaseScene.sampleQuestion().items(now: Date()).first?.request)
        #expect(question.action.recipient.handle == "risebakery.example")
    }

    // MARK: Forgetting with a yes under way

    /// The person said yes and the step is under way when they forget
    /// everything. The task goes, but a plain line stays on Today, and in
    /// the memory's status, to say it may be done. It names nothing.
    @Test func forgetEverythingKeepsAMayBeDoneLineForAYesUnderWay() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.tapPrimary() == .approved)
        #expect(engine.task(id)?.state == .running)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-underway-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let memory = MemoryModel(store: store, place: .onDevice, onForgetEverything: { model.forgetTasks() })
        memory.newNote = "Prefers mornings"
        memory.add()
        memory.forgetEverything()
        let line = TaskWords.forgotUnderway(1)
        #expect(engine.tasks.isEmpty)
        #expect(model.forgotUnderway == line)
        #expect(memory.status == MemoryWords.forgotten + " " + line)
        #expect(heard.contains(TaskAnnouncer.Line(text: line, urgent: true)))
        for detail in ["Maple", "Saturday", "10:30", "dentist"] { #expect(!line.contains(detail)) }
        // On Today, even with nothing else there, until the person puts it away.
        _ = try render(model, size: CGSize(width: 393, height: 852))
        model.dismissForgotUnderway()
        #expect(model.forgotUnderway == nil)
    }

    /// With no yes under way, forgetting leaves nothing behind on Today.
    @Test func forgetEverythingWithNoYesUnderWayLeavesNoLine() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        #expect(engine.task(id)?.waitsForApproval == true)
        let model = model(engine)
        let cleared = model.forgetTasks()
        #expect(cleared == ClearedTasks(forgotten: 1, underway: 0))
        #expect(model.forgotUnderway == nil)
    }

    /// The tasks went, but the notes couldn't be erased. The status says
    /// which part worked rather than that nothing did.
    @Test func aFailedForgetSaysTheTasksWent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try store.remember("Prefers mornings", source: .toldMe)
        // A folder nothing can be removed from, so erasing the notes fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        let model = model(engine)
        let memory = MemoryModel(store: store, place: .onDevice, onForgetEverything: { model.forgetTasks() })
        memory.forgetEverything()
        #expect(engine.tasks.isEmpty)
        #expect(memory.status == MemoryWords.couldNotForgetNotes)
        // With no tasks to forget, the plain words.
        let none = MemoryModel(store: store, place: .onDevice)
        none.forgetEverything()
        #expect(none.status == MemoryWords.couldNotForget)
    }

    /// The fallback screen says the tasks are gone once its button goes,
    /// and points VoiceOver at that line.
    @Test func theMemoryFallbackSaysTheTasksAreForgotten() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        let model = model(engine)
        #expect(MemoryUnavailableView(hasTasks: model.hasTasks, forgotten: model.tasksForgotten,
                                      onForgetTasks: {}).status == nil)
        model.forgetTasks()
        #expect(model.tasksForgotten)
        let after = MemoryUnavailableView(hasTasks: model.hasTasks, forgotten: model.tasksForgotten,
                                          underway: model.forgotUnderway, onForgetTasks: {})
        #expect(after.status == TaskWords.tasksForgotten)
        _ = try #require(ImageRenderer(content: after.frame(width: 393, height: 852)).cgImage)
        // With a yes under way, it says that too.
        let underway = MemoryUnavailableView(hasTasks: false, forgotten: true,
                                             underway: TaskWords.forgotUnderway(1), onForgetTasks: {})
        #expect(underway.status == TaskWords.tasksForgotten + " " + TaskWords.forgotUnderway(1))
        // A new task, and the line goes.
        engine.start(SampleTasks.plan)
        #expect(!model.tasksForgotten)
    }

    // MARK: A task's yes stays the task's

    /// The task moved on (stopped, or forgotten) in the same moment its yes
    /// came. The yes is still known as the task's, so it does nothing, says
    /// so on the card, and never reaches `NeedsYou`.
    @Test func aLateTaskYesNeverFallsToNeedsYou() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                                  details: "Running late")
        let noteQuestion = try #require(asks.ask(note))
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice, now: { ShowcaseScene.morning })
        let task = try #require(engine.task(id))
        model.review(task)
        let request = try #require(model.reviewing)
        guard case .approved(let yes) = rule.sayYes(to: request) else { Issue.record("yes refused"); return }
        model.stop(task)
        model.approved(yes)
        #expect(engine.task(id)?.state == .stopped)
        #expect(engine.task(id)?.history.contains { $0.mark == .approved } == false)
        #expect(model.cardState(id).note == TaskWords.yesNotUsed)
        #expect(model.feed.needsYou.contains { $0.request == noteQuestion })
        // Forgotten instead: the same, with no task left to note.
        let again = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        model.review(try #require(engine.task(again)))
        let second = try #require(model.reviewing)
        guard case .approved(let late) = rule.sayYes(to: second) else { Issue.record("yes refused"); return }
        model.forgetTasks()
        model.approved(late)
        #expect(engine.tasks.isEmpty)
        #expect(model.feed.needsYou.contains { $0.request == noteQuestion })
    }

    // MARK: A stale Approve

    /// The question timed out while its Approve was on screen, and nothing
    /// built the feed again. The tap looks again, the task settles, and the
    /// card says the question timed out.
    @Test func aStaleApproveRefreshesAndSaysItTimedOut() throws {
        let clock = Clock()
        let rule = AskFirst.isolated(now: clock.now)
        let engine = LocalFakeEngine(rule: rule)
        let script = TaskScript(title: "Hold it", steps: [
            .init("Asking", kind: .ask(SampleTasks.holdVisit, askLine: "May I?"), duration: 2, todo: "hold it"),
            .init("Tidying", duration: 5, todo: "tidy up"),
        ], doneLine: "Done.")
        let id = engine.start(script)
        let model = model(engine, clock: clock)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        let shown = try #require(model.feed.needsYou.first { $0.id == id }?.task)
        #expect(model.canApprove(shown))
        clock.advance(AskFirst.defaultWindow + 1)
        // Nothing has looked again: the engine and the feed still have it waiting.
        #expect(engine.task(id)?.waitsForApproval == true)
        model.review(shown)
        #expect(model.reviewing == nil)
        let settled = try #require(engine.task(id))
        #expect(!settled.waitsForApproval)
        #expect(settled.step == "Tidying")
        #expect(settled.history.last?.text == TaskWords.timedOut("hold it"))
        #expect(!model.feed.needsYou.contains { $0.id == id })
        #expect(model.cardState(id).note == TaskWords.questionTimedOut)
        #expect(heard.contains(TaskAnnouncer.Line(text: TaskWords.questionTimedOut, urgent: true)))
    }

    @Test func calmMotionHoldsStillWithReduceMotion() {
        #expect(Motion.sweep(at: 0, reduceMotion: true) == Motion.sweep(at: 1.3, reduceMotion: true))
        #expect(Motion.sweep(at: 0, reduceMotion: false) != Motion.sweep(at: 1.3, reduceMotion: false))
        #expect(Motion.breath(at: 0.4, reduceMotion: true) == 1)
        #expect(Motion.progress(reduceMotion: true) == nil)
        #expect(Motion.progress(reduceMotion: false) != nil)
    }

    // MARK: With Today's shared pieces

    /// A purchase asked through `NeedsYou`, beside the tasks.
    private static let bakery = ProposedAction(
        kind: .purchase,
        recipient: Recipient(id: "merchant:sample-bakery", displayName: "Rise Bakery", handle: "risebakery.example"),
        details: "Sourdough loaf, pickup at 9",
        price: Price(minorUnits: 650, currency: "CAD")
    )

    /// A task's question that closes with nothing else changing leaves Needs
    /// you on the loop the home screen runs, so the count beside Today drops
    /// even with Today off screen.
    @Test func aTaskQuestionLeavesTheCountOnTheHomeLoop() async throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        let question = try #require(model.feed.needsYou.first { $0.id == id }?.task?.question)
        engine.rule.withdraw(question)
        // Nothing has looked again yet, so the count still holds it.
        #expect(model.feed.needsYou.contains { $0.id == id })
        var naps = 0
        await model.keepFresh { _ in
            naps += 1
            throw CancellationError()
        }
        #expect(naps == 1)
        #expect(!model.feed.needsYou.contains { $0.id == id })
        #expect(engine.task(id)?.waitsForApproval == false)
    }

    /// `NeedsYou`'s change hook rebuilds the feed with the tasks still in
    /// it: a new question sits beside a pinned task at once, questions
    /// first, and a dismissal leaves the task where it was. A model that
    /// goes stops watching.
    @Test func aNeedsYouChangeKeepsTaskCardsInPlace() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let asks = NeedsYou(rule: engine.rule)
        var model: FeedModel? = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice,
                                          now: { ShowcaseScene.morning })
        #expect(model?.feed.needsYou.map(\.id) == [id])
        let asked = try #require(asks.ask(Self.bakery))
        #expect(model?.feed.needsYou.count == 2)
        #expect(model?.feed.needsYou.first?.request?.id == asked.id)
        #expect(model?.feed.needsYou.last?.id == id)
        asks.dismissed(asked)
        #expect(model?.feed.needsYou.map(\.id) == [id])
        #expect(asks.observerCount == 1)
        model = nil
        #expect(asks.observerCount == 0)
    }

    /// A task's question in the sheet covers the chat like any question,
    /// so neither composer sends from the keyboard behind it.
    @Test func aTaskQuestionCoversTheChat() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        model.review(try #require(engine.task(id)))
        #expect(model.reviewing != nil)
        for usesSidebar in [false, true] {
            let cover = HomeCover(usesSidebar: usesSidebar, section: .today, showsShortcuts: false,
                                  readerOpen: false, questionOpen: model.reviewing != nil)
            #expect(cover.chatIsCovered)
            #expect(!cover.chatSendsFromKeyboard)
            #expect(!cover.todayInFront)
        }
    }

    /// A scripted task's question says it is an example in the sheet too,
    /// and a real question asked beside it does not.
    @Test func aScriptedTasksQuestionIsAnExampleInTheSheet() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let asks = NeedsYou(rule: engine.rule)
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice,
                              now: { ShowcaseScene.morning })
        let real = try #require(asks.ask(Self.bakery))
        model.review(try #require(engine.task(id)))
        let question = try #require(model.reviewing)
        #expect(model.isSample(question))
        #expect(!model.isSample(real))
    }

    // MARK: Not now stays Not now

    /// Not now on a task's question, with `NeedsYou` watched by this model
    /// and another that builds the feed again at once, says the person
    /// closed it, never that it timed out. `NeedsYou`'s own question stays.
    @Test func notNowOnATaskQuestionSaysDeclinedWithNeedsYouWatched() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        let real = try #require(asks.ask(Self.bakery))
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice,
                              now: { ShowcaseScene.morning })
        let watcher = asks.observe { MainActor.assumeIsolated { model.refresh() } }
        defer { asks.stopObserving(watcher) }
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        #expect(sheet.cancel() == .closed)
        let declined = TaskWords.declined("hold a Saturday visit")
        let timedOut = TaskWords.timedOut("hold a Saturday visit")
        #expect(engine.task(id)?.history.last?.text == declined)
        // The sheet then goes: its `onDismiss` refresh, then `onDisappear`.
        model.refresh()
        sheet.disappeared()
        model.closedQuestion(request)
        let history = try #require(engine.task(id)?.history)
        #expect(history.filter { $0.text == declined }.count == 1)
        #expect(!history.contains { $0.text == timedOut })
        #expect(model.feed.needsYou.contains { $0.request == real })
    }

    /// Swiped away, the sheet withdraws the question and `onDismiss` builds
    /// the feed again before `onDisappear` tells the model. That refresh
    /// still says the person closed it.
    @Test func aRefreshBeforeTheModelHearsStillSaysDeclined() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = model(engine)
        var heard: [TaskAnnouncer.Line] = []
        model.announce = { heard.append($0) }
        model.review(try #require(engine.task(id)))
        let request = try #require(model.reviewing)
        let sheet = ConfirmationState(request: request, rule: model.rule,
                                      onApprove: { model.approved($0) }, onDecline: { model.closedQuestion(request) })
        sheet.disappeared()
        model.refresh()
        model.closedQuestion(request)
        let history = try #require(engine.task(id)?.history)
        #expect(history.last?.text == TaskWords.declined("hold a Saturday visit"))
        #expect(!history.contains { $0.text == TaskWords.timedOut("hold a Saturday visit") })
        #expect(!heard.contains { $0.text.contains("timed out") })
    }

    // MARK: Approve while something covers Today

    /// A task's Approve tapped while a sheet is closing with a step held
    /// for after it hands off to the question sheet, as a `NeedsYou`
    /// question does: the question opens, covers the chat, and the held
    /// step is dropped rather than sweep the question away.
    @Test func aTaskApproveUnderACoverHandsOffLikeANeedsYouQuestion() throws {
        let rule = AskFirst.isolated()
        let asks = NeedsYou(rule: rule)
        _ = try #require(asks.ask(Self.bakery))
        let engine = LocalFakeEngine(rule: rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let model = FeedModel(sources: [], needsYou: asks, tasks: engine, place: .onDevice,
                              now: { ShowcaseScene.morning })
        let place = SheetHandoff.Place(section: .today, usesSidebar: false)
        let task = try #require(model.feed.needsYou.first { $0.id == id })
        let question = try #require(model.feed.needsYou.first { $0.request != nil })
        for item in [task, question] {
            var handoff = SheetHandoff()
            var ran = false
            // The reader is closing, with a step held for after it.
            let closing = HomeCover(usesSidebar: false, section: .today, showsShortcuts: false,
                                    readerOpen: true, questionOpen: model.reviewing != nil)
            #expect(handoff.start({ ran = true }, sheetOpen: closing.anySheetOpen, at: place) == nil)
            model.perform(item, talk: { _ in })
            let opened = try #require(model.reviewing)
            let cover = HomeCover(usesSidebar: false, section: .today, showsShortcuts: false,
                                  readerOpen: false, questionOpen: model.reviewing != nil)
            #expect(cover.questionOpen && cover.chatIsCovered && !cover.anySheetOpen)
            handoff.sheetClosed(stillOpen: cover.anySheetOpen, questionOpen: cover.questionOpen)?()
            #expect(!ran, "\(item.id)")
            #expect(handoff.waiting == nil)
            // The question is the one the card asked, in the same sheet.
            #expect(opened == (item.task?.question ?? item.request))
            model.reviewing = nil
        }
    }

    /// Every pair a task card button draws is one `Theme.textPairs` checks,
    /// over the card, and each reads.
    @Test(arguments: [ColorScheme.light, .dark])
    func everyCardButtonPairIsChecked(scheme: ColorScheme) {
        let pairs = Theme.textPairs(scheme)
        for base in ["backdrop top", "backdrop bottom", "sheet"] {
            for (text, background) in [("accentText", "accent wash on the card on \(base)"),
                                       ("secondaryText", "card on \(base)"),
                                       ("secondaryText", "disabled button on the card on \(base)")] {
                let pair = pairs.first { $0.text == text && $0.background == background }
                #expect(pair != nil, "\(text) on \(background)")
                #expect((pair?.contrast ?? 0) >= 4.5, "\(text) on \(background)")
            }
        }
        let primary = pairs.first { $0.text == "onAccent" && $0.background == "accent" }
        #expect((primary?.contrast ?? 0) >= 4.5)
    }

    /// The task card's Send, before there are words, is gray words on a
    /// neutral fill over the card, and that pair is checked.
    @Test(arguments: [ColorScheme.light, .dark])
    func theDisabledCardButtonIsAReadablePair(scheme: ColorScheme) throws {
        let pairs = Theme.textPairs(scheme).filter { $0.background.hasPrefix("disabled button on the card on ") }
        #expect(pairs.count == 3 * 4)
        for pair in pairs { #expect(pair.contrast >= 4.5, "\(pair.text) on \(pair.background)") }
        let source = try #require(ContrastGuardTests.sources().first { $0.name == "TaskCard.swift" }?.text)
        #expect(source.contains("Theme.accentText"))
        #expect(source.contains("Theme.secondaryText"))
    }

    @Test func theLiveShowcasePlaysInRealTime() {
        let engine = ShowcaseScene.liveTasks(rule: .isolated())
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine, drivesTasks: true,
                              place: .onDevice)
        #expect(model.drivesTasks)
        model.tick(7)
        #expect(engine.now == 7)
        #expect(engine.tasks.count == SampleTasks.all.count)
    }
}
#endif
