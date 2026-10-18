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
    private(set) var requests = 0
    private(set) var posted: [QuestionNudge] = []
    private(set) var removed: [String] = []
    private var handler: (@MainActor @Sendable (String) -> Void)?

    init(grants: Bool = true) { self.grants = grants }

    func permission() async -> NudgePermission { .notDetermined }
    func requestPermission() async -> Bool { countRequest() }
    private func countRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return grants
    }
    func post(_ nudge: QuestionNudge) { lock.lock(); posted.append(nudge); lock.unlock() }
    func remove(_ ids: [String]) { lock.lock(); removed += ids; lock.unlock() }
    func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) { self.handler = handler }
    @MainActor func tap(_ taskID: String) { handler?(taskID) }
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
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: { "Pip" })
        // The device clock and the engine's agree, as they do in the app.
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
        flow.scene(isActive: true)
        #expect(notifier.removed == [nudge.id], "back in front, the nudge goes")
        flow.scene(isActive: false)
        #expect(notifier.posted.count == 1, "each question is nudged once")
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
        model.forgetTasks()
        await model.settled()
        #expect(receipts(model).isEmpty)
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(store.nudges == .allowed, "only the nudge choice stays")
        #expect(notifier.removed.contains(nudge.id))
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

    @Test func aNudgeOpenedBeforeAnythingListensIsHandedOverOnce() async {
        let notifier = LocalQuestionNotifier()
        notifier.open("task:7")
        var heard: [String] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            notifier.onOpen { id in
                heard.append(id)
                done.resume()
            }
        }
        #expect(heard == ["task:7"])
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
