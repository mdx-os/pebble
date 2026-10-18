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
    func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock(); self.handler = handler; listeners += 1; lock.unlock()
    }
    @MainActor func tap(_ taskID: String) { handler?(taskID) }
}

/// The scripted engine, telling its listeners from another thread, as a
/// real engine may. Its snapshots reach Today a turn later, not at once.
private final class OffMainEngine: KeepsTasks, @unchecked Sendable {
    let inner: LocalFakeEngine
    init(_ inner: LocalFakeEngine) { self.inner = inner }

    var rule: AskFirst { inner.rule }
    var tasks: [AgentTask] { inner.tasks }
    var isSample: Bool { inner.isSample }
    func start(_ request: TaskRequest) -> String { inner.start(request) }
    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        inner.observe { snapshot in DispatchQueue.global().async { onChange(snapshot) } }
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
        do {
            let rule = AskFirst.isolated()
            let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
            engine.start(SampleTasks.dentist)
            let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
            let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: OffMainEngine(engine),
                                  place: .onDevice, flow: flow, now: { Self.morning + engine.now })
            engine.advance(by: 42)
            for _ in 0..<50 where pinned(model) == nil {
                try await Task.sleep(for: .milliseconds(20))
                await model.settled()
            }
            #expect(store.tasks.first?.phase == .waiting)
            #expect(try sheet(model, try #require(pinned(model))).tapPrimary() == .approved)
            // No await: the engine's own word of the yes hasn't reached Today yet.
            #expect(store.tasks.first?.phase == .approved)
        }
        // The app closes here, and nothing from before is left to write to
        // the store once the snapshots still on their way have landed.
        try await Task.sleep(for: .milliseconds(100))
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
        func ended(closing: String, notDone: [String]) -> TaskCard {
            var task = AgentTask(id: "task:1", title: "A task", step: "Done.", state: .done,
                                 history: [TaskStep(closing, mark: .skipped, at: Self.morning)],
                                 wrapUp: TaskWrapUp(kept: [], notDone: notDone), startedAt: Self.morning)
            task.updatedAt = Self.morning
            return TaskCard(task: task, time: "")
        }
        let same = ended(closing: "You closed the question, so I didn't hold a Saturday visit.",
                         notDone: ["hold a Saturday visit"])
        #expect(!same.showsNotDone(TaskWrapUp(kept: [], notDone: ["hold a Saturday visit"])))
        let other = ended(closing: "You closed the question, so I didn't hold a Saturday visit.",
                          notDone: ["read their reviews"])
        #expect(other.showsNotDone(TaskWrapUp(kept: [], notDone: ["read their reviews"])))
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
        #expect(model.usedYes.isEmpty, "not even the ids of yeses stay")
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

    /// Each window's home screen gets its flow from here, so all share one.
    @Test func everyHomeScreenGetsTheAppsFlow() {
        let notifier = FakeNotifier()
        let store = TaskStore.inMemory()
        let names = InMemoryAgentNameStore(stored: "Pip")
        let one = HomeView.flow(store: store, notifier: notifier, brand: Brand(name: "Nova"), names: names)
        let two = HomeView.flow(store: store, notifier: notifier, brand: Brand(name: "Nova"), names: names)
        #expect(one === two)
        #expect(notifier.clears == 1)
        #expect(notifier.listeners == 1)
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
        // Handed over a turn later. Waits a while, never forever.
        for _ in 0..<100 where heard.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(heard == ["task:7"])
        // A listener set after it has been handed over gets nothing.
        var later: [String] = []
        notifier.onOpen { later.append($0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(later.isEmpty)
        #expect(heard == ["task:7"], "once, not twice")
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
