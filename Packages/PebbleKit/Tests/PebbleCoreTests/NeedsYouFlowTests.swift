import Foundation
@testable import PebbleCore
import Testing

/// A question at a consequential step, end to end in the engine and the
/// store: asked once, answered once, kept while the app is closed, and
/// recorded on a receipt. Every clock here is moved by hand.
struct NeedsYouFlowTests {
    static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The dentist search, played to its question at 42 seconds.
    static func atQuestion(rule: AskFirst, origin: Date = base) -> (LocalFakeEngine, AgentTask) {
        let engine = LocalFakeEngine(rule: rule, origin: origin)
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let task = engine.tasks[0]
        return (engine, task)
    }

    /// A yes, the way the sheet makes one.
    static func yes(_ request: ConfirmationRequest, rule: AskFirst) throws -> Approval {
        guard case .approved(let approval) = rule.sayYes(to: request) else {
            throw CancellationError()
        }
        return approval
    }

    // MARK: Asked again with the deadline it had

    @Test func askingAgainKeepsTheFirstDeadline() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let request = try #require(rule.askAgain(SampleTasks.holdVisit, askedAgo: 200))
        clock.advance(99)
        #expect(!rule.isClosed(request))
        clock.advance(2)
        #expect(rule.isClosed(request), "200 seconds before plus 101 now is past the five minutes")
    }

    @Test func askingAgainNeverOpensALapsedQuestion() {
        let rule = AskFirst.isolated()
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: 301) == nil)
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: -1) == nil, "a clock moved back opens nothing")
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: .infinity) == nil)
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: .nan) == nil)
        #expect(rule.questionWindow == AskFirst.defaultWindow)
    }

    @Test func anOutcomeWithHiddenCharactersIsNeverAsked() {
        let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"),
                                    details: "Running late", outcome: "I'll send it now\u{202E}")
        #expect(AskFirst.isolated().ask(action) == nil)
    }

    @Test func theOutcomeIsPartOfWhatIsApproved() throws {
        let rule = AskFirst.isolated()
        let request = try #require(rule.ask(SampleTasks.holdVisit))
        let approval = try Self.yes(request, rule: rule)
        let other = ProposedAction(kind: .sharePersonalInfo, recipient: SampleTasks.holdVisit.recipient,
                                   details: SampleTasks.holdVisit.details, outcome: "I'll book Sunday instead.")
        #expect(rule.decide(other, approval: approval) == .stop)
        #expect(rule.decide(SampleTasks.holdVisit, approval: approval) == .proceed)
    }

    // MARK: Yes resumes once

    @Test func yesResumesTheTaskOnceAndLeavesAReceipt() throws {
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        let store = TaskStore.inMemory()
        let approval = try Self.yes(try #require(task.question), rule: rule)
        #expect(engine.resume(task.id, with: approval) == .proceeding)
        #expect(engine.resume(task.id, with: approval) == .refused, "a second tap does nothing")
        store.keep(engine)
        #expect(store.receipts.isEmpty, "no receipt until the step has ended")
        engine.advance(by: 4)
        store.keep(engine)
        store.keep(engine)
        let receipt = try #require(store.receipts.first)
        #expect(store.receipts.count == 1)
        #expect(receipt.outcome == .done)
        #expect(receipt.line == ReceiptWords.done)
        #expect(receipt.title == "Your details for Maple Dental")
        #expect(receipt.handle == "mapledental.example")
        #expect(receipt.details == SampleTasks.holdVisit.details)
        #expect(receipt.outcomeLine == SampleTasks.holdVisit.outcome)
        #expect(receipt.approvedAt == Self.base + 42)
        #expect(receipt.isSample)
        #expect(engine.tasks[0].state == .done)
        #expect(engine.tasks[0].history.filter { $0.mark == .approved }.count == 1)
        #expect(store.tasks.isEmpty, "an ended task isn't kept")
    }

    @Test func notNowEndsTheQuestionWithALineAndNoReceipt() throws {
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        let request = try #require(task.question)
        rule.withdraw(request)
        engine.questionClosed(request)
        let ended = engine.tasks[0]
        #expect(ended.state == .done)
        #expect(ended.history.last?.text == "You closed the question, so I didn't hold a Saturday visit.")
        #expect(ended.wrapUp?.notDone == ["hold a Saturday visit"])
        #expect(engine.takeReceipts().isEmpty)
    }

    @Test func aTimeoutEndsTheQuestionWithALineAndNoReceipt() throws {
        let clock = TestClock()
        let rule = AskFirst.isolated(now: clock.now)
        let (engine, task) = Self.atQuestion(rule: rule)
        clock.advance(301)
        engine.refresh()
        let ended = engine.tasks[0]
        #expect(ended.question == nil)
        #expect(ended.history.last?.text == "That question timed out, so I didn't hold a Saturday visit.")
        // A yes after the window approves nothing.
        #expect(rule.sayYes(to: try #require(task.question)) == .timedOut)
        #expect(engine.takeReceipts().isEmpty)
    }

    @Test func stoppingAfterAYesLeavesAReceiptThatSaysItMayBeDone() throws {
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        engine.stop(task.id)
        let receipts = engine.takeReceipts()
        #expect(receipts.map(\.outcome) == [.mayBeDone])
        #expect(engine.takeReceipts().isEmpty, "each receipt is handed over once")
    }

    // MARK: Closed and opened again

    @Test func aQuestionOutlastsTheAppClosingAndIsAskedAgainFresh() throws {
        let store = TaskStore.inMemory()
        let first = AskFirst.isolated()
        let (before, task) = Self.atQuestion(rule: first)
        store.keep(before)
        let saved = try #require(store.tasks.first)
        #expect(saved.phase == .waiting)
        #expect(saved.askedAt == Self.base + 42)

        // A minute later the app opens again: a new rule and a new engine.
        let clock = TestClock()
        let second = AskFirst.isolated(now: clock.now)
        let after = LocalFakeEngine(rule: second, origin: Self.base + 102)
        store.restore(into: after, now: Self.base + 102)
        let back = try #require(after.task(task.id))
        let question = try #require(back.question)
        #expect(back.waitsForApproval)
        #expect(question.action == SampleTasks.holdVisit)
        #expect(question.id != task.question?.id, "asked again, not brought back")
        #expect(back.history.map(\.text) == task.history.map(\.text))
        // The old question is gone with the old rule; nothing it made can work here.
        let oldYes = try Self.yes(try #require(task.question), rule: first)
        #expect(after.resume(task.id, with: oldYes) == .refused)
        // It keeps its deadline: one minute was spent, four are left.
        clock.advance(239)
        #expect(!second.isClosed(question))
        clock.advance(2)
        #expect(second.isClosed(question))
    }

    @Test func aQuestionAnsweredYesInTheNewLaunchGoesOnOnce() throws {
        let store = TaskStore.inMemory()
        let (before, task) = Self.atQuestion(rule: .isolated())
        store.keep(before)
        let rule = AskFirst.isolated()
        let after = LocalFakeEngine(rule: rule, origin: Self.base + 60)
        store.restore(into: after, now: Self.base + 60)
        let question = try #require(after.task(task.id)?.question)
        let approval = try Self.yes(question, rule: rule)
        #expect(after.resume(task.id, with: approval) == .proceeding)
        #expect(after.resume(task.id, with: approval) == .refused)
        after.advance(by: 4)
        store.keep(after)
        #expect(store.receipts.map(\.outcome) == [.done])
    }

    @Test func aQuestionWhoseTimeRanOutWhileClosedEndsAsATimeout() throws {
        let store = TaskStore.inMemory()
        let (before, task) = Self.atQuestion(rule: .isolated())
        store.keep(before)
        let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 400)
        store.restore(into: after, now: Self.base + 400)
        let back = try #require(after.task(task.id))
        #expect(back.question == nil)
        #expect(back.history.last?.text == "That question timed out, so I didn't hold a Saturday visit.")
        #expect(store.tasks.isEmpty, "saved again at once, so it never comes back twice")
    }

    @Test func aClockMovedBackNeverReopensAQuestion() throws {
        let store = TaskStore.inMemory()
        let (before, task) = Self.atQuestion(rule: .isolated())
        store.keep(before)
        let after = LocalFakeEngine(rule: .isolated(), origin: Self.base)
        store.restore(into: after, now: Self.base + 30)
        #expect(after.task(task.id)?.question == nil)
        #expect(after.task(task.id)?.history.last?.text == "That question timed out, so I didn't hold a Saturday visit.")
    }

    /// PERMANENT GUARD. A yes is never brought back after the app closes.
    /// A step said yes to and under way is never run again: it ends saying
    /// it may be done, and so does its receipt.
    @Test func aYesIsNeverReplayedAfterTheAppCloses() throws {
        let store = TaskStore.inMemory()
        let first = AskFirst.isolated()
        let (before, task) = Self.atQuestion(rule: first)
        _ = before.resume(task.id, with: try Self.yes(try #require(task.question), rule: first))
        store.keep(before)
        #expect(store.tasks.first?.phase == .approved)
        #expect(store.tasks.first?.approvedAt == Self.base + 42)

        let rule = AskFirst.isolated()
        let after = LocalFakeEngine(rule: rule, origin: Self.base + 43)
        store.restore(into: after, now: Self.base + 43)
        after.advance(by: 60)
        store.keep(after)
        let back = try #require(after.task(task.id))
        #expect(back.state == .failed)
        #expect(back.step == TaskWords.interrupted)
        #expect(back.question == nil)
        #expect(back.wrapUp?.underwayLine == "You said yes, so I'd already started to hold a Saturday visit. It may be done.")
        #expect(!back.history.contains { $0.text == SampleTasks.dentist.steps[3].text }, "the step never ran again")
        #expect(store.receipts.map(\.outcome) == [.mayBeDone])
        #expect(store.tasks.isEmpty)
        // Opening once more brings nothing back.
        let third = LocalFakeEngine(rule: .isolated(), origin: Self.base + 200)
        store.restore(into: third, now: Self.base + 200)
        #expect(third.tasks.isEmpty)
        #expect(store.receipts.count == 1)
    }

    @Test func workStillGoingPicksUpAtItsStep() throws {
        let store = TaskStore.inMemory()
        let before = LocalFakeEngine(rule: .isolated(), origin: Self.base)
        let id = before.start(SampleTasks.plan)
        before.advance(by: 8)
        store.keep(before)
        let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 100)
        store.restore(into: after, now: Self.base + 100)
        let back = try #require(after.task(id))
        #expect(back.state == .running)
        #expect(back.step == SampleTasks.plan.steps[1].text)
        // A new task never takes a kept task's id.
        #expect(after.start(SampleTasks.lunch) != id)
        after.advance(by: 30)
        #expect(after.task(id)?.state == .done)
    }

    @Test func aTaskAlreadyHereIsLeftAsItIs() {
        let store = TaskStore.inMemory()
        let (engine, _) = Self.atQuestion(rule: .isolated())
        store.keep(engine)
        let before = engine.tasks
        store.restore(into: engine, now: Self.base + 50)
        #expect(engine.tasks == before)
    }

    // MARK: The store

    @Test func theFileOutlastsTheStoreAndForgetLeavesOnlyTheNudgeChoice() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        let store = TaskStore(fileURL: url)
        store.keep(engine)
        store.setNudges(.declined)
        let again = TaskStore(fileURL: url)
        #expect(again.receipts == store.receipts)
        #expect(again.nudges == .declined)
        again.forget()
        let after = TaskStore(fileURL: url)
        #expect(after.receipts.isEmpty)
        #expect(after.tasks.isEmpty)
        #expect(after.nudges == .declined)
        after.setNudges(.notAsked)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing to keep, so no file")
    }

    @Test func anUnreadableFileIsNeverWrittenOver() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = TaskStore(fileURL: url)
        store.setNudges(.allowed)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }

    /// A store file in a folder of its own, holding one receipt and a
    /// declined nudge, as an earlier launch left it.
    private static func earlierFile() throws -> (folder: URL, url: URL, receipt: Receipt) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("tasks.json")
        let rule = AskFirst.isolated()
        let (engine, task) = atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        let earlier = TaskStore(fileURL: url)
        earlier.keep(engine)
        earlier.setNudges(.declined)
        return (folder, url, try #require(earlier.receipts.first))
    }

    private static func setReadable(_ url: URL, _ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000], ofItemAtPath: url.path)
    }

    /// PERMANENT GUARD. Forget everything removes the file even when it
    /// couldn't be read, as before the device is first unlocked, and
    /// nothing it held comes back once it could have been.
    @Test func forgetRemovesAFileThatCouldNotBeRead() throws {
        let (folder, url, _) = try Self.earlierFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.setReadable(url, false)
        let store = TaskStore(fileURL: url)
        #expect(store.receipts.isEmpty, "not read yet")
        store.forget()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no staging file either")
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(TaskStore(fileURL: url).receipts.isEmpty, "nothing comes back on the next launch")
    }

    @Test func forgetRemovesAFileThatCouldNotBeDecoded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        // As a later version might write it: a receipt this one can't read.
        try Data(#"{"tasks":[],"receipts":[{"kind":"teleport"}],"nudges":"allowed"}"#.utf8).write(to: url)
        try Data("half a write".utf8).write(to: folder.appendingPathComponent(".tasks.json.next"))
        let store = TaskStore(fileURL: url)
        store.forget()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(TaskStore(fileURL: url).receipts.isEmpty)
    }

    /// When the file can't even be removed, it is still forgotten: once it
    /// can be read, nothing it held comes back.
    @Test func aFileForgottenWhileItCouldNotBeRemovedNeverComesBack() throws {
        let (folder, url, _) = try Self.earlierFile()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try Self.setReadable(url, false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let store = TaskStore(fileURL: url)
        store.forget()
        #expect(FileManager.default.fileExists(atPath: url.path), "the folder won't let it go")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try Self.setReadable(url, true)
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(store.nudges == .declined, "the nudge choice is all it keeps")
        #expect(TaskStore(fileURL: url).receipts.isEmpty, "and the file says so now")
    }

    /// A file read late never takes back what changed since launch.
    @Test func aLateReadKeepsWhatChangedSinceLaunch() throws {
        let (folder, url, earlier) = try Self.earlierFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.setReadable(url, false)
        let store = TaskStore(fileURL: url)
        let (engine, task) = Self.atQuestion(rule: .isolated(), origin: Self.base + 1000)
        store.keep(engine)
        store.setNudges(.allowed)
        try Self.setReadable(url, true)
        #expect(store.tasks.map(\.id) == [task.id], "the task kept now, not the file's")
        #expect(store.nudges == .allowed)
        #expect(store.receipts.map(\.id) == [earlier.id], "the earlier receipt is still kept")
        let next = TaskStore(fileURL: url)
        #expect(next.tasks.map(\.id) == [task.id])
        #expect(next.nudges == .allowed)
        #expect(next.receipts.map(\.id) == [earlier.id])
    }

    @Test func aReceiptClearsAndTheOldestGoPastTheLimit() throws {
        let store = TaskStore.inMemory()
        for _ in 0..<(TaskStore.receiptLimit + 2) {
            let rule = AskFirst.isolated()
            let (engine, task) = Self.atQuestion(rule: rule)
            _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
            engine.advance(by: 4)
            store.keep(engine)
        }
        #expect(store.receipts.count == TaskStore.receiptLimit)
        let one = try #require(store.receipts.first)
        #expect(store.clearReceipt(one.id))
        #expect(!store.clearReceipt(one.id))
        #expect(store.receipts.count == TaskStore.receiptLimit - 1)
    }

    @Test func receiptsShowInTheFeedAmongTheRest() throws {
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        let store = TaskStore.inMemory()
        store.keep(engine)
        let feed = Feed.build(from: [ReceiptFeed(store: store)], now: Self.base + 60)
        let item = try #require(feed.groups.flatMap(\.items).first)
        #expect(item.kind == .receipt)
        #expect(item.receipt?.outcome == .done)
        #expect(item.spokenKind == ReceiptWords.label)
        #expect(item.action?.title == TaskWords.dismissTitle)
        #expect(feed.needsYou.isEmpty, "a receipt never asks anything")
    }

    // MARK: Only the app's own rule

    @Test func aQuestionFromAForeignRuleIsNeverPinned() throws {
        let (engine, task) = Self.atQuestion(rule: .isolated())
        let feed = Feed.build(from: [], needsYou: NeedsYou(rule: .isolated()), tasks: engine, now: Self.base + 60)
        #expect(task.waitsForApproval)
        #expect(!feed.needsYou.contains { $0.task?.question != nil })
    }

    // MARK: What a nudge says

    @Test func aNudgeNamesNothingTheQuestionHolds() throws {
        let (_, task) = Self.atQuestion(rule: .isolated())
        let nudge = QuestionNudge(question: try #require(task.question), taskID: task.id, agentName: "Pip")
        #expect(nudge.title == "Pip has a question for you")
        for held in [task.title, "Maple Dental", "mapledental.example", "Saturday", "phone"] {
            #expect(!nudge.title.contains(held))
        }
        #expect(nudge.taskID == task.id)
    }

    // MARK: Words

    @Test func flowWordsAreWarmAndPlain() {
        for line in ReceiptWords.all + NudgeWords.all + [TaskWords.interrupted] {
            #expect(!line.contains("!"), "exclamation in: \(line)")
            for avoid in ["retry", "error", "failed", "invalid", "timeout", "request", "N/A", "notification",
                          "permission", "authoriz", "record"] {
                #expect(!line.lowercased().contains(avoid.lowercased()), "\(avoid) in: \(line)")
            }
        }
    }
}

extension ReceiptWords {
    /// Every receipt line a person can see or hear.
    static var all: [String] {
        [label, done, mayBeDone, clearHint] + ConsequentialAction.allCases.map { title($0, "Maple Dental") }
    }
}

extension NudgeWords {
    /// Every nudge line a person can see or hear, the lock screen's included.
    static var all: [String] {
        [question("Pip"), offerTitle, offerDetail, allowTitle, declineTitle, off]
    }
}
