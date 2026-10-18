import Foundation
@testable import PebbleCore
import SourceScan
import TestScratch
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
        clock.advance(1)
        #expect(!rule.isClosed(request), "200 seconds before plus 100 now is exactly five minutes, still open")
        clock.advance(0.001)
        #expect(rule.isClosed(request), "a moment past the five minutes, it closes")
    }

    @Test func askingAgainNeverOpensALapsedQuestion() {
        let rule = AskFirst.isolated()
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: 300) != nil, "exactly five minutes is still open")
        #expect(rule.askAgain(SampleTasks.holdVisit, askedAgo: 300.001) == nil)
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

    /// A question saved as asked in the future, as after the clock was
    /// moved back or the file was changed by hand, can't be given a true
    /// deadline. It ends as timed out and is never asked, then or later.
    @Test func aQuestionAskedInTheFutureTimesOutAndIsNeverAsked() throws {
        let store = TaskStore.inMemory()
        let (before, task) = Self.atQuestion(rule: .isolated())
        store.keep(before)
        let kept = try #require(store.tasks.first)
        #expect(kept.phase == .waiting)
        // An hour from now, as the file would hold it.
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(kept)) as? [String: Any])
        fields["askedAt"] = (Self.base + 3600).timeIntervalSinceReferenceDate
        let saved = try JSONDecoder().decode(SavedTask.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(saved.askedAt == Self.base + 3600)
        let rule = AskFirst.isolated()
        let after = LocalFakeEngine(rule: rule, origin: Self.base + 60)
        after.restore([saved], now: Self.base + 60)
        let back = try #require(after.task(task.id))
        #expect(back.question == nil)
        #expect(!back.waitsForApproval)
        #expect(back.history.last?.text == "That question timed out, so I didn't hold a Saturday visit.")
        after.advance(by: 600)
        after.refresh()
        #expect(after.tasks.allSatisfy { $0.question == nil }, "never asked later either")
        #expect(after.takeReceipts().isEmpty)
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
        #expect(back.state == .stopped, "it may have happened, so it never says it failed")
        #expect(back.state.label == TaskWords.stoppedLabel)
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

    /// The dentist search with a different question at its last step, as an
    /// update to the script might make it.
    private static func dentist(asking action: ProposedAction) -> TaskScript {
        var steps = SampleTasks.dentist.steps
        let last = steps.removeLast()
        steps.append(.init(last.text, kind: .ask(action, askLine: "May I?"), duration: last.duration,
                           kept: last.kept, todo: last.todo))
        return TaskScript(title: SampleTasks.dentistTitle, steps: steps, doneLine: SampleTasks.dentist.doneLine)
    }

    /// A yes under way, saved as the app closed.
    private static func savedYes() throws -> SavedTask {
        let store = TaskStore.inMemory()
        let rule = AskFirst.isolated()
        let (before, task) = atQuestion(rule: rule)
        _ = before.resume(task.id, with: try yes(try #require(task.question), rule: rule))
        store.keep(before)
        return try #require(store.tasks.first)
    }

    /// The same saved task with its kept yes swapped.
    private static func replacing(_ saved: SavedTask, action: SavedAction?) -> SavedTask {
        SavedTask(id: saved.id, title: saved.title, step: saved.step, phase: saved.phase, askedAt: saved.askedAt,
                  approvedAt: saved.approvedAt, approvedAction: action, kept: saved.kept, notDone: saved.notDone,
                  history: saved.history, startedAt: saved.startedAt)
    }

    /// PERMANENT GUARD. A receipt after a restart says what the person said
    /// yes to, as it was kept then, never what today's script says.
    @Test func aReceiptAfterARestartIsMadeFromWhatWasApproved() throws {
        let saved = try Self.savedYes()
        #expect(saved.approvedAction == SavedAction(SampleTasks.holdVisit))
        let changed = ProposedAction(kind: .sharePersonalInfo,
                                     recipient: Recipient(id: "clinic:other", displayName: "Other Dental", handle: "other.example"),
                                     details: "Your name, phone number and birthday", outcome: "I'll book Sunday.")
        let after = LocalFakeEngine(rule: .isolated(), scripts: [Self.dentist(asking: changed)], origin: Self.base + 43)
        after.restore([saved], now: Self.base + 43)
        let receipt = try #require(after.takeReceipts().first)
        #expect(receipt.recipientName == "Maple Dental")
        #expect(receipt.handle == "mapledental.example")
        #expect(receipt.details == SampleTasks.holdVisit.details)
        #expect(receipt.outcomeLine == SampleTasks.holdVisit.outcome)
        #expect(receipt.outcome == .mayBeDone)
    }

    @Test func aYesKeptWithoutItsActionLeavesNoReceiptAndNeverRunsAgain() throws {
        let saved = Self.replacing(try Self.savedYes(), action: nil)
        let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 43)
        after.restore([saved], now: Self.base + 43)
        after.advance(by: 60)
        #expect(after.takeReceipts().isEmpty, "nothing to say what was approved, so no receipt")
        let back = try #require(after.task(saved.id))
        #expect(back.step == TaskWords.interrupted)
        #expect(back.wrapUp?.underway == "hold a Saturday visit", "the card still says it may be done")
    }

    /// A file changed by hand never puts hidden words in a receipt.
    @Test func aTamperedYesLeavesNoReceipt() throws {
        let saved = try Self.savedYes()
        let honest = try #require(saved.approvedAction)
        let json = String(decoding: try JSONEncoder().encode(honest), as: UTF8.self)
        for tampered in [json.replacingOccurrences(of: "Saturday at 10:30", with: "Saturday at 10:30\\u202E"),
                         json.replacingOccurrences(of: "mapledental.example", with: "mapledental.example\\u200B"),
                         json.replacingOccurrences(of: #""kind":"sharePersonalInfo""#, with: #""kind":"purchase""#),
                         // The kind kept, the recipient's id changed.
                         json.replacingOccurrences(of: #""recipientID":"\#(honest.recipientID)""#,
                                                   with: #""recipientID":"\#(honest.recipientID)\#u{200B}""#),
                         json.replacingOccurrences(of: #""recipientID":"\#(honest.recipientID)""#,
                                                   with: #""recipientID":"""#),
                         json.replacingOccurrences(of: #""recipientName":"Maple Dental""#,
                                                   with: #""recipientName":"Maple\#u{202E}Dental""#)] {
            #expect(tampered != json)
            let action = try JSONDecoder().decode(SavedAction.self, from: Data(tampered.utf8))
            #expect(action.action == nil, "\(tampered)")
            let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 43)
            after.restore([Self.replacing(saved, action: action)], now: Self.base + 43)
            #expect(after.takeReceipts().isEmpty)
            #expect(after.task(saved.id)?.step == TaskWords.interrupted)
        }
    }

    /// PERMANENT GUARD. No source file holds a hidden or reordering
    /// character as itself, where a reader can't see it and an editor can
    /// drop it without a trace. Tests that need one write it as an escape,
    /// such as `\u{202E}`.
    @Test func noSourceHoldsAHiddenCharacterAsItself() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        var scanned = 0
        for folder in ["Packages/PebbleKit/Sources", "Packages/PebbleKit/Tests", "App", "AppUITests"] {
            for file in try SwiftSource.files(under: root.appendingPathComponent(folder)) {
                scanned += 1
                for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where AskFirst.hasHiddenScalars(String(line)) {
                    Issue.record("\(folder)/\(file.name):\(number + 1) holds a hidden character as itself")
                }
            }
        }
        #expect(scanned > 50)
        // The check sees one when it is there.
        #expect(AskFirst.hasHiddenScalars("Maple\u{202E}Dental"))
        #expect(AskFirst.hasHiddenScalars("id\u{200B}"))
    }

    /// A waiting question whose words carry hidden characters is never
    /// asked again, whatever the file says.
    @Test func aTamperedWaitingQuestionIsNeverAskedAgain() throws {
        let store = TaskStore.inMemory()
        let (before, task) = Self.atQuestion(rule: .isolated())
        store.keep(before)
        let saved = try #require(store.tasks.first)
        #expect(saved.phase == .waiting)
        let hidden = [
            ProposedAction(kind: .sharePersonalInfo, recipient: SampleTasks.holdVisit.recipient,
                           details: SampleTasks.holdVisit.details, outcome: "I'll hold Saturday\u{202E} at 10:30."),
            ProposedAction(kind: .sharePersonalInfo, recipient: SampleTasks.holdVisit.recipient,
                           details: "Your name\u{202E} and phone number", outcome: SampleTasks.holdVisit.outcome),
        ]
        for action in hidden {
            let rule = AskFirst.isolated()
            let after = LocalFakeEngine(rule: rule, scripts: [Self.dentist(asking: action)], origin: Self.base + 60)
            after.restore([saved], now: Self.base + 60)
            let back = try #require(after.task(task.id))
            #expect(back.question == nil)
            #expect(!back.waitsForApproval)
            let feed = Feed.build(from: [], needsYou: NeedsYou(rule: rule), tasks: after, now: Self.base + 60)
            #expect(!feed.needsYou.contains { $0.task?.id == task.id })
        }
        // A step that doesn't ask, or isn't there, is never asked either.
        for step in [0, -1, 99] {
            let odd = SavedTask(id: saved.id, title: saved.title, step: step, phase: .waiting, askedAt: saved.askedAt,
                                startedAt: saved.startedAt)
            let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 60)
            after.restore([odd], now: Self.base + 60)
            #expect(after.task(saved.id)?.question == nil, "step \(step)")
        }
    }

    /// PERMANENT GUARD. A step said yes to never stalls into stuck, however
    /// long it takes, so Try again can never run it a second time. Kept as
    /// approved all the while.
    @Test func aStepSaidYesToNeverStalls() throws {
        var steps = SampleTasks.dentist.steps
        let last = steps.removeLast()
        steps.append(.init(last.text, kind: last.kind, duration: 10_000, kept: last.kept, todo: last.todo))
        let slow = TaskScript(title: "Slow", steps: steps, doneLine: "Done.")
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.base)
        let id = engine.start(slow)
        engine.advance(by: 42)
        let question = try #require(engine.task(id)?.question)
        #expect(engine.resume(id, with: try Self.yes(question, rule: rule)) == .proceeding)
        for _ in 0..<20 {
            engine.advance(by: RetryPolicy.standard.timeout * 5)
            let task = try #require(engine.task(id))
            #expect(task.state == .running, "never stalled, stuck or retried")
            #expect(!task.isStuck)
            #expect(!engine.retry(id))
            #expect(engine.saved().first?.phase == .approved)
        }
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
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        store.keep(engine)
        store.setNudges(.declined)
        let again = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(again.receipts == store.receipts)
        #expect(again.nudges == .declined)
        #expect(FileManager.default.fileExists(atPath: url.path), "a receipt is kept, so there is a file")
        again.forget()
        #expect(!FileManager.default.fileExists(atPath: url.path), "only the choice is left, and it is kept apart")
        let after = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(after.receipts.isEmpty)
        #expect(after.tasks.isEmpty)
        #expect(after.nudges == .declined)
        #expect(!FileManager.default.fileExists(atPath: url.path), "reading the choice back writes no file")
    }

    /// A file that is read but can't be understood is deleted: nothing
    /// could ever read it back, and the person couldn't see or clear what
    /// it held. It never stops what happens now from being kept: a yes
    /// saved after it is on disk.
    @Test func aFileThatCannotBeDecodedIsDeletedAndTheStoreGoesOn() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        try Data("not json, Maple Dental".utf8).write(to: url)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "gone, not moved aside")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "nothing is owed")
        // It may have held a yes under way, so Today is told something went,
        // once.
        #expect(store.clearedUnreadable)
        store.saidUnreadableCleared()
        #expect(!store.clearedUnreadable)
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        store.keep(engine)
        store.setNudges(.allowed)
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.tasks.map(\.phase) == [.approved], "the yes is on disk")
        #expect(next.nudges == .allowed)
        #expect(!next.clearedUnreadable, "a file that reads clears nothing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["tasks.json"])
    }

    /// PERMANENT GUARD. A receipt changed on disk into one no question could
    /// have shown is dropped as it is read, the same checks a kept yes
    /// gets, so a card that says "You said yes" never shows hidden or
    /// reordering characters. The honest one stays, and the file is written
    /// again without the rest.
    @Test func aReceiptChangedOnDiskIsDropped() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        let honest = Receipt(action: SampleTasks.holdVisit, taskTitle: SampleTasks.dentistTitle,
                             approvedAt: Self.base, endedAt: Self.base, outcome: .done, isSample: true)
        #expect(honest.couldHaveBeenAsked)
        let json = String(decoding: try JSONEncoder().encode(honest), as: UTF8.self)
        let changes = [
            ("mapledental.example", "mapledental.example\\u200B"),
            ("mapledental.example", "maple\\u202Edental.example"),
            ("mapledental.example", " mapledental.example"),
            ("Maple Dental", "Maple\\u202EDental"),
            ("Maple Dental", "Maple  Dental"),
            ("Saturday at 10:30", "Saturday at 10:30\\u202E"),
            (SampleTasks.dentistTitle, SampleTasks.dentistTitle + "\\u2066"),
            (#""kind":"sharePersonalInfo""#, #""kind":"purchase""#),
        ]
        var all = [honest]
        for (from, to) in changes {
            // Each a receipt of its own, as a changed file would hold them.
            let changed = json.replacingOccurrences(of: from, with: to)
                .replacingOccurrences(of: honest.id.uuidString, with: UUID().uuidString)
            #expect(json.contains(from), "the change to \(from) is made")
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(changed.utf8))
            #expect(!receipt.couldHaveBeenAsked, "\(changed)")
            all.append(receipt)
        }
        #expect(Set(all.map(\.id)).count == all.count)
        try JSONEncoder().encode(TaskStore.State(receipts: all)).write(to: url)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(store.receipts.map(\.id) == [honest.id])
        let written = try JSONDecoder().decode(TaskStore.State.self, from: Data(contentsOf: url))
        #expect(written.receipts.map(\.id) == [honest.id], "written again without them")
    }

    /// PERMANENT GUARD. The file holds receipts, which name who a yes went
    /// to, and the on-device engine's tasks, so where the system protects
    /// files it can be read only while the device is unlocked, as the notes
    /// are. The nudge choice and the marker hold nothing of the person's and
    /// must be read and written while it may still be locked, so they have
    /// no protection.
    @Test func eachFileIsWrittenWithTheProtectionItNeeds() throws {
        let mask = Data.WritingOptions.fileProtectionMask
        let file = TaskStore.fileWriting(protected: true).intersection(mask)
        #expect(file == .completeFileProtection, "the file is written with \(file.rawValue)")
        #expect(TaskStore.fileWriting(protected: true).contains(.withoutOverwriting))
        #expect(TaskStore.choiceWriting(protected: true).intersection(mask) == .noFileProtection)
        #expect(TaskStore.markerWriting(protected: true).intersection(mask) == .noFileProtection)
        // Where nothing is protected, nothing asks for it.
        for options in [TaskStore.fileWriting(protected: false), TaskStore.choiceWriting(protected: false),
                        TaskStore.markerWriting(protected: false)] {
            #expect(options.intersection(mask).isEmpty)
        }
        #if os(macOS)
        #expect(!TaskStore.protectsFiles)
        #else
        #expect(TaskStore.protectsFiles)
        #endif
        // Every write in the store goes through these.
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleCore/TaskStore.swift"),
                              encoding: .utf8)
        let writes = SwiftSource(text).calls(named: ["write"]).filter { $0.arguments.hasPrefix("to:") }
        #expect(writes.count == 3, "\(writes.map(\.arguments))")
        for call in writes {
            #expect(["Self.fileWriting()", "Self.choiceWriting()", "Self.markerWriting()"].contains { call.arguments.contains($0) },
                    "\(call.arguments)")
        }
    }

    /// A file that can't be understood and won't go is owed a forget, so
    /// it is never read and goes as soon as it can.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aFileThatCannotBeDecodedAndWontGoIsOwedAForget() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        try Data("not json".utf8).write(to: url)
        try Self.setWritable(folder: folder, false)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try Self.setWritable(folder: folder, true)
        #expect(store.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A store file in a folder of its own, holding one receipt and a
    /// declined nudge, as an earlier launch left it, and where a forget
    /// still owed is written down, in another folder.
    private static func earlierFile() throws -> (folder: URL, url: URL, marker: URL, receipt: Receipt) {
        let folder = try folder()
        let url = folder.appendingPathComponent("tasks.json")
        let marker = try Self.marker()
        let rule = AskFirst.isolated()
        let (engine, task) = atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        let earlier = TaskStore(fileURL: url, forgetMarker: marker)
        earlier.keep(engine)
        earlier.setNudges(.declined)
        return (folder, url, marker, try #require(earlier.receipts.first))
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Where a forget still owed is written down, in a temporary folder of
    /// its own, so no test shares one with another or with the app.
    private static func marker() throws -> URL {
        try folder().appendingPathComponent("tasks-forgotten")
    }

    private static func setReadable(_ url: URL, _ readable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000], ofItemAtPath: url.path)
    }

    private static func setWritable(folder: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    private static func cleanUp(_ folders: URL...) {
        for folder in folders {
            try? setWritable(folder: folder, true)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// PERMANENT GUARD. Forget everything removes the file even when it
    /// couldn't be read, as before the device is first unlocked, and
    /// nothing it held comes back once it could have been. The nudge
    /// choice, kept apart from it, stays.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func forgetRemovesAFileThatCouldNotBeRead() throws {
        let (folder, url, marker, _) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        try Self.setReadable(url, false)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(store.receipts.isEmpty, "not read yet")
        store.forget()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no staging file either")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "nothing is owed")
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(store.nudges == .declined, "kept apart, so it stays though the file was never read")
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.receipts.isEmpty, "nothing comes back on the next launch")
        #expect(next.nudges == .declined)
    }

    /// PERMANENT GUARD. The same button gives the same result: Forget
    /// everything keeps the nudge choice whether the file could be read or
    /// not, as when the device hasn't been unlocked since it started.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func forgetKeepsTheNudgeChoiceWhetherOrNotTheFileWasRead() throws {
        var kept: [NudgeChoice] = []
        for readable in [true, false] {
            let (folder, url, marker, _) = try Self.earlierFile()
            defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
            if !readable { try Self.setReadable(url, false) }
            let store = TaskStore(fileURL: url, forgetMarker: marker)
            store.forget()
            #expect(store.receipts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            kept.append(store.nudges)
            kept.append(TaskStore(fileURL: url, forgetMarker: marker).nudges)
        }
        #expect(kept == [.declined, .declined, .declined, .declined])
    }

    /// The choice kept apart holds nothing else: one word, and no file at
    /// all once it is back to not asked.
    @Test func theNudgeChoiceKeptApartHoldsOnlyTheChoice() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let store = TaskStore(fileURL: folder.appendingPathComponent("tasks.json"), forgetMarker: marker)
        store.setNudges(.allowed)
        let choice = marker.deletingLastPathComponent().appendingPathComponent("nudge-choice")
        #expect(try String(contentsOf: choice, encoding: .utf8) == "allowed")
        store.setNudges(.notAsked)
        #expect(!FileManager.default.fileExists(atPath: choice.path))
    }

    @Test func forgetRemovesAFileThatCouldNotBeDecoded() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        // As a later version might write it: a receipt this one can't read.
        try Data(#"{"tasks":[],"receipts":[{"kind":"teleport"}],"nudges":"allowed"}"#.utf8).write(to: url)
        try Data("half a write".utf8).write(to: folder.appendingPathComponent(".tasks.json.next"))
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        store.forget()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(TaskStore(fileURL: url, forgetMarker: marker).receipts.isEmpty)
    }

    /// PERMANENT GUARD. When the file can't even be removed, it is still
    /// forgotten, even by a store opened after the app was killed: none
    /// reads it, and the first that can deletes it. The nudge choice stays,
    /// the same as when it could be removed.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aFileForgottenWhileItCouldNotBeRemovedNeverComesBack() throws {
        let (folder, url, marker, _) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        try Self.setReadable(url, false)
        try Self.setWritable(folder: folder, false)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        store.forget()
        #expect(FileManager.default.fileExists(atPath: url.path), "the folder won't let it go")
        #expect(FileManager.default.fileExists(atPath: marker.path), "the forget is written down")
        // The app is killed. The next launch opens a new store before the
        // file can be read, and then it can be.
        let relaunched = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(relaunched.receipts.isEmpty)
        try Self.setReadable(url, true)
        #expect(relaunched.receipts.isEmpty, "readable now, and still never read")
        #expect(relaunched.tasks.isEmpty)
        #expect(store.receipts.isEmpty)
        // The folder lets go: the first look deletes it.
        try Self.setWritable(folder: folder, true)
        #expect(relaunched.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(relaunched.nudges == .declined, "kept apart, so it stays")
        let third = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(third.receipts.isEmpty)
        #expect(third.nudges == .declined)
    }

    /// PERMANENT GUARD. Forget everything deletes the file first, even when
    /// it was read and the store is in use. A file that won't go is owed a
    /// forget, written down, and tried again at every later change.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func forgetDeletesTheFileFirstEvenWhenItWasRead() throws {
        let (folder, url, marker, receipt) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(store.receipts.map(\.id) == [receipt.id], "read and in use")
        try Self.setWritable(folder: folder, false)
        store.forget()
        #expect(store.receipts.isEmpty)
        #expect(TaskStore(fileURL: url, forgetMarker: marker).receipts.isEmpty, "a new launch never reads it")
        // A later change, once the folder lets go, deletes it and writes
        // only what is in memory now: a new task, and not the old receipt.
        try Self.setWritable(folder: folder, true)
        store.setNudges(.allowed)
        #expect(!FileManager.default.fileExists(atPath: url.path), "only the choice is left, and it is kept apart")
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.base)
        engine.start(SampleTasks.plan)
        store.keep(engine)
        let data = try Data(contentsOf: url)
        #expect(!String(decoding: data, as: UTF8.self).contains("Maple Dental"))
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.receipts.isEmpty)
        #expect(next.nudges == .allowed)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A store whose folder couldn't be opened keeps everything in memory,
    /// and Forget everything still deletes what an earlier launch left.
    @Test func aStoreThatCouldNotOpenItsFolderStillForgetsTheFileThere() throws {
        let (folder, url, marker, _) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        try Data("half a write".utf8).write(to: folder.appendingPathComponent(".tasks.json.next"))
        let store = TaskStore(forgetOnly: url, forgetMarker: marker)
        #expect(store.receipts.isEmpty, "it never reads the file")
        store.setNudges(.allowed)
        #expect(FileManager.default.fileExists(atPath: url.path), "nor writes it")
        store.forget()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(store.nudges == .allowed)
    }

    /// A forget an earlier launch still owed is carried out by a store that
    /// couldn't open its folder, as soon as it opens.
    @Test func aStoreThatCouldNotOpenItsFolderCarriesOutAForgetStillOwed() throws {
        let (folder, url, marker, _) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        try Data().write(to: marker)
        _ = TaskStore(forgetOnly: url, forgetMarker: marker)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// The file lives in the app's own folder. The marker has a folder of
    /// its own beside the file's. `DiskNameTests` checks the folder's name.
    @Test func theStoreLivesInTheAppsFolderAndTheMarkerInOneOfItsOwn() {
        let base = URL(fileURLWithPath: "/tmp/support")
        let (file, marker) = TaskStore.location(base: base, app: TaskStore.appFolder)
        let root = base.appendingPathComponent(TaskStore.appFolder)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        #expect(marker.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        #expect(marker.deletingLastPathComponent() != file.deletingLastPathComponent())
        #expect(!marker.path.hasPrefix(file.deletingLastPathComponent().path))
        #expect(file.lastPathComponent == "tasks.json")
        let other = TaskStore.location(base: base, app: "other-folder")
        #expect(other.file != file, "another folder is another place")
    }

    /// PERMANENT GUARD. While the file can't be opened, as while the device
    /// is locked, nothing about tasks changes: a `keep` then is refused, not
    /// held in memory to write once it opens, so a launch killed before then
    /// loses nothing. The file read late is taken as it is. Only the nudge
    /// choice, kept apart, still changes.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aStoreThatWontOpenTakesNoChangeToTasks() throws {
        let (folder, url, marker, earlier) = try Self.earlierFile()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let saved = TaskStore(fileURL: url, forgetMarker: marker).tasks.map(\.id)
        try Self.setReadable(url, false)
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        let (engine, _) = Self.atQuestion(rule: .isolated(), origin: Self.base + 1000)
        store.keep(engine)
        store.setNudges(.allowed)
        #expect(store.tasks.isEmpty, "nothing taken while it is shut")
        #expect(store.receipts.isEmpty)
        try Self.setReadable(url, true)
        #expect(try Data(contentsOf: url) == before, "the file was never written")
        #expect(store.tasks.map(\.id) == saved, "the file's tasks, as they were")
        #expect(store.nudges == .allowed)
        #expect(store.receipts.map(\.id) == [earlier.id], "the earlier receipt is still kept")
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.tasks.map(\.id) == saved)
        #expect(next.nudges == .allowed)
        #expect(next.receipts.map(\.id) == [earlier.id])
    }

    /// PERMANENT GUARD. A file read late never drops the tasks it saved,
    /// even after a `keep` from before the read that knew none of them. An
    /// approved step under way still ends saying it may be done, with its
    /// receipt, and is never run again.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aLateReadNeverDropsSavedTasks() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        let saved = try Self.savedYes()
        // As an earlier launch left it.
        try JSONEncoder().encode(TaskStore.State(tasks: [saved])).write(to: url)
        try Self.setReadable(url, false)

        // Launched before the first unlock: nothing can be read.
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        let heard = Heard()
        _ = store.observe { heard.add() }
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.base + 43)
        store.restore(into: engine, now: Self.base + 43)
        #expect(engine.tasks.isEmpty)
        store.keep(engine, now: Self.base + 43)
        let before = heard.count

        // Unlocked. The read brings the task in, and says so.
        try Self.setReadable(url, true)
        #expect(store.tasks.map(\.phase) == [.approved])
        #expect(store.hasLateTasks)
        #expect(heard.count > before, "watchers hear that it arrived")
        // The next keep, which knows nothing of it, picks it up first.
        store.keep(engine, now: Self.base + 44)
        #expect(!store.hasLateTasks)
        let back = try #require(engine.task(saved.id))
        #expect(back.step == TaskWords.interrupted)
        #expect(back.wrapUp?.underway == "hold a Saturday visit")
        #expect(store.receipts.map(\.outcome) == [.mayBeDone])
        #expect(store.tasks.isEmpty, "ended, so nothing left to pick up")
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.receipts.map(\.outcome) == [.mayBeDone])
    }

    /// PERMANENT GUARD. Clearing the last receipt when its file won't go
    /// is owed a forget, written down, so the receipt never comes back,
    /// even after the app is killed.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aReceiptClearedWhenItsFileWontGoNeverComesBack() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        engine.advance(by: 4)
        store.keep(engine)
        let receipt = try #require(store.receipts.first)
        try Self.setWritable(folder: folder, false)
        #expect(store.clearReceipt(receipt.id))
        #expect(FileManager.default.fileExists(atPath: url.path), "the folder won't let it go")
        #expect(FileManager.default.fileExists(atPath: marker.path), "the clear is written down")
        // The app is killed. The next launch never reads it.
        let relaunched = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(relaunched.receipts.isEmpty)
        try Self.setWritable(folder: folder, true)
        #expect(relaunched.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(TaskStore(fileURL: url, forgetMarker: marker).receipts.isEmpty)
    }

    /// PERMANENT GUARD. A rewrite that fails after a clear stays owed and
    /// is tried again at the next look, so the cleared receipt is gone from
    /// the file as soon as the file can be written.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func aClearThatCouldNotBeWrittenIsWrittenAtTheNextLook() throws {
        let folder = try Self.folder()
        let marker = try Self.marker()
        defer { Self.cleanUp(folder, marker.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("tasks.json")
        let store = TaskStore(fileURL: url, forgetMarker: marker)
        for _ in 0..<2 {
            let rule = AskFirst.isolated()
            let (engine, task) = Self.atQuestion(rule: rule)
            _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
            engine.advance(by: 4)
            store.keep(engine)
        }
        let receipts = store.receipts
        #expect(receipts.count == 2)
        try Self.setWritable(folder: folder, false)
        #expect(store.clearReceipt(receipts[0].id))
        #expect(TaskStore(fileURL: url, forgetMarker: marker).receipts.count == 2, "not written yet")
        try Self.setWritable(folder: folder, true)
        #expect(store.receipts.map(\.id) == [receipts[1].id])
        #expect(TaskStore(fileURL: url, forgetMarker: marker).receipts.map(\.id) == [receipts[1].id])
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

    /// PERMANENT GUARD. Only the rule Today asks through can pin a
    /// question, so no other can be answered from its card.
    @Test func aQuestionFromAForeignRuleIsNeverPinned() throws {
        let (engine, task) = Self.atQuestion(rule: .isolated())
        let feed = Feed.build(from: [], needsYou: NeedsYou(rule: .isolated()), tasks: engine, now: Self.base + 60)
        #expect(task.waitsForApproval)
        #expect(!feed.needsYou.contains { $0.id == task.id || $0.task?.id == task.id },
                "not pinned at all, with its question or without")
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
                          "alert", "permission", "authoriz", "record"] {
                #expect(!line.lowercased().contains(avoid.lowercased()), "\(avoid) in: \(line)")
            }
        }
    }

    /// After the system said no, the line says where nudges can be turned
    /// on. After No thanks it doesn't: the system was never asked, so
    /// Settings has nothing to turn on.
    @Test func onlyTheSystemsNoPointsToSettings() {
        #expect(NudgeWords.offBySystem.contains(NudgeWords.settingsName))
        #expect(NudgeWords.offBySystem.hasPrefix(NudgeWords.off.dropLast()))
        #expect(!NudgeWords.off.contains("Settings"))
    }
}

/// Counts calls from any thread.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func add() { lock.lock(); calls += 1; lock.unlock() }
}

extension ReceiptWords {
    /// Every receipt line a person can see or hear.
    static var all: [String] {
        [label, done, mayBeDone, clearHint, unreadableCleared]
            + ConsequentialAction.allCases.flatMap { kind in
                [title(kind, "Maple Dental"), clearLabel(kind, "Maple Dental"), cleared(kind, "Maple Dental")]
            }
    }
}

extension NudgeWords {
    /// Every nudge line a person can see or hear, the lock screen's included.
    static var all: [String] {
        [question("Pip"), on, offerTitle, offerDetail, allowTitle, declineTitle, off, offBySystem]
    }
}
