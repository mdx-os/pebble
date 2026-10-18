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

/// Every snapshot an observer was told, from any thread.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [TaskSnapshot] = []

    func add(_ snapshot: TaskSnapshot) { lock.lock(); snapshots.append(snapshot); lock.unlock() }
    var all: [TaskSnapshot] { lock.lock(); defer { lock.unlock() }; return snapshots }
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

    /// The place is never written by hand. The engine is made only from an
    /// `OnDeviceTasks.Key`, which only `OnDeviceTasks.swift` can make, so
    /// the compiler refuses any other maker. This checks the one maker
    /// there is: its place is the model's, every time.
    @Test func theFactoryTakesThePlaceFromTheModel() throws {
        let first = try engine()
        let second = try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: notes))
        #expect(first.place == LocalStubModel().privacyPlace)
        #expect(second.place == LocalStubModel().privacyPlace)
        #expect(first.place.staysOnDevice)
    }

    @Test func theEngineNeverReachesTheNetwork() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleModel/DeviceTaskEngine.swift")
        let engine = try String(contentsOf: file, encoding: .utf8)
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
        // Each note's line keeps where that note came from.
        #expect(question.action.details.contains("Dentist on Thursday at 3 (From Calendar)"))
        #expect(question.action.details.contains("Loves lemon cake. (You told me)"))
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

    /// Keeps a digest and returns it with the engine, the task's id and
    /// the note it became.
    func keepDigest() throws -> (DeviceTaskEngine, String, MemoryNote) {
        let engine = try engine()
        let (task, question) = try runToQuestion(engine)
        guard case .approved(let approval) = rule.sayYes(to: question) else { throw ApprovalMissing() }
        #expect(engine.resume(task.id, with: approval) == .proceeding)
        let kept = try #require(notes.notes().last)
        #expect(kept.text == question.action.details)
        return (engine, task.id, kept)
    }

    struct ApprovalMissing: Error {}

    /// A kept digest's words live only in the notes. The file never holds
    /// them, and once the digest note and a note it quoted are forgotten,
    /// nothing of either is left in the file or on the card, then or after
    /// a relaunch.
    @Test func forgettingTheNotesLeavesNothingOfThemBehind() throws {
        let (engine, id, kept) = try keepDigest()
        #expect(engine.tasks.first?.result == kept.text)
        let file = try String(contentsOf: tasksFile, encoding: .utf8)
        #expect(!file.contains("Dentist"))
        #expect(!file.contains(DigestWords.heading))

        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        #expect(try notes.forget(dentist.id))
        #expect(try notes.forget(kept.id))
        engine.refresh()
        let card = try #require(engine.tasks.first { $0.id == id })
        #expect(card.result == nil)
        #expect(card.step == DigestWords.removed)

        let again = try self.engine()
        let back = try #require(again.tasks.first { $0.id == id })
        #expect(back.result == nil)
        #expect(back.step == DigestWords.removed)
        for text in [try String(contentsOf: tasksFile, encoding: .utf8), "\(back)"] {
            #expect(!text.contains("Dentist"))
            #expect(!text.contains("lemon cake"))
            #expect(!text.contains(DigestWords.heading))
        }
    }

    /// Forgetting only a note the digest quoted takes the digest's words
    /// off the card too, though the digest note itself stays in the notes.
    @Test func forgettingOneQuotedNoteTakesTheWordsOffTheCard() throws {
        let (engine, id, kept) = try keepDigest()
        let heard = Heard()
        let watch = engine.observe { heard.add($0) }
        let cake = try #require(notes.notes().first { $0.text.contains("lemon cake") && $0.id != kept.id })
        #expect(try notes.forget(cake.id))
        engine.refresh()
        let card = try #require(engine.tasks.first { $0.id == id })
        #expect(card.result == nil)
        #expect(card.step == DigestWords.done)
        // Observers hear it, so an open card follows.
        #expect(heard.all.count == 2)
        #expect(heard.all.last?.tasks.first { $0.id == id }?.result == nil)
        watch.cancel()
        let again = try self.engine()
        #expect(again.tasks.first { $0.id == id }?.result == nil)
    }

    /// A file left unreadable at launch, as on a locked device, is read on
    /// refresh, and its tasks join those started meanwhile, which keep
    /// going and keep their question.
    @Test(.enabled(if: getuid() != 0, "root can read a locked file"))
    func aLateFirstReadKeepsTasksStartedMeanwhile() throws {
        let (_, keptID, _) = try keepDigest()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tasksFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tasksFile.path) }
        let locked = try engine()
        #expect(locked.tasks.isEmpty)
        let (task, question) = try runToQuestion(locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tasksFile.path)
        locked.refresh()
        let ids = locked.tasks.map(\.id)
        #expect(ids == [task.id, keptID])
        #expect(locked.tasks.first?.state == .waitingOnYou)
        #expect(locked.tasks.first?.question == question)
        #expect(!rule.isClosed(question))
        // Both are written once the file has been read.
        #expect(try self.engine().tasks.map(\.id) == ids)
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
        #expect(back.progress != .fraction(1))
    }

    /// Only a task that was done comes back looking complete. One that
    /// stopped or failed never shows a full bar.
    @Test func onlyADoneTaskComesBackFull() throws {
        let json = ["done", "stopped", "failed"].map { state in
            """
            {"id":"device-task:\(state)","title":"\(DigestTask.title)","step":"x","state":"\(state)",
             "history":[],"startedAt":0,"updatedAt":0,"saving":false}
            """
        }.joined(separator: ",")
        try Data("[\(json)]".utf8).write(to: tasksFile)
        let back = Dictionary(uniqueKeysWithValues: try engine().tasks.map { ($0.state, $0.progress) })
        #expect(back[.done] == .fraction(1))
        #expect(back[.stopped] == .indeterminate)
        #expect(back[.failed] == .indeterminate)
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
        // The person's own note with the same first words is theirs, not a digest.
        let typed = MemoryNote(text: DigestWords.heading + " I mostly rested", savedAt: now - 30, source: .toldMe)
        #expect(DigestTask.thisWeek(week + [typed], now: now).last == typed)
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
