#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import Testing
#if canImport(UserNotifications)
import UserNotifications
#endif
@testable import PebbleUI

/// A monotonic clock tests can move forward.
private final class FlowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += .milliseconds(Int64(seconds * 1000)); lock.unlock() }
}

/// Stands in for the system's notifications: says what it is told to,
/// and writes down every call.
private final class FakeNotifier: QuestionNotifying, @unchecked Sendable {
    private let lock = NSLock()
    var grants: Bool
    /// What the system says when asked without asking, as Settings left it.
    var system: NudgePermission = .notDetermined
    private(set) var requests = 0
    private(set) var posted: [QuestionNudge] = []
    private(set) var delays: [TimeInterval] = []
    private(set) var removed: [String] = []
    /// Times every question's nudge was taken away, this launch's and older.
    private(set) var clears = 0
    /// Nudges posted and not taken away since, as the system would hold them.
    private(set) var live: [String] = []
    private var handler: (@MainActor @Sendable (String) -> Void)?
    /// Times a listener for taps was set.
    private(set) var listeners = 0

    init(grants: Bool = true) { self.grants = grants }

    func permission() async -> NudgePermission { readSystem() }
    private func readSystem() -> NudgePermission { lock.lock(); defer { lock.unlock() }; return system }
    func requestPermission() async -> Bool { countRequest() }
    private func countRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return grants
    }
    func post(_ nudge: QuestionNudge, after delay: TimeInterval) {
        lock.lock(); posted.append(nudge); delays.append(delay); live.append(nudge.id); lock.unlock()
    }
    func remove(_ ids: [String]) {
        lock.lock(); removed += ids; live.removeAll { ids.contains($0) }; lock.unlock()
    }
    func removeAll() { lock.lock(); clears += 1; live = []; lock.unlock() }
    /// Times Forget everything reached here.
    private(set) var forgets = 0
    func forget() { lock.lock(); clears += 1; forgets += 1; live = []; lock.unlock() }
    func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock(); self.handler = handler; listeners += 1; lock.unlock()
    }
    @MainActor func tap(_ taskID: String) { handler?(taskID) }
}

/// Counts a store's changes, from any thread.
private final class StoreChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func add() { lock.lock(); calls += 1; lock.unlock() }
}

/// The scripted engine, telling its listeners from another thread, as a
/// real engine may. Its snapshots reach Today a turn later, not at once.
private final class OffMainEngine: KeepsTasks, @unchecked Sendable {
    let inner: LocalFakeEngine
    init(_ inner: LocalFakeEngine) { self.inner = inner }

    /// Every snapshot on its way, so a test can wait for all to land.
    private let inFlight = DispatchGroup()
    private let lock = NSLock()
    private var sent = 0
    /// Snapshots handed to listeners so far.
    var delivered: Int { lock.lock(); defer { lock.unlock() }; return sent }

    /// Returns once every snapshot sent so far has been handed over.
    func drained() async {
        await withCheckedContinuation { done in inFlight.notify(queue: .global()) { done.resume() } }
    }

    var rule: AskFirst { inner.rule }
    var tasks: [AgentTask] { inner.tasks }
    var isSample: Bool { inner.isSample }
    func start(_ request: TaskRequest) -> String { inner.start(request) }
    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        inner.observe { [inFlight, weak self] snapshot in
            inFlight.enter()
            DispatchQueue.global().async {
                onChange(snapshot)
                self?.lock.lock(); self?.sent += 1; self?.lock.unlock()
                inFlight.leave()
            }
        }
    }
    func redirect(_ id: String, with instructions: String) -> Bool { inner.redirect(id, with: instructions) }
    func stop(_ id: String) -> Bool { inner.stop(id) }
    func dismiss(_ id: String) -> Bool { inner.dismiss(id) }
    func clear() -> ClearedTasks { inner.clear() }
    func retry(_ id: String) -> Bool { inner.retry(id) }
    func resume(_ id: String, with approval: Approval) -> TaskApproval { inner.resume(id, with: approval) }
    func questionClosed(_ request: ConfirmationRequest) { inner.questionClosed(request) }
    func refresh() { inner.refresh() }
    func saved() -> [SavedTask] { inner.saved() }
    func restore(_ saved: [SavedTask], now: Date) { inner.restore(saved, now: now) }
    func takeReceipts() -> [Receipt] { inner.takeReceipts() }
}

/// The Needs you flow through Today's own model: the question pinned, the
/// nudge offered in the moment, the sheet's yes, Not now and a timeout,
/// receipts, and what survives the app closing.
@MainActor
struct NeedsYouFlowModelTests {
    static let morning = ShowcaseScene.morning

    /// Today with the dentist search, and the flow around it.
    private func today(rule: AskFirst? = nil, store: TaskStore = .inMemory(), notifier: FakeNotifier = FakeNotifier(),
                       origin: Date = morning, start: Bool = true) -> (FeedModel, LocalFakeEngine, NeedsYouFlow) {
        let rule = rule ?? .isolated()
        let engine = LocalFakeEngine(rule: rule, origin: origin)
        if start { engine.start(SampleTasks.dentist) }
        // The device clock and the engine's agree, as they do in the app.
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: { "Pip" }, now: { origin + engine.now })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                              flow: flow, now: { origin + engine.now })
        return (model, engine, flow)
    }

    private func pinned(_ model: FeedModel) -> AgentTask? {
        FeedModel.pinnedTasks(in: model.feed).first
    }

    /// Opens the question from the card and answers it in the sheet's own state.
    private func sheet(_ model: FeedModel, _ task: AgentTask) throws -> ConfirmationState {
        model.review(task)
        let request = try #require(model.reviewing)
        return ConfirmationState(request: request, rule: model.rule,
                                 onApprove: { model.approved($0) },
                                 onDecline: { model.closedQuestion(request) })
    }

    private var receipts: (FeedModel) -> [Receipt] {
        { $0.feed.groups.flatMap(\.items).compactMap(\.receipt) }
    }

    // MARK: Asked once, in the moment

    @Test func theNudgeIsOfferedOnlyOnceAQuestionWaitsAndNeverAtLaunch() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(notifier: notifier)
        #expect(!flow.offersNudges, "nothing waits at launch, so nothing is offered")
        #expect(notifier.requests == 0)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        #expect(model.canApprove(task))
        #expect(flow.offersNudges)
        #expect(notifier.requests == 0, "the system asks only after a yes to the offer")
        flow.allowNudges()
        // Today built again while the system asks never brings the offer back.
        model.refresh()
        #expect(!flow.offersNudges)
        await flow.settled()
        #expect(notifier.requests == 1)
        #expect(flow.store.nudges == .allowed)
        #expect(!flow.offersNudges)
    }

    @Test func aWaitingQuestionNudgesOnceOnlyWhileAwayAndGoesWhenItCloses() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(notifier: notifier)
        engine.advance(by: 42)
        flow.allowNudges()
        await flow.settled()
        #expect(notifier.posted.isEmpty, "in front, the card is the nudge")
        flow.scene(isActive: false)
        let nudge = try #require(notifier.posted.first)
        #expect(nudge.title == "Pip has a question for you")
        #expect(nudge.taskID == pinned(model)?.id)
        #expect(notifier.delays == [NeedsYouFlow.nudgeDelay], "never at once")
        // Away long enough for it to show, then back.
        engine.advance(by: NeedsYouFlow.nudgeDelay + 1)
        flow.scene(isActive: true)
        #expect(notifier.removed == [nudge.id], "back in front, the nudge goes")
        flow.scene(isActive: false)
        #expect(notifier.posted.count == 1, "each question is nudged once")
    }

    @Test func aQuickSwitchAwayAndBackSendsNothingAndTheQuestionMayNudgeLater() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        flow.scene(isActive: false)
        engine.advance(by: 5)
        flow.scene(isActive: true)
        let first = try #require(notifier.posted.first)
        #expect(notifier.removed == [first.id], "back before it showed, so it never does")
        // It never showed, so leaving again for longer still nudges once.
        flow.scene(isActive: false)
        #expect(notifier.posted.map(\.taskID) == [task.id, task.id])
        #expect(notifier.delays == [NeedsYouFlow.nudgeDelay, NeedsYouFlow.nudgeDelay])
    }

    @Test func aQuestionAboutToTimeOutIsNeverNudged() async throws {
        let clock = FlowClock()
        let notifier = FakeNotifier()
        let rule = AskFirst.isolated(now: clock.now)
        let (model, engine, flow) = today(rule: rule, store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        clock.advance(AskFirst.defaultWindow - NeedsYouFlow.leastTimeLeft + 1)
        model.refresh()
        #expect(pinned(model) != nil, "still open")
        flow.scene(isActive: false)
        #expect(notifier.posted.isEmpty)
    }

    @Test func nudgesLeftFromBeforeGoAtLaunch() {
        let notifier = FakeNotifier()
        _ = today(notifier: notifier, start: false)
        #expect(notifier.clears == 1, "every question's nudge, not only this launch's")
    }

    @Test func turningNudgesOnOrOffInSettingsIsFollowedOnReturn() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .denied))
        let (model, engine, flow) = today(store: store, notifier: notifier)
        engine.advance(by: 42)
        await model.settled()
        #expect(pinned(model) != nil)
        notifier.system = .allowed
        flow.scene(isActive: false)
        #expect(notifier.posted.isEmpty)
        flow.scene(isActive: true)
        await flow.settled()
        #expect(store.nudges == .allowed)
        flow.scene(isActive: false)
        #expect(notifier.posted.count == 1)
        notifier.system = .denied
        flow.scene(isActive: true)
        await flow.settled()
        #expect(store.nudges == .denied)
        #expect(notifier.requests == 0, "only read, never asked")
    }

    @Test func noThanksStandsWhateverSettingsSay() async throws {
        let notifier = FakeNotifier()
        notifier.system = .allowed
        let store = TaskStore.inMemory(.init(nudges: .declined))
        let (_, engine, flow) = today(store: store, notifier: notifier)
        engine.advance(by: 42)
        flow.scene(isActive: false)
        flow.scene(isActive: true)
        await flow.settled()
        #expect(store.nudges == .declined)
    }

    @Test func theLineAfterNoThanksIsSaidToVoiceOver() async throws {
        let (_, engine, flow) = today()
        var heard: [String] = []
        flow.announce = { heard.append($0) }
        engine.advance(by: 42)
        flow.declineNudges()
        #expect(heard == [NudgeWords.off])

        let refused = FakeNotifier(grants: false)
        let (_, again, next) = today(notifier: refused)
        var also: [String] = []
        next.announce = { also.append($0) }
        again.advance(by: 42)
        next.allowNudges()
        await next.settled()
        #expect(also == [NudgeWords.off])
    }

    /// Yes, nudge me takes the offer away too, so once the system allows
    /// it a short line is said, and VoiceOver isn't left with nothing.
    @Test func aYesToNudgesIsSaidToVoiceOver() async throws {
        let (model, engine, flow) = today(notifier: FakeNotifier(grants: true))
        var heard: [String] = []
        flow.announce = { heard.append($0) }
        engine.advance(by: 42)
        #expect(pinned(model) != nil)
        #expect(flow.offersNudges)
        flow.allowNudges()
        await flow.settled()
        #expect(!flow.offersNudges)
        #expect(heard == [NudgeWords.on])
        #expect(flow.nudgeNote == nil, "nothing stays on screen; it was only said")
    }

    @Test func permissionDeniedNeverNudgesAndNeverAsksAgain() async throws {
        let notifier = FakeNotifier(grants: false)
        let store = TaskStore.inMemory()
        let (_, engine, flow) = today(store: store, notifier: notifier)
        engine.advance(by: 42)
        flow.allowNudges()
        await flow.settled()
        #expect(store.nudges == .denied)
        #expect(flow.nudgeNote == NudgeWords.off)
        flow.scene(isActive: false)
        #expect(notifier.posted.isEmpty)
        // The next launch with a new question offers nothing.
        let (_, again, next) = today(store: store, notifier: notifier)
        again.advance(by: 42)
        #expect(!next.offersNudges)
        next.scene(isActive: false)
        #expect(notifier.posted.isEmpty)
        #expect(notifier.requests == 1)
    }

    @Test func noThanksNeverAsksTheSystem() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(notifier: notifier)
        engine.advance(by: 42)
        flow.declineNudges()
        #expect(flow.store.nudges == .declined)
        #expect(flow.nudgeNote == NudgeWords.off)
        flow.scene(isActive: false)
        #expect(notifier.requests == 0)
        #expect(notifier.posted.isEmpty)
        // The line goes once nothing waits.
        try sheet(model, try #require(pinned(model))).cancel()
        await model.settled()
        #expect(flow.nudgeNote == nil)
    }

    @Test func aQuestionFromAForeignRuleIsNeitherPinnedNorNudgedNorAnswerable() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .allowed))
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: { "Pip" })
        // Today's rule is not the one the engine asked through.
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: engine, place: .onDevice,
                              flow: flow, now: { Self.morning })
        let task = try #require(engine.tasks.first)
        #expect(task.waitsForApproval)
        #expect(FeedModel.pinnedTasks(in: model.feed).isEmpty)
        #expect(!model.canApprove(task))
        model.review(task)
        #expect(model.reviewing == nil, "its Approve opens nothing")
        #expect(!flow.offersNudges)
        flow.scene(isActive: false)
        #expect(notifier.posted.isEmpty)
    }

    // MARK: The sheet's answer

    @Test func yesResumesOnceAndLeavesAReceiptThatCanBeCleared() async throws {
        let (model, engine, flow) = today()
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        let state = try sheet(model, task)
        #expect(state.tapPrimary() == .approved)
        #expect(state.tapPrimary() == .ignored, "a second tap does nothing")
        #expect(pinned(model) == nil, "the card leaves Needs you")
        engine.advance(by: 4)
        await model.settled()
        let receipt = try #require(receipts(model).first)
        #expect(receipts(model).count == 1)
        #expect(receipt.outcome == .done)
        #expect(model.isSample(ReceiptFeed.item(receipt)))
        #expect(engine.task(task.id)?.history.filter { $0.mark == .approved }.count == 1)
        model.clearReceipt(receipt)
        await model.settled()
        #expect(receipts(model).isEmpty)
        #expect(flow.store.receipts.isEmpty)
    }

    @Test func theSameYesHandedOverTwiceSaysNothingTheSecondTime() async throws {
        let (model, engine, _) = today()
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        model.review(task)
        let request = try #require(model.reviewing)
        guard case .approved(let approval) = model.rule.sayYes(to: request) else { throw CancellationError() }
        model.approved(approval)
        model.approved(approval)
        #expect(model.cardState(task.id).note == nil, "the first yes went through, so no line says it didn't")
        engine.advance(by: 4)
        await model.settled()
        #expect(receipts(model).count == 1)
    }

    /// PERMANENT GUARD. A yes is kept the moment the task goes on, before
    /// anything else runs, so an app closed right after it never asks again
    /// and never runs the step twice.
    @Test func aYesIsKeptBeforeAnythingElseRuns() async throws {
        let store = TaskStore.inMemory()
        let offMain: OffMainEngine
        let drain: @MainActor () async -> Void
        do {
            let rule = AskFirst.isolated()
            let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
            engine.start(SampleTasks.dentist)
            offMain = OffMainEngine(engine)
            let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
            let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: offMain,
                                  place: .onDevice, flow: flow, now: { Self.morning + engine.now })
            drain = model.drain
            engine.advance(by: 42)
            await offMain.drained()
            await model.settled()
            #expect(store.tasks.first?.phase == .waiting)
            let before = offMain.delivered
            #expect(try sheet(model, try #require(pinned(model))).tapPrimary() == .approved)
            // No await: the engine's own word of the yes hasn't reached Today yet.
            #expect(store.tasks.first?.phase == .approved)
            // Every snapshot from the yes lands on a live Today, and the
            // yes is still kept after each.
            await offMain.drained()
            await model.settled()
            #expect(offMain.delivered > before, "snapshots were on their way after the yes")
            #expect(store.tasks.first?.phase == .approved)
            engine.advance(by: 1)
        }
        // The app closes here, and nothing from before is left to write to
        // the store once the snapshots still on their way have landed.
        await offMain.drained()
        await drain()
        #expect(store.tasks.first?.phase == .approved)
        // Opening again never asks or runs it again.
        let (reopened, again, _) = today(store: store, origin: Self.morning + 43, start: false)
        again.advance(by: 60)
        await reopened.settled()
        #expect(pinned(reopened) == nil)
        #expect(again.tasks.first?.step == TaskWords.interrupted)
        #expect(store.tasks.isEmpty, "ended, so nothing is kept to pick up again")
        #expect(store.receipts.map(\.outcome) == [.mayBeDone])
    }

    @Test func notNowEndsTheQuestionHonestlyOnTheCard() async throws {
        let (model, engine, _) = today()
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        #expect(try sheet(model, task).cancel() == .closed)
        await model.settled()
        let ended = try #require(model.feed.groups.flatMap(\.items).compactMap(\.task).first { $0.id == task.id })
        let card = TaskCard(task: ended, time: "9:41 AM")
        #expect(card.closingLine == "You closed the question, so I didn't hold a Saturday visit.")
        #expect(!card.showsNotDone(try #require(ended.wrapUp)), "said once, not twice")
        #expect(receipts(model).isEmpty)
    }

    @Test func aTimeoutEndsTheQuestionHonestlyOnTheCard() async throws {
        let clock = FlowClock()
        let notifier = FakeNotifier()
        let rule = AskFirst.isolated(now: clock.now)
        let (model, engine, flow) = today(rule: rule, store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        flow.scene(isActive: false)
        let nudge = try #require(notifier.posted.first)
        clock.advance(AskFirst.defaultWindow + 1)
        model.refresh()
        #expect(pinned(model) == nil)
        let ended = try #require(engine.task(task.id))
        #expect(TaskCard(task: ended, time: "").closingLine == "That question timed out, so I didn't hold a Saturday visit.")
        #expect(notifier.removed.contains(nudge.id), "a question that timed out takes its nudge with it")
        #expect(receipts(model).isEmpty)
    }

    // MARK: Closed and opened again

    @Test func aQuestionIsStillPinnedAfterTheAppOpensAgain() async throws {
        let store = TaskStore.inMemory()
        let (first, engine, _) = today(store: store)
        engine.advance(by: 42)
        let before = try #require(pinned(first))
        // The app closes and opens: a new rule, a new engine, the same store.
        let (model, reopened, _) = today(store: store, origin: Self.morning + 60, start: false)
        let after = try #require(pinned(model))
        #expect(after.id == before.id)
        #expect(model.canApprove(after))
        #expect(after.question?.action == before.question?.action)
        #expect(after.question?.id != before.question?.id)
        // And it goes on once, after a yes here.
        #expect(try sheet(model, after).tapPrimary() == .approved)
        reopened.advance(by: 4)
        await model.settled()
        #expect(receipts(model).map(\.outcome) == [.done])
    }

    @Test func aYesUnderWayWhenTheAppClosedIsNeverReplayed() async throws {
        let store = TaskStore.inMemory()
        let (first, engine, _) = today(store: store)
        engine.advance(by: 42)
        #expect(try sheet(first, try #require(pinned(first))).tapPrimary() == .approved)
        let (model, reopened, _) = today(store: store, origin: Self.morning + 43, start: false)
        reopened.advance(by: 60)
        await model.settled()
        #expect(pinned(model) == nil)
        let task = try #require(reopened.tasks.first)
        #expect(task.step == TaskWords.interrupted)
        #expect(receipts(model).map(\.outcome) == [.mayBeDone])
        // The card agrees with the receipt: it may be done, so its label
        // never says it couldn't finish.
        let card = TaskCard(task: try #require(model.feed.groups.flatMap(\.items).compactMap(\.task).first),
                            time: "9:42 AM")
        #expect(card.spoken.hasPrefix(TaskWords.stoppedLabel))
        #expect(!card.spoken.contains(TaskWords.failedLabel))
        #expect(task.wrapUp?.underwayLine == "You said yes, so I'd already started to hold a Saturday visit. It may be done.")
    }

    /// The "I didn't" line is left off only when the closing line already
    /// names that same step.
    @Test func theNotDoneLineIsLeftOffOnlyForTheStepTheClosingLineNames() {
        func ended(closing: String, undone: String?, notDone: [String]) -> TaskCard {
            var task = AgentTask(id: "task:1", title: "A task", step: "Done.", state: .done,
                                 history: [TaskStep(closing, mark: .skipped, at: Self.morning, undone: undone)],
                                 wrapUp: TaskWrapUp(kept: [], notDone: notDone), startedAt: Self.morning)
            task.updatedAt = Self.morning
            return TaskCard(task: task, time: "")
        }
        let same = ended(closing: "You closed the question, so I didn't hold a Saturday visit.",
                         undone: "hold a Saturday visit", notDone: ["hold a Saturday visit"])
        #expect(!same.showsNotDone(TaskWrapUp(kept: [], notDone: ["hold a Saturday visit"])))
        let other = ended(closing: "You closed the question, so I didn't hold a Saturday visit.",
                          undone: "hold a Saturday visit", notDone: ["read their reviews"])
        #expect(other.showsNotDone(TaskWrapUp(kept: [], notDone: ["read their reviews"])))
        // Told by the step's mark, not its words: a closing line worded
        // some other way still keeps the line from being said twice.
        let reworded = ended(closing: "I left the Saturday visit for you to hold.",
                             undone: "hold a Saturday visit", notDone: ["hold a Saturday visit"])
        #expect(!reworded.showsNotDone(TaskWrapUp(kept: [], notDone: ["hold a Saturday visit"])))
        // And the words alone, with no mark, never hide it.
        let unmarked = ended(closing: "You closed the question, so I didn't hold a Saturday visit.",
                             undone: nil, notDone: ["hold a Saturday visit"])
        #expect(unmarked.showsNotDone(TaskWrapUp(kept: [], notDone: ["hold a Saturday visit"])))
    }

    /// Every way the engine leaves a step undone marks it, so each closing
    /// line keeps the "I didn't" line from showing twice.
    @Test func everyStepLeftUndoneIsMarked() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let question = try #require(engine.tasks.first?.question)
        rule.withdraw(question)
        engine.questionClosed(question)
        let step = try #require(engine.tasks.first?.history.last)
        #expect(step.mark == .skipped)
        #expect(step.undone == "hold a Saturday visit")
        // Kept with the task while the app is closed, too.
        let saved = SavedTask.Step(text: step.text, mark: step.mark, at: step.at, undone: step.undone)
        let decoded = try JSONDecoder().decode(SavedTask.Step.self, from: JSONEncoder().encode(saved))
        #expect(decoded.undone == "hold a Saturday visit")
    }

    // MARK: Forget everything

    @Test func forgetEverythingClearsReceiptsAndNudges() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .allowed))
        let (model, engine, flow) = today(store: store, notifier: notifier)
        engine.advance(by: 42)
        #expect(try sheet(model, try #require(pinned(model))).tapPrimary() == .approved)
        engine.advance(by: 4)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        flow.scene(isActive: false)
        let nudge = try #require(notifier.posted.first)
        await model.settled()
        #expect(receipts(model).count == 1)
        #expect(notifier.live == [nudge.id])
        #expect(!model.usedYes.isEmpty)
        model.forgetTasks()
        await model.settled()
        #expect(receipts(model).isEmpty)
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(store.nudges == .allowed, "only the nudge choice stays")
        #expect(notifier.posted.contains(nudge), "it was posted")
        #expect(notifier.live.isEmpty, "and it is gone")
        #expect(notifier.clears == 2, "once at launch, and again for every nudge, old ones too")
        #expect(notifier.forgets == 1, "and a nudge opened but not yet handed over goes too")
        #expect(model.usedYes.isEmpty, "not even the ids of yeses stay")
    }

    /// PERMANENT GUARD. A yes handed over before Forget everything is dead
    /// after it: nothing goes on, no receipt is made, and nothing is kept.
    @Test func aYesFromBeforeForgetEverythingDoesNothingAfterIt() async throws {
        let store = TaskStore.inMemory()
        let heard = StoreChanges()
        _ = store.observe { heard.add() }
        let (model, engine, _) = today(store: store)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        model.review(task)
        let request = try #require(model.reviewing)
        guard case .approved(let approval) = model.rule.sayYes(to: request) else { throw CancellationError() }
        model.forgetTasks()
        await model.settled()
        let changes = heard.count
        model.approved(approval)
        engine.advance(by: 10)
        await model.settled()
        #expect(engine.tasks.isEmpty, "nothing was picked up again")
        #expect(engine.takeReceipts().isEmpty)
        #expect(receipts(model).isEmpty)
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(heard.count == changes, "nothing was written")
        #expect(!model.usedYes.contains(approval.id))
    }

    /// PERMANENT GUARD. Forget everything in one window forgets in every
    /// other: their receipts go, and so do the ids of their yeses.
    @Test func forgetEverythingInOneWindowForgetsInTheOther() async throws {
        let store = TaskStore.inMemory()
        let flow = NeedsYouFlow(store: store, notifier: FakeNotifier(), agentName: { "Pip" })
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        func window() -> FeedModel {
            FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice, flow: flow,
                      now: { Self.morning + engine.now })
        }
        let first = window()
        let second = window()
        #expect(try sheet(second, try #require(pinned(second))).tapPrimary() == .approved)
        engine.advance(by: 4)
        await first.settled()
        await second.settled()
        #expect(receipts(first).count == 1)
        #expect(receipts(second).count == 1)
        #expect(!second.usedYes.isEmpty)
        first.forgetTasks()
        await first.settled()
        await second.settled()
        #expect(receipts(first).isEmpty)
        #expect(receipts(second).isEmpty, "the other window's receipts go too")
        #expect(second.usedYes.isEmpty, "and the ids of its yeses")
    }

    /// Forget everything lets go of a nudge being brought into view, and of
    /// which questions were nudged, since both name forgotten tasks.
    @Test func forgetEverythingLetsGoOfTheNudgeInView() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        flow.scene(isActive: false)
        #expect(notifier.posted.count == 1)
        notifier.tap(task.id)
        #expect(flow.focus == task.id)
        model.forgetTasks()
        #expect(flow.focus == nil)
        #expect(flow.told.isEmpty, "not even which questions were nudged")
        // A new question nudges as any would.
        flow.scene(isActive: true)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        await model.settled()
        #expect(pinned(model) != nil)
        flow.scene(isActive: false)
        #expect(notifier.posted.count == 2)
    }

    /// PERMANENT GUARD. Forget everything reaches the store with no task
    /// at all: receipts left from before, and nothing else, still go, and
    /// so does the file.
    @Test func forgetEverythingWithOnlyReceiptsLeavesNoFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("tasks.json")
        let store = TaskStore(fileURL: url, forgetMarker: folder.appendingPathComponent("pending/tasks-forgotten"))
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let question = try #require(engine.tasks.first?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw CancellationError() }
        _ = engine.resume(engine.tasks[0].id, with: approval)
        engine.advance(by: 4)
        store.keep(engine)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let flow = NeedsYouFlow(store: store, notifier: FakeNotifier(), agentName: { "Pip" })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: nil, place: .onDevice,
                              flow: flow, now: { Self.morning })
        #expect(!model.hasTasks)
        #expect(model.hasSomethingToForget, "a receipt alone is something to forget")
        // Both memory screens offer it.
        #expect(MemoryView.showsForgetEverything(hasNotes: false, mayHaveWords: false,
                                                 holdsMore: model.hasSomethingToForget))
        #expect(!MemoryView.showsForgetEverything(hasNotes: false, mayHaveWords: false, holdsMore: false))
        let fallback = MemoryUnavailableView(hasTasks: model.hasSomethingToForget, onForgetTasks: { model.forgetTasks() })
        fallback.forgetTasks()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.receipts.isEmpty)
        #expect(!model.hasSomethingToForget)
        #expect(model.tasksForgotten, "the screen can say they went")
    }

    /// Tasks a late read of the store found reach Today's engine on their
    /// own, with no change from Today: a step said yes to that was under
    /// way gets its card and its receipt.
    @Test(.enabled(if: geteuid() != 0, "file permissions don't stop root"))
    func tasksALateReadFoundArePickedUpByToday() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: folder.appendingPathComponent("tasks.json").path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("tasks.json")
        let marker = folder.appendingPathComponent("pending/tasks-forgotten")
        let rule = AskFirst.isolated()
        let before = LocalFakeEngine(rule: rule, origin: Self.morning)
        before.start(SampleTasks.dentist)
        before.advance(by: 42)
        let question = try #require(before.tasks.first?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw CancellationError() }
        _ = before.resume(before.tasks[0].id, with: approval)
        TaskStore(fileURL: url, forgetMarker: marker).keep(before)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        // Opened before the file can be read.
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        let (model, engine, _) = today(store: store, origin: Self.morning + 43, start: false)
        #expect(engine.tasks.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        // Anything that reads the store now reads the file.
        _ = store.receipts
        await model.settled()
        await model.settled()
        let back = try #require(engine.tasks.first)
        #expect(back.step == TaskWords.interrupted)
        #expect(receipts(model).map(\.outcome) == [.mayBeDone])
        #expect(store.tasks.isEmpty)
    }

    @Test func forgetEverythingFromTheMemoryScreenClearsReceipts() throws {
        let store = TaskStore.inMemory()
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let question = try #require(engine.tasks.first?.question)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw CancellationError() }
        _ = engine.resume(engine.tasks[0].id, with: approval)
        engine.advance(by: 4)
        store.keep(engine)
        let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: nil, place: .onDevice,
                              flow: flow, now: { Self.morning })
        #expect(receipts(model).count == 1, "receipts show even with no engine")
        let memory = HomeView.memoryModel(store: ShowcaseScene.emptyMemory(), model: LocalStubModel(),
                                          onForgetEverything: { model.forgetTasks() })
        memory.forgetEverything()
        #expect(receipts(model).isEmpty)
        #expect(store.receipts.isEmpty)
    }

    // MARK: A nudge opened

    @Test func openingANudgeBringsItsCardIntoView() async throws {
        let notifier = FakeNotifier()
        let (model, engine, flow) = today(notifier: notifier)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        notifier.tap(task.id)
        #expect(flow.focus == task.id)
        #expect(model.reviewing == nil, "opening a nudge brings the card, never the sheet")
    }

    /// VoiceOver goes to the card a nudge brought into view.
    @Test func openingANudgeTakesVoiceOverToItsCard() async throws {
        let (model, engine, _) = today()
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        model.focusCard(task.id)
        #expect(model.cardState(task.id).pendingFocus == .summary)
        model.focusCard("task:404")
        #expect(model.feed.needsYou.allSatisfy { $0.id != "task:404" })
    }

    /// A nudge tapped after its question timed out, or for a task this
    /// launch never knew, opens no sheet and makes nothing answerable.
    @Test func aStaleOrUnknownNudgeOpensNothing() async throws {
        let clock = FlowClock()
        let notifier = FakeNotifier()
        let rule = AskFirst.isolated(now: clock.now)
        let (model, engine, flow) = today(rule: rule, store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        let task = try #require(pinned(model))
        flow.scene(isActive: false)
        clock.advance(AskFirst.defaultWindow + 1)
        model.refresh()
        #expect(pinned(model) == nil)
        notifier.tap(task.id)
        #expect(model.reviewing == nil)
        let ended = try #require(engine.task(task.id))
        #expect(!model.canApprove(ended))
        model.review(ended)
        #expect(model.reviewing == nil, "its card opens nothing either")
        flow.focus = nil
        notifier.tap("task:404")
        #expect(flow.focus == nil, "a task never pinned is never brought into view")
        #expect(model.reviewing == nil)
        #expect(engine.tasks.allSatisfy { !model.canApprove($0) })
    }

    /// PERMANENT GUARD. While a cloud preview waits for its answer, going
    /// away nudges nothing. Once it is answered, the question may nudge.
    @Test func aWaitingCloudPreviewHoldsTheNudge() async throws {
        let notifier = FakeNotifier()
        let (model, engine, _) = today(store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        #expect(pinned(model) != nil)
        model.preview(waiting: true)
        model.scene(isActive: false)
        #expect(notifier.posted.isEmpty, "the preview covers the screen, so the question couldn't be answered")
        model.preview(waiting: false)
        #expect(notifier.posted.map(\.taskID) == [pinned(model)?.id], "answered, so the question nudges")
        #expect(notifier.delays == [NeedsYouFlow.nudgeDelay])
    }

    /// The offer sits closer under Needs you than sections do, but never so
    /// close it overlaps: the room between them is fixed, not scaled, so
    /// this holds at AX5 as at any size.
    @Test func theNudgeOfferNeverOverlapsNeedsYou() {
        #expect(FeedView.offerTuck > 0)
        #expect(FeedView.sectionSpacing - FeedView.offerTuck >= 8)
    }

    @Test func theNudgeWaitAndTheLeastTimeLeftArePinned() {
        #expect(NeedsYouFlow.nudgeDelay == 30)
        #expect(NeedsYouFlow.leastTimeLeft == 90)
    }

    /// A question with exactly `leastTimeLeft` to go still nudges; one
    /// with a second less doesn't.
    @Test(arguments: [(0.0, true), (1.0, false)])
    func aQuestionAtTheEdgeOfTimeLeft(short: Double, nudges: Bool) async throws {
        let clock = FlowClock()
        let notifier = FakeNotifier()
        let rule = AskFirst.isolated(now: clock.now)
        let (model, engine, flow) = today(rule: rule, store: .inMemory(.init(nudges: .allowed)), notifier: notifier)
        engine.advance(by: 42)
        clock.advance(AskFirst.defaultWindow - NeedsYouFlow.leastTimeLeft + short)
        model.refresh()
        let task = try #require(pinned(model))
        #expect(rule.timeLeft(try #require(task.question)) == NeedsYouFlow.leastTimeLeft - short)
        flow.scene(isActive: false)
        #expect(notifier.posted.isEmpty == !nudges)
    }

    // MARK: One per app

    /// PERMANENT GUARD. Every window shares the app's one flow: a second
    /// window never takes away the first one's nudge or its taps, and
    /// nothing nudges while any window is in front.
    @Test func aSecondWindowSharesTheFlow() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .allowed))
        let flow = NeedsYouFlow.forApp(store: store, notifier: notifier, agentName: { "Pip" })
        #expect(NeedsYouFlow.forApp(store: store, notifier: notifier, agentName: { "Pip" }) === flow)
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let first = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                              flow: flow, now: { Self.morning + engine.now })
        first.scene(isActive: false)
        let nudge = try #require(notifier.posted.first)
        // A second window opens, in front.
        let second = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                               flow: NeedsYouFlow.forApp(store: store, notifier: notifier, agentName: { "Pip" }),
                               now: { Self.morning + engine.now })
        second.scene(isActive: true)
        #expect(notifier.clears == 1, "nudges from before go once, as the app starts")
        #expect(notifier.listeners == 1, "taps have one listener")
        #expect(notifier.removed == [nudge.id], "one window in front, so the nudge goes")
        // The first window coming back and going again nudges nothing
        // while the second is still in front.
        first.scene(isActive: true)
        first.scene(isActive: false)
        #expect(notifier.posted.count == 1)
        // A tap reaches the flow both windows read.
        let task = try #require(FeedModel.pinnedTasks(in: second.feed).first)
        notifier.tap(task.id)
        #expect(flow.focus == task.id)
        #expect(first.flow === second.flow)
    }

    /// Each window's home screen gets its flow from here, so all share one,
    /// and a nudge says the name the person chose, not the product's.
    @Test func everyHomeScreenGetsTheAppsFlow() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .allowed))
        let names = InMemoryAgentNameStore(stored: "Pip")
        let one = HomeView.flow(store: store, notifier: notifier, brand: Brand(name: "Nova"), names: names)
        let two = HomeView.flow(store: store, notifier: notifier, brand: Brand(name: "Nova"), names: names)
        #expect(one === two)
        #expect(notifier.clears == 1)
        #expect(notifier.listeners == 1)
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                              flow: one, now: { Self.morning + engine.now })
        model.scene(isActive: false)
        #expect(notifier.posted.map(\.title) == ["Pip has a question for you"])
    }

    /// PERMANENT GUARD. The app's flow is one per store, held only while a
    /// window holds it. Two stores, as two tests running at once have, get
    /// two flows, each with its own notifier.
    @Test func eachStoreGetsAFlowOfItsOwn() {
        let firstNotifier = FakeNotifier()
        let secondNotifier = FakeNotifier()
        let firstStore = TaskStore.inMemory()
        let secondStore = TaskStore.inMemory()
        let first = NeedsYouFlow.forApp(store: firstStore, notifier: firstNotifier, agentName: { "Pip" })
        let second = NeedsYouFlow.forApp(store: secondStore, notifier: secondNotifier, agentName: { "Pip" })
        #expect(first !== second)
        #expect(first.store === firstStore)
        #expect(second.store === secondStore)
        #expect(firstNotifier.clears == 1 && firstNotifier.listeners == 1)
        #expect(secondNotifier.clears == 1 && secondNotifier.listeners == 1)
        #expect(NeedsYouFlow.forApp(store: firstStore, notifier: secondNotifier, agentName: { "Pip" }) === first)
        // Held weakly: once no window holds it, the next is a new one.
        weak var gone: NeedsYouFlow?
        do {
            let store = TaskStore.inMemory()
            gone = NeedsYouFlow.forApp(store: store, notifier: nil, agentName: { "Pip" })
        }
        #expect(gone == nil)
    }

    /// PERMANENT GUARD. Each window is known by a token made for it and
    /// never used again, so a window that says it closed late can never
    /// take away what a newer window has pinned.
    @Test func aWindowClosingLateNeverTakesANewWindowsQuestions() async throws {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory(.init(nudges: .allowed))
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: { "Pip" })
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        var old: FeedModel? = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                                        flow: flow, now: { Self.morning + engine.now })
        let oldWindow = try #require(old?.window)
        old = nil
        let new = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice,
                            flow: flow, now: { Self.morning + engine.now })
        #expect(new.window != oldWindow)
        // The old window's word arrives after the new one has pinned.
        flow.closed(oldWindow)
        await Task.yield()
        new.scene(isActive: false)
        #expect(notifier.posted.count == 1, "the new window's question is still pinned, so it nudges")
    }

    /// Only the window in front brings an opened nudge into view. A window
    /// that can't show it now lets it go, so it never jumps there later.
    @Test func onlyTheWindowInFrontTakesAnOpenedNudge() async throws {
        let notifier = FakeNotifier()
        let (first, engine, flow) = today(notifier: notifier)
        let second = FeedModel(sources: [], needsYou: NeedsYou(rule: first.rule), tasks: engine, place: .onDevice,
                               flow: flow, now: { Self.morning + engine.now })
        engine.advance(by: 42)
        await first.settled()
        let task = try #require(pinned(first))
        first.scene(isActive: true)
        second.scene(isActive: true)
        notifier.tap(task.id)
        #expect(!flow.takesOpened(in: first.window, canShow: true), "the other window is in front")
        #expect(flow.focus == task.id, "and it is left for that window")
        #expect(flow.takesOpened(in: second.window, canShow: true))
        // In front but busy, as during the first run: let go.
        #expect(!flow.takesOpened(in: second.window, canShow: false))
        #expect(flow.focus == nil)
        #expect(!flow.takesOpened(in: second.window, canShow: true), "nothing left to take")
    }

    #if canImport(UserNotifications)
    /// PERMANENT GUARD. A nudge carries only that the agent has a question
    /// and which card to open. Nothing for a lock screen to show.
    @Test func aNudgeShowsNothingOfTheQuestion() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.morning)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let task = try #require(engine.tasks.first)
        let nudge = QuestionNudge(question: try #require(task.question), taskID: task.id, agentName: "Pip")
        let content = LocalQuestionNotifier.content(for: nudge)
        #expect(content.title == "Pip has a question for you")
        #expect(content.body.isEmpty)
        #expect(content.subtitle.isEmpty)
        #expect(content.attachments.isEmpty)
        #expect(content.userInfo.count == 1)
        #expect(LocalQuestionNotifier.taskID(in: content.userInfo) == task.id)
        #expect(LocalQuestionNotifier.taskID(in: ["other": "x"]) == nil)
    }

    /// PERMANENT GUARD. The notification delegate answers through the
    /// completion forms. The async forms answer UIKit off the main thread,
    /// which stopped the app the moment a nudge was opened.
    @Test func theNudgeDelegateNeverUsesTheAsyncForms() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/NeedsYouFlow.swift"),
                              encoding: .utf8)
        let code = String(SwiftSource(text).code)
        #expect(code.contains("withCompletionHandler completionHandler: @escaping () -> Void"))
        #expect(code.range(of: #"UNNotificationResponse\)\s*async"#, options: .regularExpression) == nil)
        #expect(code.range(of: #"willPresent notification: UNNotification\)\s*async"#, options: .regularExpression) == nil)
    }

    @Test func onlyQuestionNudgesAreHiddenWhileTheAppIsInFront() throws {
        #expect(LocalQuestionNotifier.presentation(inThread: LocalQuestionNotifier.thread).isEmpty)
        #expect(LocalQuestionNotifier.presentation(inThread: "other") == [.banner, .list, .sound])
        let question = try #require(AskFirst.isolated().ask(SampleTasks.holdVisit))
        let content = LocalQuestionNotifier.content(for: QuestionNudge(question: question, taskID: "task:1", agentName: "Pip"))
        #expect(content.threadIdentifier == LocalQuestionNotifier.thread)
    }

    @Test func aNudgeOpenedBeforeAnythingListensIsHandedOverOnce() async throws {
        let notifier = LocalQuestionNotifier()
        notifier.open("task:7")
        var heard: [String] = []
        notifier.onOpen { heard.append($0) }
        // Handed over a turn later.
        await notifier.handOver?.value
        #expect(heard == ["task:7"])
        // A listener set after it has been handed over gets nothing: there
        // is nothing on its way to it.
        var later: [String] = []
        notifier.onOpen { later.append($0) }
        #expect(notifier.handOver == nil)
        #expect(later.isEmpty)
        #expect(heard == ["task:7"], "once, not twice")
    }

    /// Forget everything drops a nudge opened before anything listened, so
    /// a task from before the forget never reaches the next listener.
    @Test func forgetDropsANudgeOpenedBeforeAnythingListens() async throws {
        let notifier = LocalQuestionNotifier()
        notifier.open("task:7")
        notifier.forget()
        var heard: [String] = []
        notifier.onOpen { heard.append($0) }
        #expect(notifier.handOver == nil)
        #expect(heard.isEmpty)
    }

    /// Away from the app, as in a test, there is no notification center,
    /// so nothing here may reach for one.
    @Test func aNotifierThatWasNeverInstalledTouchesNothing() throws {
        let notifier = LocalQuestionNotifier()
        let question = try #require(AskFirst.isolated().ask(SampleTasks.holdVisit))
        notifier.post(QuestionNudge(question: question, taskID: "task:1", agentName: "Pip"), after: 30)
        notifier.remove(["question:1"])
        notifier.removeAll()
        notifier.forget()
        #expect(!notifier.installed)
    }

    /// PERMANENT GUARD. Taking every nudge away takes both kinds, those
    /// still to come and those shown, and only from the questions' thread.
    /// Otherwise a nudge set to show 30 seconds on would still show after
    /// Forget everything.
    @Test func removingEveryNudgeTakesThePendingAndTheShown() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/NeedsYouFlow.swift"),
                              encoding: .utf8)
        let source = SwiftSource(text)
        let code = String(source.code)
        let start = try #require(code.range(of: "public func removeAll()"))
        let body = String(code[start.upperBound...].prefix(1200))
        for call in ["getPendingNotificationRequests", "removePendingNotificationRequests",
                     "getDeliveredNotifications", "removeDeliveredNotifications"] {
            #expect(body.contains(call), "\(call)")
        }
        #expect(body.components(separatedBy: "threadIdentifier == Self.thread").count == 3,
                "both kinds are taken only from the questions' thread")
        let forget = try #require(code.range(of: "public func forget()"))
        let forgetBody = String(code[forget.upperBound...].prefix(200))
        #expect(forgetBody.contains("waitingOpen = nil"))
        #expect(forgetBody.contains("removeAll()"))
    }
    #endif

    // MARK: What the sheet and the receipt show

    @Test func theSheetSaysWhatHappensToWhomAndWhatIsShared() throws {
        #expect(ConfirmationSheet.detailsLabel(.sharePersonalInfo) == ConfirmationWords.sharedLabel)
        #expect(ConfirmationSheet.detailsLabel(.send) == ConfirmationWords.whatLabel)
        #expect(SampleTasks.holdVisit.outcome != nil)
        let receipt = Receipt(action: SampleTasks.holdVisit, taskTitle: SampleTasks.dentistTitle,
                              approvedAt: Self.morning, endedAt: Self.morning, outcome: .done, isSample: true)
        let card = ReceiptCard(receipt: receipt, time: "9:41 AM", onClear: {})
        #expect(card.rows.map(\.label) == [ConfirmationWords.whereLabel, ConfirmationWords.sharedLabel,
                                           ConfirmationWords.happensLabel])
        #expect(card.spoken.hasPrefix("Example. You said yes. Your details for Maple Dental"))
    }

    // MARK: The largest text

    /// The size a view takes when offered `width`, as rendered.
    private func measured(_ view: some View, width: CGFloat, text: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, text))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try #require(renderer.cgImage)
        return CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
    }

    @Test func labelsStackOverTheirValuesOnlyAtAccessibilitySizes() {
        for size in DynamicTypeSize.allCases {
            #expect(ConfirmationSheet.stacksLabels(at: size) == size.isAccessibilitySize, "\(size)")
        }
    }

    /// At AX5 on an iPhone, a label in its own column would leave the value,
    /// the part being said yes to, a sliver. Over it, the value has the
    /// whole width, so it takes far fewer lines.
    @Test func atTheLargestTextTheValueGetsTheWholeWidth() throws {
        let value = SampleTasks.holdVisit.details
        func row(stacked: Bool) -> some View {
            LabeledRow(stacked: stacked, labelWidth: 92 * 3.5, spacing: 10) {
                Text(ConfirmationWords.happensLabel)
            } value: {
                Text(value)
            }
            .font(.footnote)
        }
        let side = try measured(row(stacked: false), width: 361, text: .accessibility5)
        let over = try measured(row(stacked: true), width: 361, text: .accessibility5)
        #expect(over.width <= 361.5)
        #expect(over.height * 2 < side.height, "stacked \(over.height), side by side \(side.height)")
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func theReceiptAndTheSheetFitAnIPhoneAt(text: DynamicTypeSize) throws {
        let receipt = Receipt(action: SampleTasks.holdVisit, taskTitle: SampleTasks.dentistTitle,
                              approvedAt: Self.morning, endedAt: Self.morning, outcome: .done, isSample: true)
        let card = try measured(ReceiptCard(receipt: receipt, time: "9:41 AM", onClear: {}), width: 361, text: text)
        #expect(card.width <= 361.5, "the receipt is \(card.width) wide at \(text)")
        let rule = AskFirst.isolated()
        let request = try #require(rule.ask(SampleTasks.holdVisit))
        let sheet = ConfirmationSheet(request: request, rule: rule, isExample: true, onApprove: { _ in }, onDecline: {})
            .unscrolled()
        let size = try measured(sheet, width: 393, text: text)
        #expect(size.width <= 393.5, "the sheet is \(size.width) wide at \(text)")
        // Its labels go over their values and the sheet grows to hold
        // them, rather than squeeze them in beside. Fonts don't grow with
        // the text size where these tests run on a Mac, so only the
        // stacking shows here.
        let usual = try measured(sheet, width: 393, text: .large)
        if text.isAccessibilitySize {
            #expect(size.height > usual.height, "\(size.height) at \(text), \(usual.height) usually")
        }
        try smokeRender(ConfirmationSheet(request: request, rule: rule, isExample: true, onApprove: { _ in }, onDecline: {})
            .environment(\.dynamicTypeSize, text)
            .frame(width: 393, height: 852))
    }

    /// PERMANENT GUARD. The receipt's rows follow the sheet's rule: at
    /// accessibility sizes each label goes over its value, so the receipt
    /// grows rather than squeeze what was said yes to. Fonts don't grow
    /// where these tests run, so the stacking is what makes it taller.
    @Test func theReceiptStacksItsLabelsAtAccessibilitySizes() throws {
        let receipt = Receipt(action: SampleTasks.holdVisit, taskTitle: SampleTasks.dentistTitle,
                              approvedAt: Self.morning, endedAt: Self.morning, outcome: .done, isSample: true)
        let card = ReceiptCard(receipt: receipt, time: "9:41 AM", onClear: {})
        let usual = try measured(card, width: 361, text: .large)
        for size in DynamicTypeSize.allCases {
            let height = try measured(card, width: 361, text: size).height
            if ConfirmationSheet.stacksLabels(at: size) {
                #expect(height > usual.height + 3 * 10, "\(size): \(height), usually \(usual.height)")
            } else {
                #expect(abs(height - usual.height) < 1, "\(size): \(height), usually \(usual.height)")
            }
        }
    }

    /// docs/VOICE.md: no dash in anything said, the lines VoiceOver puts
    /// together for a receipt and a task card included.
    @Test func theSpokenCardsUseNoDash() throws {
        let dashes: [Character] = ["\u{2014}", "\u{2013}"]
        var spoken: [String] = []
        for outcome in [Receipt.Outcome.done, .mayBeDone] {
            for sample in [true, false] {
                let receipt = Receipt(action: SampleTasks.holdVisit, taskTitle: SampleTasks.dentistTitle,
                                      approvedAt: Self.morning, endedAt: Self.morning, outcome: outcome, isSample: sample)
                spoken.append(ReceiptCard(receipt: receipt, time: "9:41 AM", onClear: {}).spoken)
            }
        }
        // Every state a task card can be in: going, asking, closed, timed
        // out, done after a yes, and stopped after a yes.
        let clock = FlowClock()
        let rule = AskFirst.isolated(now: clock.now)
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        let ids = (0..<4).map { _ in engine.start(SampleTasks.dentist) }
        engine.advance(by: 10)
        var tasks = engine.tasks
        engine.advance(by: 32)
        tasks += engine.tasks
        let asked = ids.compactMap { id in engine.task(id)?.question.map { (id, $0) } }
        rule.withdraw(asked[0].1)
        engine.questionClosed(asked[0].1)
        _ = engine.resume(asked[1].0, with: try #require({
            if case .approved(let yes) = rule.sayYes(to: asked[1].1) { return yes } else { return nil }
        }()))
        _ = engine.resume(asked[2].0, with: try #require({
            if case .approved(let yes) = rule.sayYes(to: asked[2].1) { return yes } else { return nil }
        }()))
        engine.stop(asked[2].0)
        engine.advance(by: 4)
        clock.advance(AskFirst.defaultWindow + 1)
        engine.refresh()
        tasks += engine.tasks
        for task in tasks {
            for sample in [true, false] {
                let card = TaskCard(task: task, time: "9:41 AM", isSample: sample)
                spoken.append(card.spoken)
                spoken += [card.closingLine, task.wrapUp?.notDoneLine, task.wrapUp?.underwayLine].compactMap { $0 }
            }
        }
        #expect(spoken.count > 20)
        for line in spoken {
            #expect(!line.contains(where: dashes.contains), "dash in: \(line)")
        }
    }

    @Test("Smoke: the ask scenes draw", arguments: [ShowcaseScene.askWaiting, .askSheet, .askAnswered, .askClosed],
          [ColorScheme.light, .dark])
    func theAskScenesDraw(scene: ShowcaseScene, scheme: ColorScheme) throws {
        try smokeRender(scene.view(brand: Brand(name: "Nova"))
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 852))
    }

    @Test func eachAskSceneShowsItsMoment() throws {
        func dentist(_ scene: ShowcaseScene) -> AgentTask? {
            ShowcaseScene.askTasks(scene, rule: .isolated()).tasks.first { $0.title == SampleTasks.dentistTitle }
        }
        #expect(dentist(.askWaiting)?.waitsForApproval == true)
        #expect(dentist(.askAnswered)?.state == .done)
        #expect(dentist(.askAnswered)?.history.contains { $0.mark == .approved } == true)
        #expect(dentist(.askClosed)?.history.last?.text == "You closed the question, so I didn't hold a Saturday visit.")
    }
}
#endif
