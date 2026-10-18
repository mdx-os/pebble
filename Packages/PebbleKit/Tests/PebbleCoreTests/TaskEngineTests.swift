import Foundation
@testable import PebbleCore
import Testing

/// Collects every snapshot an engine reports.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [[AgentTask]] = []
    func add(_ tasks: [AgentTask]) { lock.lock(); list.append(tasks); lock.unlock() }
    var snapshots: [[AgentTask]] { lock.lock(); defer { lock.unlock() }; return list }
    /// Each state the task was seen in, without repeats in a row.
    func states(_ id: String) -> [TaskState] {
        var out: [TaskState] = []
        for state in snapshots.compactMap({ $0.first { $0.id == id }?.state }) where out.last != state {
            out.append(state)
        }
        return out
    }
}

/// Collects each snapshot's number.
private final class Numbers: @unchecked Sendable {
    private let lock = NSLock()
    private var numbers: [Int] = []
    func add(_ number: Int) { lock.lock(); numbers.append(number); lock.unlock() }
    var list: [Int] { lock.lock(); defer { lock.unlock() }; return numbers }
}

/// The scripted engine, driven by a clock the tests move. Nothing sleeps.
struct TaskEngineTests {
    let origin = Date(timeIntervalSinceReferenceDate: 813_000_000)

    private func engine(_ rule: AskFirst = .isolated(), policy: RetryPolicy = .standard) -> LocalFakeEngine {
        LocalFakeEngine(rule: rule, policy: policy, origin: origin)
    }

    private static let quick = TaskScript(title: "Quick", steps: [
        .init("One", duration: 2, kept: "the first thing", todo: "do one"),
        .init("Two", duration: 2, kept: "the second thing", todo: "do two"),
        .init("Three", duration: 2, todo: "do three"),
    ], doneLine: "All done.", result: "The result")

    // MARK: State machine

    @Test func aScriptRunsItsStepsInOrderThenIsDone() throws {
        let engine = engine()
        let id = engine.start(Self.quick)
        var task = try #require(engine.task(id))
        #expect(task.state == .running)
        #expect(task.step == "One")
        #expect(task.progress == .fraction(0))
        engine.advance(by: 1)
        task = try #require(engine.task(id))
        #expect(task.step == "One")
        #expect(abs((task.progress.fraction ?? 0) - 1.0 / 6) < 0.001)
        engine.advance(by: 1)
        #expect(engine.task(id)?.step == "Two")
        #expect(engine.task(id)?.history.map(\.text) == ["One"])
        engine.advance(by: 4)
        task = try #require(engine.task(id))
        #expect(task.state == .done)
        #expect(task.step == "All done.")
        #expect(task.progress == .fraction(1))
        #expect(task.result == "The result")
        #expect(task.wrapUp == nil)
        #expect(task.history.map(\.mark) == [.done, .done, .done])
    }

    @Test func oneLongJumpLandsWhereManyShortStepsWould() throws {
        let short = engine()
        let long = engine()
        let a = short.start(SampleTasks.dentist)
        let b = long.start(SampleTasks.dentist)
        for _ in 0..<160 { short.advance(by: 0.25) }
        long.advance(by: 40)
        #expect(short.task(a)?.state == long.task(b)?.state)
        #expect(short.task(a)?.step == long.task(b)?.step)
        #expect(short.task(a)?.history.map(\.text) == long.task(b)?.history.map(\.text))
    }

    @Test func theDentistSearchGoesThroughEveryState() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let seen = Seen()
        let watch = engine.observe { seen.add($0.tasks) }
        let id = engine.start(SampleTasks.dentist)
        for _ in 0..<50 { engine.advance(by: 1) }
        #expect(seen.states(id) == [.running, .stalled, .retrying, .running, .waitingOnYou])
        let task = try #require(engine.task(id))
        #expect(task.waitsForApproval)
        #expect(task.question?.action == SampleTasks.holdVisit)
        watch.cancel()
    }

    @Test func progressNeverGoesBackward() {
        let engine = engine()
        let id = engine.start(SampleTasks.dentist)
        var last = 0.0
        for _ in 0..<200 {
            engine.advance(by: 0.25)
            let now = engine.task(id)?.progress.fraction ?? 0
            #expect(now >= last)
            last = now
        }
    }

    @Test func aScriptThatCantSayHowFarSaysSo() {
        let engine = engine()
        let id = engine.start(SampleTasks.plan)
        engine.advance(by: 3)
        #expect(engine.task(id)?.progress == .indeterminate)
        #expect(engine.task(id)?.spokenProgress == TaskWords.stillWorking)
        engine.advance(by: 30)
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.progress == .fraction(1))
    }

    @Test func theHistoryStaysShort() {
        let steps = (1...10).map { TaskScript.Step("Step \($0)", duration: 1, todo: "do step \($0)") }
        let engine = engine()
        let id = engine.start(TaskScript(title: "Long", steps: steps, doneLine: "Done."))
        engine.advance(by: 20)
        #expect(engine.task(id)?.history.count == AgentTask.historyLimit)
        #expect(engine.task(id)?.history.last?.text == "Step 10")
    }

    @Test func aStepThatCantBeDoneEndsInPlainWords() {
        let engine = engine()
        let id = engine.start(TaskScript(title: "Hard", steps: [
            .init("First", duration: 1, kept: "a start", todo: "start"),
            .init("Impossible", kind: .fails, todo: "do the impossible"),
        ], doneLine: "Done."))
        engine.advance(by: 2)
        #expect(engine.task(id)?.state == .failed)
        #expect(engine.task(id)?.step == TaskWords.failed)
        #expect(engine.task(id)?.wrapUp == TaskWrapUp(kept: ["a start"], notDone: ["do the impossible"]))
    }

    @Test func aRequestNoScriptCoversStillRuns() {
        let engine = engine()
        let id = engine.start(TaskRequest(title: "Sort my photos"))
        #expect(engine.task(id)?.title == "Sort my photos")
        engine.advance(by: 60)
        #expect(engine.task(id)?.state == .done)
        let known = engine.start(TaskRequest(title: SampleTasks.planTitle))
        #expect(engine.task(known)?.step == SampleTasks.plan.steps[0].text)
    }

    @Test func tasksAreNewestFirst() {
        let engine = engine()
        let first = engine.start(Self.quick)
        let second = engine.start(SampleTasks.plan)
        #expect(engine.tasks.map(\.id) == [second, first])
    }

    // MARK: Retry with backoff, then ask

    @Test func theBackoffDoublesAndHasACeiling() {
        let policy = RetryPolicy(timeout: 20, maxRetries: 5, backoff: 2, maxBackoff: 10)
        #expect((0..<5).map(policy.delay(beforeRetry:)) == [2, 4, 8, 10, 10])
    }

    @Test func aHangingStepIsTriedAgainWithBackoffThenTheCardAsks() throws {
        let engine = engine()
        let id = engine.start(SampleTasks.lunch)
        engine.advance(by: 19.9)
        #expect(engine.task(id)?.state == .running)
        // Hung past the 20 second timeout: wait 2 seconds, then try another way.
        engine.advance(by: 0.1)
        #expect(engine.task(id)?.state == .stalled)
        #expect(engine.task(id)?.step == SampleTasks.lunch.steps[0].slowLine)
        engine.advance(by: 1.9)
        #expect(engine.task(id)?.state == .stalled)
        engine.advance(by: 0.1)
        #expect(engine.task(id)?.state == .retrying)
        #expect(engine.task(id)?.step == "That page was slow, so I'm trying another way.")
        // The second hang waits twice as long.
        engine.advance(by: 20)
        #expect(engine.task(id)?.state == .stalled)
        engine.advance(by: 3.9)
        #expect(engine.task(id)?.state == .stalled)
        engine.advance(by: 0.1)
        #expect(engine.task(id)?.state == .retrying)
        // Retries spent: only now does it ask the person.
        engine.advance(by: 19.9)
        #expect(engine.task(id)?.state == .retrying)
        engine.advance(by: 0.1)
        let task = try #require(engine.task(id))
        #expect(task.state == .waitingOnYou)
        #expect(task.isStuck)
        #expect(task.question == nil)
        #expect(task.step == TaskWords.stuck)
        // And nothing else happens until the person decides.
        engine.advance(by: 600)
        #expect(engine.task(id)?.state == .waitingOnYou)
    }

    @Test func aStuckTaskIsANeedsYouItem() throws {
        let engine = engine()
        let id = engine.start(SampleTasks.lunch)
        engine.advance(by: 30)
        var feed = Feed.build(from: [], tasks: engine, now: origin + 30)
        #expect(feed.working.map(\.id) == [id])
        #expect(feed.needsYou.isEmpty)
        engine.advance(by: 60)
        // A stuck task asks nothing, so it is pinned without a NeedsYou.
        feed = Feed.build(from: [], tasks: engine, now: origin + 90)
        #expect(feed.needsYou.map(\.id) == [id])
        #expect(feed.working.isEmpty)
        #expect(feed.groups.isEmpty)
    }

    @Test func taskCardsComeOnlyFromTheFeedsOwnEngine() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let waiting = try #require(engine.tasks.first)
        #expect(waiting.waitsForApproval)
        // The engine passed as a plain source, or a card posing as its task,
        // adds nothing: no card, and no question pinned.
        struct Posing: FeedSource {
            let item: FeedItem
            func items(now: Date) -> [FeedItem] { [item] }
        }
        let posing = Posing(item: TaskFeed.item(waiting))
        let feed = Feed.build(from: [TaskFeed(engine: engine), posing], needsYou: NeedsYou(rule: rule), now: origin + 45)
        #expect(feed.isEmpty)
    }

    @Test func aTaskQuestionIsPinnedOnlyThroughTheFeedsRule() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let question = try #require(engine.task(id)?.question)
        // No NeedsYou: nothing holds the question open, so it isn't pinned.
        #expect(Feed.build(from: [], tasks: engine, now: origin + 45).needsYou.isEmpty)
        // Another rule never asked it.
        let other = Feed.build(from: [], needsYou: NeedsYou(rule: .isolated()), tasks: engine, now: origin + 45)
        #expect(other.needsYou.isEmpty)
        #expect(other.working.map(\.id) == [id])
        // The rule that asked it pins it.
        let asked = Feed.build(from: [], needsYou: NeedsYou(rule: rule), tasks: engine, now: origin + 45)
        #expect(asked.needsYou.map(\.id) == [id])
        // Once the rule closes it, it is gone from Needs you, even before
        // the engine notices.
        rule.withdraw(question)
        #expect(engine.task(id)?.waitsForApproval == true)
        #expect(Feed.build(from: [], needsYou: NeedsYou(rule: rule), tasks: engine, now: origin + 45).needsYou.isEmpty)
    }

    @Test func questionsComeBeforeTasksInNeedsYou() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let asks = NeedsYou(rule: rule)
        let note = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                                  details: "Running late")
        let request = try #require(asks.ask(note, at: origin + 50))
        let feed = Feed.build(from: [], needsYou: asks, tasks: engine, now: origin + 50)
        #expect(feed.needsYou.map(\.id) == ["ask:\(request.id.uuidString)", id])
    }

    @Test func scriptedTasksAreExamples() {
        let engine = engine()
        #expect(engine.isSample)
        #expect(TaskFeed(engine: engine).isSample)
    }

    @Test func tryAgainAfterTheRetriesRunOut() throws {
        let engine = engine()
        let id = engine.start(SampleTasks.lunch)
        #expect(!engine.retry(id), "only a stuck task can be tried again")
        engine.advance(by: 66)
        #expect(engine.task(id)?.isStuck == true)
        #expect(engine.retry(id))
        #expect(engine.task(id)?.state == .running)
        engine.advance(by: 5)
        #expect(engine.task(id)?.state == .done)
    }

    @Test func aStepThatRecoversSaysItTookAnotherWay() {
        let engine = engine()
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 36)
        let marks = engine.task(id)?.history.map(\.mark)
        #expect(marks == [.done, .retried])
        #expect(engine.task(id)?.history.last?.text == "Found another way to check Saturday hours.")
        #expect(engine.task(id)?.state == .running)
    }

    @Test func noRetriesMeansAskingAtTheFirstHang() {
        let engine = engine(policy: RetryPolicy(timeout: 5, maxRetries: 0))
        let id = engine.start(SampleTasks.lunch)
        engine.advance(by: 5)
        #expect(engine.task(id)?.isStuck == true)
    }

    // MARK: Stop

    @Test func stopIsImmediateAndSaysWhatWasKeptAndWhatWasNot() throws {
        let engine = engine()
        let id = engine.start(Self.quick)
        engine.advance(by: 3)
        #expect(engine.stop(id))
        let task = try #require(engine.task(id))
        #expect(task.state == .stopped)
        #expect(task.step == TaskWords.stopped)
        #expect(task.wrapUp == TaskWrapUp(kept: ["the first thing"], notDone: ["do two", "do three"]))
        #expect(task.wrapUp?.keptLine == "I kept the first thing.")
        #expect(task.wrapUp?.notDoneLine == "I didn't do two or do three.")
        // Nothing moves after a stop.
        engine.advance(by: 60)
        #expect(engine.task(id) == task)
        #expect(!engine.stop(id))
    }

    @Test func stoppingBeforeAnythingIsKeptSaysSo() {
        let engine = engine()
        let id = engine.start(Self.quick)
        engine.stop(id)
        #expect(engine.task(id)?.wrapUp?.keptLine == TaskWords.keptNothing)
    }

    @Test func stoppingWhileWaitingForAYesWithdrawsTheQuestion() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let question = try #require(engine.task(id)?.question)
        #expect(engine.stop(id))
        #expect(rule.isClosed(question))
        #expect(engine.task(id)?.question == nil)
        #expect(engine.task(id)?.wrapUp?.notDone == ["hold a Saturday visit"])
        // A yes for it now does nothing.
        #expect(engine.resume(id, with: question.approve()) == .refused)
    }

    // MARK: Redirect

    @Test func redirectNeedsNoYesAndIsRecorded() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 3)
        #expect(engine.redirect(id, with: "  Only ones near\nthe school  "))
        let task = try #require(engine.task(id))
        #expect(task.state == .running)
        #expect(task.step == TaskWords.redirected)
        #expect(task.question == nil)
        #expect(task.history.last == TaskStep("You said: Only ones near the school", mark: .redirected, at: origin + 3))
        // The step starts over with the new words.
        engine.advance(by: 5.9)
        #expect(engine.task(id)?.step == TaskWords.redirected)
        engine.advance(by: 0.1)
        #expect(engine.task(id)?.step == SampleTasks.dentist.steps[1].text)
    }

    @Test func redirectRefusesEmptyWordsAndEndedTasks() {
        let engine = engine()
        let id = engine.start(Self.quick)
        #expect(!engine.redirect(id, with: "  \n "))
        engine.advance(by: 10)
        #expect(!engine.redirect(id, with: "Something else"))
        #expect(!engine.redirect("task:nope", with: "Something else"))
    }

    @Test func longRedirectWordsAreShortened() {
        let engine = engine()
        let id = engine.start(Self.quick)
        engine.redirect(id, with: String(repeating: "a", count: 500))
        let said = engine.task(id)?.history.last?.text ?? ""
        #expect(said.count <= "You said: ".count + LocalFakeEngine.maxInstructionLength + 3)
    }

    /// The script can't change what it asks, so a redirect at an ask step
    /// leaves the step undone and says so. It never says the change was
    /// taken and then asks the old thing again.
    @Test func redirectAtAnAskStepLeavesItUndoneAndSaysSo() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let old = try #require(engine.task(id)?.question)
        guard case .ask(_, let askLine) = SampleTasks.dentist.steps[3].kind else { Issue.record("not an ask"); return }
        #expect(engine.task(id)?.step == askLine)
        #expect(engine.redirect(id, with: "Make it 11 instead"))
        #expect(rule.isClosed(old))
        let task = try #require(engine.task(id))
        #expect(task.step != askLine)
        #expect(task.step != TaskWords.redirected)
        #expect(task.question == nil)
        #expect(!task.waitsForApproval)
        #expect(task.history.suffix(2).map(\.text) == [
            "You said: Make it 11 instead", "You changed course, so I didn't hold a Saturday visit.",
        ])
        #expect(task.wrapUp?.notDone == ["hold a Saturday visit"])
        // The old yes can't be used for anything.
        #expect(engine.resume(id, with: old.approve()) == .refused)
    }

    /// An ask step with more to do after it goes on to the next step.
    @Test func redirectAtAnAskStepGoesOnToTheNextStep() throws {
        let engine = engine()
        let id = engine.start(TaskScript(title: "Hold and remind", steps: [
            .init("Holding a visit", kind: .ask(SampleTasks.holdVisit, askLine: "I'll wait for your yes."),
                  todo: "hold a visit"),
            .init("Setting a reminder", duration: 2, todo: "set a reminder"),
        ], doneLine: "Done."))
        #expect(engine.task(id)?.step == "I'll wait for your yes.")
        engine.redirect(id, with: "Later in the day")
        let task = try #require(engine.task(id))
        #expect(task.state == .running)
        #expect(task.step == "Setting a reminder")
        #expect(task.question == nil)
    }

    @Test func redirectGetsAStuckTaskGoing() {
        let engine = engine()
        let id = engine.start(SampleTasks.lunch)
        engine.advance(by: 66)
        #expect(engine.redirect(id, with: "Try the board's site"))
        #expect(engine.task(id)?.state == .running)
        engine.advance(by: 5)
        #expect(engine.task(id)?.state == .done)
    }

    // MARK: Approve only through the approval path

    private func waiting(_ rule: AskFirst) throws -> (LocalFakeEngine, String, ConfirmationRequest) {
        let engine = engine(rule)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let question = try #require(engine.task(id)?.question)
        return (engine, id, question)
    }

    @Test func aYesFromTheSheetLetsTheTaskGoOnOnce() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(engine.resume(id, with: yes) == .proceeding)
        #expect(engine.task(id)?.state == .running)
        #expect(engine.task(id)?.history.last?.mark == .approved)
        // Used once. The same yes again does nothing.
        #expect(engine.resume(id, with: yes) == .refused)
        #expect(rule.decide(question.action, approval: yes) == .stop)
        engine.advance(by: 4)
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.wrapUp == nil)
    }

    @Test func aLateYesIsRefusedAndTheStepIsNotDone() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let (engine, id, question) = try waiting(rule)
        clock.advance(AskFirst.defaultWindow + 1)
        #expect(rule.sayYes(to: question) == .timedOut)
        #expect(engine.resume(id, with: question.approve()) == .refused)
        engine.refresh()
        let task = try #require(engine.task(id))
        #expect(task.state == .done)
        #expect(task.wrapUp?.notDone == ["hold a Saturday visit"])
        #expect(task.history.last?.text == "That question timed out, so I didn't hold a Saturday visit.")
    }

    @Test func aYesGivenInTimeButCheckedTooLateTimesOut() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let (engine, id, question) = try waiting(rule)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        clock.advance(31)
        #expect(engine.resume(id, with: yes) == .timedOut)
        #expect(engine.task(id)?.state == .done)
        #expect(engine.task(id)?.wrapUp?.notDone == ["hold a Saturday visit"])
    }

    @Test func aYesForAnotherQuestionIsRefused() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        let other = try #require(rule.ask(ProposedAction(
            kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")))
        #expect(engine.resume(id, with: other.approve()) == .refused)
        #expect(engine.resume("task:nope", with: question.approve()) == .refused)
        #expect(engine.task(id)?.waitsForApproval == true)
    }

    @Test func aYesFromAnotherRuleIsRefused() throws {
        let (engine, id, question) = try waiting(.isolated())
        // Not the rule that asked: it never issued this question.
        let forged = try #require(AskFirst.isolated().ask(question.action)).approve()
        #expect(engine.resume(id, with: forged) == .refused)
        #expect(engine.task(id)?.waitsForApproval == true)
    }

    @Test func notNowLetsTheTaskGoOnWithoutTheStep() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        engine.questionClosed(question)
        #expect(rule.isClosed(question))
        let task = try #require(engine.task(id))
        #expect(task.state == .done)
        #expect(task.history.last?.text == "You closed the question, so I didn't hold a Saturday visit.")
        #expect(task.wrapUp?.notDoneLine == "I didn't hold a Saturday visit.")
    }

    /// A question the sheet withdrew, noticed by a refresh before the engine
    /// was told, is the person's no, not a timeout.
    @Test func aWithdrawnQuestionSettlesAsDeclinedNotTimedOut() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        rule.withdraw(question)
        #expect(rule.wasWithdrawn(question))
        engine.refresh()
        #expect(engine.task(id)?.history.last?.text == TaskWords.declined("hold a Saturday visit"))
        // Told afterwards, nothing changes.
        engine.questionClosed(question)
        #expect(engine.task(id)?.history.filter { $0.mark == .skipped }.count == 1)
    }

    /// Close on a question that had already run out of time says it timed
    /// out, whichever way the engine hears of it.
    @Test func closingATimedOutQuestionSaysItTimedOut() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let (engine, id, question) = try waiting(rule)
        clock.advance(AskFirst.defaultWindow + 1)
        // The sheet's Close withdraws it, but it had already run out.
        rule.withdraw(question)
        #expect(!rule.wasWithdrawn(question))
        engine.questionClosed(question)
        #expect(engine.task(id)?.history.last?.text == TaskWords.timedOut("hold a Saturday visit"))
    }

    @Test func aQuestionThatTimesOutOnScreenIsNoticed() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let (engine, id, _) = try waiting(rule)
        clock.advance(AskFirst.defaultWindow - 1)
        engine.refresh()
        #expect(engine.task(id)?.waitsForApproval == true)
        clock.advance(2)
        engine.advance(by: 0)
        #expect(engine.task(id)?.state == .done)
    }

    @Test func aQuestionAskFirstWontAskIsNeverAsked() throws {
        let engine = engine()
        let unclear = ProposedAction(kind: .send, recipient: Recipient(id: "c:2", displayName: "Someone"), details: "Hello")
        let id = engine.start(TaskScript(title: "Say hello", steps: [
            .init("Sending hello", kind: .ask(unclear, askLine: "Ready to send."), todo: "send hello"),
        ], doneLine: "Done."))
        let task = try #require(engine.task(id))
        #expect(task.question == nil)
        #expect(task.state == .done)
        #expect(task.history.last?.text == "I couldn't ask about this clearly, so I didn't send hello.")
    }

    // MARK: Observing

    @Test func observersHearChangesUntilTheyCancel() {
        let engine = engine()
        let seen = Seen()
        let watch = engine.observe { seen.add($0.tasks) }
        #expect(seen.snapshots.count == 1, "told at once")
        engine.start(Self.quick)
        engine.advance(by: 1)
        let heard = seen.snapshots.count
        #expect(heard == 3)
        // A tick that changes nothing says nothing.
        engine.refresh()
        #expect(seen.snapshots.count == heard)
        watch.cancel()
        engine.advance(by: 1)
        #expect(seen.snapshots.count == heard)
    }

    /// Each snapshot is numbered higher than the last, so a listener that
    /// hops threads can tell a late one.
    @Test func snapshotsAreNumberedInOrder() {
        let engine = engine()
        let numbers = Numbers()
        let watch = engine.observe { numbers.add($0.sequence) }
        engine.start(Self.quick)
        for _ in 0..<8 { engine.advance(by: 1) }
        engine.refresh()
        let seen = numbers.list
        // Told at once, at the start, and at each tick until done at 6 seconds.
        #expect(seen.count == 8)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 })
        watch.cancel()
    }

    // MARK: Letting go

    @Test func anEndedTaskCanBeClearedAwayWithWhatItHeld() throws {
        let engine = engine()
        let id = engine.start(Self.quick)
        #expect(!engine.dismiss(id), "a task still going is stopped first")
        engine.redirect(id, with: "My sister's address is 12 Elm")
        engine.stop(id)
        #expect(engine.dismiss(id))
        #expect(engine.task(id) == nil)
        #expect(engine.tasks.isEmpty)
        #expect(!engine.dismiss(id))
    }

    @Test func clearForgetsEveryTaskAndWithdrawsItsQuestion() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        let waiting = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let question = try #require(engine.task(waiting)?.question)
        engine.start(Self.quick)
        let seen = Seen()
        let watch = engine.observe { seen.add($0.tasks) }
        engine.clear()
        #expect(engine.tasks.isEmpty)
        #expect(rule.isClosed(question))
        #expect(seen.snapshots.last == [])
        // A yes for it now does nothing, and nothing comes back.
        #expect(engine.resume(waiting, with: question.approve()) == .refused)
        engine.advance(by: 600)
        #expect(engine.tasks.isEmpty)
        watch.cancel()
    }

    /// Forgetting never hides that a yes may already have done something:
    /// clear counts the approved steps under way, and says nothing else
    /// about them. Ended tasks and steps still waiting for a yes don't count.
    @Test func clearCountsApprovedStepsUnderwayAndNothingMore() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        // Another still waiting on its yes, one stopped after a yes, and a plain one.
        let asking = engine.start(SampleTasks.dentist)
        let stoppedAfterYes = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let second = try #require(engine.task(stoppedAfterYes)?.question)
        guard case .approved(let again) = rule.sayYes(to: second) else { Issue.record("yes refused"); return }
        #expect(engine.resume(stoppedAfterYes, with: again) == .proceeding)
        #expect(engine.stop(stoppedAfterYes))
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(engine.resume(id, with: yes) == .proceeding)
        engine.advance(by: 1)
        engine.start(Self.quick)
        #expect(engine.task(asking)?.waitsForApproval == true)
        #expect(engine.task(id)?.state == .running)
        let cleared = engine.clear()
        #expect(cleared == ClearedTasks(forgotten: 4, underway: 1))
        #expect(engine.tasks.isEmpty)
        let line = try #require(cleared.underwayLine)
        #expect(line == TaskWords.forgotUnderway(1))
        // Nothing the task held: no place, time, name or step words.
        for detail in ["Maple", "Saturday", "10:30", "name", "phone", "dentist", "hold"] {
            #expect(!line.contains(detail), "\(detail) in: \(line)")
        }
        // With nothing approved under way, there is nothing to say.
        #expect(engine.clear() == ClearedTasks.none)
        #expect(ClearedTasks.none.underwayLine == nil)
        #expect(ClearedTasks(forgotten: 3, underway: 2).underwayLine == TaskWords.forgotUnderway(2))
    }

    #if DEBUG
    /// Only this thread holding the lock counts as holding it. Another
    /// thread holding it at the same moment is no false alarm.
    @Test func holdingTheLockIsTrackedPerThread() {
        let engine = engine()
        #expect(!engine.holdsLock)
        engine.holdingLock { #expect(engine.holdsLock) }
        #expect(!engine.holdsLock)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            engine.holdingLock {
                held.signal()
                release.wait()
            }
            done.signal()
        }
        held.wait()
        // The other thread holds it now; this one doesn't.
        #expect(!engine.holdsLock)
        release.signal()
        done.wait()
        #expect(!engine.holdsLock)
    }
    #endif

    @Test func endedTasksAreCappedAndTasksStillGoingAreKept() throws {
        let engine = engine()
        let going = engine.start(SampleTasks.lunch)
        engine.advance(by: 66)
        #expect(engine.task(going)?.isStuck == true)
        var ids: [String] = []
        for _ in 0..<(LocalFakeEngine.endedLimit + 5) {
            ids.append(engine.start(Self.quick))
            engine.advance(by: 10)
        }
        let ended = engine.tasks.filter { !$0.isActive }
        #expect(ended.count == LocalFakeEngine.endedLimit)
        // The newest are kept, and the stuck one is never dropped.
        #expect(Set(ended.map(\.id)) == Set(ids.suffix(LocalFakeEngine.endedLimit)))
        #expect(engine.task(going) != nil)
    }

    /// The feed holds a task without its live progress, so a tick never
    /// changes the feed.
    @Test func aTickDoesNotChangeTheFeed() throws {
        let engine = engine()
        let id = engine.start(Self.quick)
        let before = Feed.build(from: [], tasks: engine, now: origin)
        engine.advance(by: 0.5)
        engine.advance(by: 0.5)
        #expect(engine.task(id)?.progress != .fraction(0))
        #expect(Feed.build(from: [], tasks: engine, now: origin) == before)
        // A new step does change it.
        engine.advance(by: 1)
        #expect(Feed.build(from: [], tasks: engine, now: origin) != before)
        #expect(TaskFeed.item(try #require(engine.task(id))).task?.progress == .fraction(0))
        #expect(engine.task(id)?.card.step == engine.task(id)?.step)
    }

    @Test func historyRowsKeepTheirIdsAsStepsPushIn() throws {
        let engine = engine()
        let id = engine.start(Self.quick)
        engine.advance(by: 2)
        let first = try #require(engine.task(id)?.history.last)
        engine.advance(by: 2)
        let task = try #require(engine.task(id))
        #expect(task.history.first?.id == first.id)
        #expect(Set(task.history.map(\.id)).count == task.history.count)
    }

    /// The clock stands still, as in the showcase scenes, and the same words
    /// come twice. Each step still has its own id.
    @Test func historyIdsNeverRepeatOnAStillClock() throws {
        let engine = engine()
        let id = engine.start(SampleTasks.plan)
        #expect(engine.redirect(id, with: "Keep Friday free"))
        #expect(engine.redirect(id, with: "Keep Friday free"))
        #expect(engine.redirect(id, with: "Keep Friday free"))
        let task = try #require(engine.task(id))
        #expect(task.history.count == 3)
        #expect(Set(task.history.map(\.text)).count == 1)
        #expect(Set(task.history.map(\.at)).count == 1)
        #expect(Set(task.history.map(\.id)).count == 3)
        // Numbers count on past the history limit, so a step pushed out
        // never hands its id to a new one.
        for _ in 0..<5 { engine.redirect(id, with: "Keep Friday free") }
        let later = try #require(engine.task(id))
        #expect(later.history.map(\.id) == [4, 5, 6, 7])
        #expect(later.stepsRecorded == 8)
    }

    // MARK: A yes is committed

    /// After a yes the step may already be under way, so new instructions
    /// let it finish. Nothing says it wasn't done.
    @Test func redirectAfterAYesLetsTheApprovedStepFinish() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(engine.resume(id, with: yes) == .proceeding)
        #expect(engine.redirect(id, with: "Only ones near the school"))
        let task = try #require(engine.task(id))
        #expect(task.state == .running)
        #expect(task.step == TaskWords.finishingApproved)
        #expect(task.history.map(\.text).suffix(2) == [TaskWords.youSaidYes, "You said: Only ones near the school"])
        #expect(!task.history.contains { $0.text == TaskWords.changedCourse("hold a Saturday visit") })
        engine.advance(by: 4)
        let done = try #require(engine.task(id))
        #expect(done.state == .done)
        #expect(done.wrapUp == nil)
        #expect(done.history.last?.text == "Holding Saturday at 10:30 at Maple Dental")
    }

    /// Stopped after a yes, mid-step: the step is named as maybe done,
    /// never as not done.
    @Test func stopAfterAYesSaysTheStepMayBeDone() throws {
        let rule = AskFirst.isolated()
        let (engine, id, question) = try waiting(rule)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(engine.resume(id, with: yes) == .proceeding)
        engine.advance(by: 1)
        #expect(engine.stop(id))
        let wrapUp = try #require(engine.task(id)?.wrapUp)
        #expect(wrapUp.notDone.isEmpty)
        #expect(wrapUp.notDoneLine == nil)
        #expect(wrapUp.underway == "hold a Saturday visit")
        #expect(wrapUp.underwayLine == "You said yes, so I'd already started to hold a Saturday visit. It may be done.")
        #expect(wrapUp.kept == ["a list of dentists nearby", "three that open Saturdays", "a few notes on their reviews"])
    }

    /// Stopped while still asking, before any yes: the step is not done, as before.
    @Test func stopBeforeAYesStillSaysNotDone() throws {
        let (engine, id, _) = try waiting(.isolated())
        #expect(engine.stop(id))
        let wrapUp = try #require(engine.task(id)?.wrapUp)
        #expect(wrapUp.notDone == ["hold a Saturday visit"])
        #expect(wrapUp.underway == nil)
    }

    /// The next step after the approved one is not committed: a redirect
    /// there works as usual.
    @Test func onlyTheApprovedStepIsCommitted() throws {
        let rule = AskFirst.isolated()
        let script = TaskScript(title: "Two things", steps: [
            .init("Asking", kind: .ask(SampleTasks.holdVisit, askLine: "May I?"), duration: 2, todo: "hold it"),
            .init("Tidying", duration: 5, todo: "tidy up"),
        ], doneLine: "Done.")
        let engine = engine(rule)
        let id = engine.start(script)
        let question = try #require(engine.task(id)?.question)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(engine.resume(id, with: yes) == .proceeding)
        engine.advance(by: 3)
        #expect(engine.task(id)?.step == "Tidying")
        #expect(engine.redirect(id, with: "Quickly"))
        #expect(engine.task(id)?.step == TaskWords.redirected)
        #expect(engine.stop(id))
        #expect(engine.task(id)?.wrapUp == TaskWrapUp(kept: [], notDone: ["tidy up"]))
    }

    // MARK: AskFirst is never called holding the lock

    /// Every path that asks, checks or withdraws a question, counted. None of
    /// those calls comes while the engine holds its lock, so a rule that
    /// called out, to someone who called straight back in, could not deadlock.
    @Test func askFirstIsNeverCalledHoldingTheEngineLock() throws {
        let rule = AskFirst.isolated()
        let engine = engine(rule)
        // An observer that calls back in, as a feed refreshing would.
        let watch = engine.observe { _ in engine.refresh() }
        defer { watch.cancel() }
        // Asked, then a yes, then finished.
        let first = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        let asked = try #require(engine.task(first)?.question)
        guard case .approved(let yes) = rule.sayYes(to: asked) else { Issue.record("yes refused"); return }
        #expect(engine.resume(first, with: yes) == .proceeding)
        // Asked, then closed.
        let second = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        engine.questionClosed(try #require(engine.task(second)?.question))
        // Asked, then redirected, stopped and cleared.
        let third = engine.start(SampleTasks.dentist)
        let fourth = engine.start(SampleTasks.dentist)
        let fifth = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        engine.redirect(third, with: "Somewhere else")
        engine.stop(fourth)
        // Timed out, then settled.
        rule.withdraw(try #require(engine.task(fifth)?.question))
        engine.refresh()
        engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        engine.clear()
        #expect(engine.ruleCalls > 10)
        #expect(engine.ruleCallsHoldingLock == 0)
        #expect(engine.tasks.isEmpty)
    }

    /// The answer to a question asked outside the lock lands on its task,
    /// and a question that can't be asked is still skipped and said.
    @Test func questionsAskedOutsideTheLockStillLandAndSkip() throws {
        let engine = engine()
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 45)
        #expect(engine.task(id)?.waitsForApproval == true)
        let vague = ProposedAction(kind: .send, recipient: Recipient(id: "c:2", displayName: "Someone"), details: "Hi")
        let script = TaskScript(title: "Vague", steps: [
            .init("Asking", kind: .ask(vague, askLine: "May I?"), todo: "send it"),
            .init("Tidying", duration: 2, todo: "tidy up"),
        ], doneLine: "Done.")
        let other = engine.start(script)
        let task = try #require(engine.task(other))
        #expect(task.state == .running)
        #expect(task.step == "Tidying")
        #expect(task.history.last?.text == TaskWords.couldNotAsk("send it"))
    }

    // MARK: Words

    @Test func taskWordsAreWarmAndPlain() {
        var lines = TaskWords.all
        for script in SampleTasks.all {
            lines += [script.title, script.doneLine, script.result ?? ""]
            for step in script.steps {
                lines += [step.text, step.todo, step.kept ?? "", step.slowLine, step.retryLine]
                if case .ask(let action, let askLine) = step.kind { lines += [askLine, action.details] }
            }
        }
        for line in lines {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
            #expect(!line.contains("!"), "exclamation in: \(line)")
            for avoid in ["retry", "error", "failed", "invalid", "timeout", "request", "N/A"] {
                #expect(!line.lowercased().contains(avoid.lowercased()), "\(avoid) in: \(line)")
            }
        }
    }

    @Test func listsReadNaturally() {
        #expect(TaskWords.kept(["a"]) == "I kept a.")
        #expect(TaskWords.kept(["a", "b"]) == "I kept a and b.")
        #expect(TaskWords.kept(["a", "b", "c"]) == "I kept a, b and c.")
        #expect(TaskWords.notDone(["a", "b"]) == "I didn't a or b.")
    }
}

/// What VoiceOver hears as tasks move.
struct TaskAnnouncerTests {
    let start = ContinuousClock.now

    private func task(_ step: String, _ state: TaskState = .running, progress: Double = 0, id: String = "t") -> AgentTask {
        AgentTask(id: id, title: "Find a dentist", step: step, progress: .fraction(progress), state: state,
                  startedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func theFirstLookIsSilent() {
        var announcer = TaskAnnouncer()
        #expect(announcer.lines(for: [task("One")], at: start).isEmpty)
    }

    @Test func progressTicksAreNeverSaid() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [task("One")], at: start)
        for tick in 1...100 {
            let lines = announcer.lines(for: [task("One", progress: Double(tick) / 100)], at: start + .seconds(tick))
            #expect(lines.isEmpty)
        }
    }

    @Test func aNewStepIsSaidOncePolitely() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [task("One")], at: start)
        let lines = announcer.lines(for: [task("Two")], at: start + .seconds(10))
        #expect(lines == [TaskAnnouncer.Line(text: "Find a dentist. Two", urgent: false)])
        #expect(announcer.lines(for: [task("Two", progress: 0.5)], at: start + .seconds(20)).isEmpty)
    }

    @Test func stepsThatComeTooFastWaitAndOnlyTheNewestIsSaid() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [task("One")], at: start)
        #expect(announcer.lines(for: [task("Two")], at: start + .seconds(10)).count == 1)
        #expect(announcer.lines(for: [task("Three")], at: start + .seconds(11)).isEmpty)
        #expect(announcer.lines(for: [task("Four")], at: start + .seconds(12)).isEmpty)
        #expect(announcer.lines(for: [task("Four", progress: 0.1)], at: start + .seconds(13)).isEmpty)
        let later = announcer.lines(for: [task("Four", progress: 0.2)], at: start + .seconds(14))
        #expect(later.map(\.text) == ["Find a dentist. Four"])
        #expect(announcer.lines(for: [task("Four", progress: 0.3)], at: start + .seconds(30)).isEmpty)
    }

    @Test func needingThePersonOrEndingIsSaidRightAway() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [task("One")], at: start)
        #expect(announcer.lines(for: [task("Two")], at: start + .seconds(10)).count == 1)
        let ask = announcer.lines(for: [task("Ready. I'll wait for your yes.", .waitingOnYou)], at: start + .seconds(10.5))
        #expect(ask == [TaskAnnouncer.Line(text: "Find a dentist. Ready. I'll wait for your yes.", urgent: true)])
        let stop = announcer.lines(for: [task(TaskWords.stopped, .stopped)], at: start + .seconds(11))
        #expect(stop.first?.urgent == true)
    }

    @Test func manyTasksShareOneGap() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [task("A1", id: "a"), task("B1", id: "b")], at: start)
        let both = announcer.lines(for: [task("A2", id: "a"), task("B2", id: "b")], at: start + .seconds(10))
        #expect(both.count == 1)
        let next = announcer.lines(for: [task("A2", id: "a"), task("B2", id: "b")], at: start + .seconds(14))
        #expect(next.map(\.text) == ["Find a dentist. B2"])
    }

    @Test func aTaskThatAppearsLaterIsSaid() {
        var announcer = TaskAnnouncer()
        _ = announcer.lines(for: [], at: start)
        #expect(announcer.lines(for: [task("One")], at: start + .seconds(1)).count == 1)
    }
}
