import Foundation
import PebbleCore
import PebbleModel
import Testing

/// A wall clock and a monotonic clock that tests move by hand.
final class DigestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var instant = ContinuousClock.now

    init(_ date: Date = Date(timeIntervalSinceReferenceDate: 813_000_000)) { self.date = date }

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func instantNow() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: Double) {
        lock.lock()
        date += seconds
        instant += .milliseconds(Int64(seconds * 1000))
        lock.unlock()
    }
}

/// A model that may send words away, as a cloud model does.
struct LeavesTheDevice: ModelClient {
    func reply(to transcript: [ChatTurn]) async throws -> String { "" }
}

/// The app's real task engine, driven step by step: what it keeps across a
/// relaunch, Stop, asking first, and Forget everything.
struct DeviceTaskEngineTests {
    let folder: URL
    let notes: MemoryStore
    let clock = DigestClock()
    let rule: AskFirst

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        rule = AskFirst.isolated(now: clock.instantNow)
        let now = clock.now()
        try notes.remember("Sam's birthday is May 14. Loves lemon cake.", at: now - 2 * 86_400, source: .toldMe)
        try notes.remember("Dentist on Thursday at 3", at: now - 86_400, source: .fromApp("Calendar"))
        try notes.remember("Old note from last month", at: now - 30 * 86_400, source: .toldMe)
    }

    /// The engine as the app makes it, with steps left to the test.
    func engine() throws -> DeviceTaskEngine {
        try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, rule: rule, pace: nil, clock: clock.now))
    }

    var tasksFile: URL { folder.appendingPathComponent("tasks.json") }

    /// Runs the digest up to its question.
    func runToQuestion(_ engine: DeviceTaskEngine) throws -> (AgentTask, ConfirmationRequest) {
        engine.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        let task = try #require(engine.tasks.first)
        let question = try #require(task.question)
        #expect(task.state == .waitingOnYou)
        return (task, question)
    }

    // MARK: On device only

    @Test func aModelThatMayLeaveTheDeviceGetsNoEngine() {
        #expect(OnDeviceTasks.engine(model: LeavesTheDevice(), notes: notes) == nil)
        let engine = OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, rule: rule, pace: nil)
        #expect(engine?.place == LocalStubModel().privacyPlace)
    }

    /// The place is never written by hand: only the factory, which reads
    /// it from the model, makes an engine.
    @Test func onlyTheFactoryMakesTheEngine() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let app = sources.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        var makers: [String] = []
        for root in [sources, app] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files where try String(contentsOf: file, encoding: .utf8).contains("DeviceTaskEngine(") {
                makers.append(file.lastPathComponent)
            }
        }
        #expect(makers == ["OnDeviceTasks.swift"])
        let engine = try String(contentsOf: sources.appendingPathComponent("PebbleCore/DeviceTaskEngine.swift"), encoding: .utf8)
        for word in ["URLSession", "URLRequest", "http"] { #expect(!engine.contains(word), "\(word) in the engine") }
    }

    // MARK: Asking first

    @Test func nothingIsSavedWithoutAYes() throws {
        let engine = try engine()
        let before = notes.notes()
        let (task, question) = try runToQuestion(engine)
        // Read, written and asked, and still nothing new in the notes.
        #expect(notes.notes() == before)
        #expect(question.action.kind == .save)
        #expect(question.action.details.hasPrefix(DigestWords.heading))
        #expect(question.action.details.contains("Dentist on Thursday at 3"))
        #expect(!question.action.details.contains("Old note from last month"))

        // A yes for another question does nothing.
        let other = try #require(rule.ask(DigestTask.keep("Something else")))
        guard case .approved(let wrong) = rule.sayYes(to: other) else { Issue.record("no approval"); return }
        #expect(engine.resume(task.id, with: wrong) == .refused)
        #expect(notes.notes() == before)

        // Not now: the task ends and nothing is kept.
        rule.withdraw(question)
        engine.questionClosed(question)
        let ended = try #require(engine.tasks.first)
        #expect(ended.state == .done)
        #expect(ended.step == TaskWords.declined(DigestTask.saveTodo))
        #expect(ended.wrapUp?.notDone == [DigestTask.saveTodo])
        #expect(ended.result == nil)
        #expect(notes.notes() == before)
    }

    @Test func aQuestionThatTimesOutSavesNothing() throws {
        let engine = try engine()
        let before = notes.notes()
        let (_, question) = try runToQuestion(engine)
        clock.advance(AskFirst.defaultWindow + 1)
        engine.refresh()
        #expect(engine.tasks.first?.step == TaskWords.timedOut(DigestTask.saveTodo))
        #expect(rule.isClosed(question))
        #expect(notes.notes() == before)
    }

    @Test func aYesKeepsExactlyWhatWasAsked() throws {
        let engine = try engine()
        let before = notes.notes()
        let (task, question) = try runToQuestion(engine)
        guard case .approved(let approval) = rule.sayYes(to: question) else { Issue.record("no approval"); return }
        #expect(engine.resume(task.id, with: approval) == .proceeding)
        let after = notes.notes()
        #expect(after.count == before.count + 1)
        #expect(after.last?.text == question.action.details)
        #expect(after.last?.source == .inferred)
        let done = try #require(engine.tasks.first)
        #expect(done.state == .done)
        #expect(done.step == DigestWords.done)
        #expect(done.result == question.action.details)
        // The yes counts once.
        #expect(engine.resume(task.id, with: approval) == .refused)
        #expect(notes.notes().count == after.count)
    }

    // MARK: Stop

    @Test func stopEndsAtOnceAndNothingMoreHappens() throws {
        let engine = try engine()
        let before = notes.notes()
        let id = engine.start(DigestTask.request)
        engine.runPending()
        #expect(engine.stop(id))
        for _ in 0..<5 { engine.runPending() }
        let task = try #require(engine.tasks.first)
        #expect(task.state == .stopped)
        #expect(task.step == TaskWords.stopped)
        #expect(task.question == nil)
        #expect(task.wrapUp?.notDone == [DigestTask.saveTodo])
        #expect(notes.notes() == before)
        #expect(!engine.stop(id))
    }

    @Test func stopWhileAskingWithdrawsTheQuestion() throws {
        let engine = try engine()
        let before = notes.notes()
        let (task, question) = try runToQuestion(engine)
        #expect(engine.stop(task.id))
        #expect(rule.isClosed(question))
        #expect(rule.wasWithdrawn(question))
        // A yes that comes after Stop does nothing.
        #expect(rule.sayYes(to: question) == .timedOut)
        #expect(notes.notes() == before)
        #expect(engine.tasks.first?.state == .stopped)
    }

    // MARK: The task file and relaunch

    @Test func tasksAreKeptNextToTheNotesAndComeBack() throws {
        let engine = try engine()
        let (task, question) = try runToQuestion(engine)
        guard case .approved(let approval) = rule.sayYes(to: question) else { Issue.record("no approval"); return }
        _ = engine.resume(task.id, with: approval)
        #expect(engine.fileURL == tasksFile)
        #expect(FileManager.default.fileExists(atPath: tasksFile.path))

        let again = try self.engine()
        let back = try #require(again.tasks.first)
        #expect(back.id == task.id)
        #expect(back.title == DigestTask.title)
        #expect(back.state == .done)
        #expect(back.step == DigestWords.done)
        #expect(back.result == question.action.details)
        #expect(back.history.map(\.text) == engine.tasks.first?.history.map(\.text))
    }

    /// The draft and the notes read are never in the file: only what a card
    /// shows, and a digest only once it has been kept.
    @Test func theFileHoldsNoDraft() throws {
        let engine = try engine()
        _ = try runToQuestion(engine)
        let text = try String(contentsOf: tasksFile, encoding: .utf8)
        #expect(!text.contains("Dentist"))
        #expect(!text.contains("lemon cake"))
    }

    @Test func aTaskGoingWhenTheAppClosedComesBackStoppedNeverDone() throws {
        let engine = try engine()
        let (task, _) = try runToQuestion(engine)
        let again = try self.engine()
        let back = try #require(again.tasks.first)
        #expect(back.id == task.id)
        #expect(back.state == .stopped)
        #expect(back.step == DigestWords.stoppedWhenClosed)
        #expect(back.question == nil)
        #expect(back.result == nil)
        #expect(back.wrapUp?.notDone == [DigestTask.saveTodo])
        #expect(back.wrapUp?.underway == nil)
        // It is ended, so a new digest can start.
        #expect(again.start(DigestTask.request) != task.id)
    }

    /// A save the person said yes to that was under way when the app
    /// closed may have happened, so it is never called undone or done.
    @Test func aSaveUnderWayWhenTheAppClosedMayBeDone() throws {
        let json = """
            [{"id":"device-task:1","title":"\(DigestTask.title)","step":"\(DigestWords.saving)","state":"running",
              "history":[{"text":"You said yes.","mark":"approved","at":0}],"startedAt":0,"updatedAt":0,"saving":true}]
            """
        try Data(json.utf8).write(to: tasksFile)
        let back = try #require(try engine().tasks.first)
        #expect(back.state == .stopped)
        #expect(back.step == DigestWords.stoppedWhenClosed)
        #expect(back.wrapUp?.underway == DigestTask.saveTodo)
        #expect(back.wrapUp?.notDone == [])
        #expect(back.wrapUp?.underwayLine == TaskWords.mayBeDone(DigestTask.saveTodo))
    }

    // MARK: Forget everything

    @Test func clearForgetsEveryTaskAndErasesTheFile() throws {
        let engine = try engine()
        let (_, question) = try runToQuestion(engine)
        #expect(engine.hasStoredFile)
        let cleared = engine.clear()
        #expect(cleared == ClearedTasks(forgotten: 1, underway: 0, erased: true))
        #expect(engine.tasks.isEmpty)
        #expect(rule.isClosed(question))
        #expect(!FileManager.default.fileExists(atPath: tasksFile.path))
        #expect(!engine.hasStoredFile)
        #expect(try self.engine().tasks.isEmpty)
    }

    @Test(.enabled(if: getuid() != 0, "root can remove files from a locked folder"))
    func aFileThatCantBeErasedIsNeverCalledGone() throws {
        let engine = try engine()
        _ = try runToQuestion(engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let cleared = engine.clear()
        #expect(!cleared.erased)
        #expect(cleared.forgotten == 1)
        #expect(engine.tasks.isEmpty)
        #expect(engine.hasStoredFile)
    }

    // MARK: The digest

    @Test func theDigestFitsInOneNoteAndLeavesOutEarlierDigests() {
        let now = clock.now()
        var week = (0..<40).map { MemoryNote(text: "Note number \($0) " + String(repeating: "word ", count: 30),
                                             savedAt: now - Double($0) * 3_600, source: .toldMe) }
        week.append(MemoryNote(text: DigestWords.heading + ". Last week's", savedAt: now - 60, source: .inferred))
        let picked = DigestTask.thisWeek(week, now: now)
        #expect(picked.count == 40)
        let digest = DigestTask.digest(of: picked, now: now)
        #expect(digest.count <= MemoryStore.maxLength)
        #expect(digest.hasPrefix(DigestWords.heading))
        #expect(digest.hasSuffix("more notes."))
    }

    @Test func aWeekWithNoNotesEndsWithoutAsking() throws {
        let empty = MemoryStore(fileURL: folder.appendingPathComponent("empty.json"))
        let engine = try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: empty, rule: rule, pace: nil,
                                                       clock: clock.now))
        engine.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        let task = try #require(engine.tasks.first)
        #expect(task.state == .done)
        #expect(task.step == DigestWords.nothingThisWeek)
        #expect(task.question == nil)
        #expect(empty.notes().isEmpty)
    }

    @Test func onlyTheBuiltInTaskRuns() throws {
        let engine = try engine()
        #expect(engine.builtIns == [DigestTask.request])
        engine.start(TaskRequest(title: "Book a table"))
        #expect(engine.tasks.first?.state == .failed)
        #expect(engine.tasks.first?.step == DigestWords.cantDoThatYet)
    }
}
