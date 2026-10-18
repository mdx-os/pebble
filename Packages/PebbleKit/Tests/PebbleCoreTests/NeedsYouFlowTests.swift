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
                         json.replacingOccurrences(of: #""kind":"sharePersonalInfo""#, with: #""kind":"purchase""#)] {
            #expect(tampered != json)
            let action = try JSONDecoder().decode(SavedAction.self, from: Data(tampered.utf8))
            #expect(action.action == nil, "\(tampered)")
            let after = LocalFakeEngine(rule: .isolated(), origin: Self.base + 43)
            after.restore([Self.replacing(saved, action: action)], now: Self.base + 43)
            #expect(after.takeReceipts().isEmpty)
            #expect(after.task(saved.id)?.step == TaskWords.interrupted)
        }
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

    /// A file that is read but can't be understood is moved aside, never
    /// written over, and never stops what happens now from being kept: a
    /// yes saved after it is on disk.
    @Test func aFileThatCannotBeDecodedIsMovedAsideAndTheStoreGoesOn() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tasks.json")
        try Data("not json".utf8).write(to: url)
        let store = TaskStore(fileURL: url)
        #expect(try Data(contentsOf: folder.appendingPathComponent(".tasks.json.unreadable")) == Data("not json".utf8))
        let rule = AskFirst.isolated()
        let (engine, task) = Self.atQuestion(rule: rule)
        _ = engine.resume(task.id, with: try Self.yes(try #require(task.question), rule: rule))
        store.keep(engine)
        store.setNudges(.allowed)
        let next = TaskStore(fileURL: url)
        #expect(next.tasks.map(\.phase) == [.approved], "the yes is on disk")
        #expect(next.nudges == .allowed)
        // Forget everything takes the one moved aside too, and keeps only
        // the nudge choice.
        next.forget()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["tasks.json"])
        let after = TaskStore(fileURL: url)
        #expect(after.tasks.isEmpty)
        #expect(after.nudges == .allowed)
    }

    /// A store file in a folder of its own, holding one receipt and a
    /// declined nudge, as an earlier launch left it, and where a forget
    /// still owed is written down, in another folder.
    private static func earlierFile() throws -> (folder: URL, url: URL, marker: URL, receipt: Receipt) {
        let folder = try folder()
        let url = folder.appendingPathComponent("tasks.json")
        let marker = try Self.folder().appendingPathComponent("tasks-forgotten")
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

    /// Permissions don't stop root, so these can't make a file unreadable there.
    static let canLockFiles = geteuid() != 0

    /// PERMANENT GUARD. Forget everything removes the file even when it
    /// couldn't be read, as before the device is first unlocked, and
    /// nothing it held comes back once it could have been. The nudge choice
    /// it held goes with it.
    @Test(.enabled(if: canLockFiles, "file permissions don't stop root"))
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
        #expect(store.nudges == .notAsked, "never read, so its choice went with it")
        let next = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(next.receipts.isEmpty, "nothing comes back on the next launch")
        #expect(next.nudges == .notAsked)
    }

    @Test func forgetRemovesAFileThatCouldNotBeDecoded() throws {
        let folder = try Self.folder()
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

    /// PERMANENT GUARD. When the file can't even be removed, it is still
    /// forgotten, even by a store opened after the app was killed: none
    /// reads it, and the first that can deletes it. The nudge choice goes
    /// with it, the same as when it could be removed.
    @Test(.enabled(if: canLockFiles, "file permissions don't stop root"))
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
        #expect(relaunched.nudges == .notAsked, "never read, so its choice went with it")
        let third = TaskStore(fileURL: url, forgetMarker: marker)
        #expect(third.receipts.isEmpty)
        #expect(third.nudges == .notAsked)
    }

    /// PERMANENT GUARD. Forget everything deletes the file first, even when
    /// it was read and the store is in use. A file that won't go is owed a
    /// forget, written down, and tried again at every later change.
    @Test(.enabled(if: canLockFiles, "file permissions don't stop root"))
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
        // only what is in memory now.
        try Self.setWritable(folder: folder, true)
        store.setNudges(.allowed)
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

    @Test func theForgetMarkerHasAFolderOfItsOwn() {
        let base = URL(fileURLWithPath: "/tmp/support")
        let (file, marker) = TaskStore.location(base: base)
        #expect(file.path == "/tmp/support/pebble/tasks/tasks.json")
        #expect(marker.deletingLastPathComponent() != file.deletingLastPathComponent())
        #expect(!marker.path.hasPrefix(file.deletingLastPathComponent().path))
    }

    /// A file read late never takes back what changed since launch.
    @Test(.enabled(if: canLockFiles, "file permissions don't stop root"))
    func aLateReadKeepsWhatChangedSinceLaunch() throws {
        let (folder, url, _, earlier) = try Self.earlierFile()
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
