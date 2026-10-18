import Foundation
import PebbleCore
import PebbleModel
import SourceScan
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
        let second = try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, rule: rule, pace: nil))
        #expect(first.place == LocalStubModel().privacyPlace)
        #expect(second.place == LocalStubModel().privacyPlace)
        #expect(first.place.staysOnDevice)
    }

    /// A spot check only: the engine's own files, and the task they run,
    /// name no way to reach the network. Its module also holds the cloud
    /// model, so this can't prove more than these files.
    @Test func theEngineFilesNameNoNetworking() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // "Module.Type" gives each file's folder and name, so no path is
        // spelled out here.
        let files = [String(reflecting: DeviceTaskEngine.self), String(reflecting: OnDeviceTasks.self),
                     String(reflecting: DigestTask.self)].map { name in
            let parts = name.split(separator: ".")
            return sources.appendingPathComponent(String(parts[0])).appendingPathComponent(parts[1] + ".swift")
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["URLSession", "URLRequest", "http", "import Network", "FoundationNetworking", "NWConnection",
                         "CFStream", "Socket"] {
                #expect(!text.contains(word), "\(word) in \(file.lastPathComponent)")
            }
        }
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
        let (_, question) = try runToQuestion(engine)
        #expect(question.action.details.contains("(You told me)"))
        let text = try String(contentsOf: tasksFile, encoding: .utf8)
        for words in Self.draftWords { #expect(!text.contains(words), "\(words) in the file") }
    }

    /// Words of the notes and of a digest written from them.
    static let draftWords = ["Dentist", "Thursday", "lemon cake", "Sam's birthday", "May 14", DigestWords.heading,
                             MemorySource.toldMe.label, MemorySource.fromApp("Calendar").label, "• "]

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
        // The probe reaches where forgotten words would be: the words the
        // engine holds of the digest, which only it read, are found, and
        // the forgotten note's are not.
        let held = StoredWords(in: engine)
        #expect(held.contains("Sam's birthday is May 14. Loves lemon cake. (You told me)"))
        #expect(!held.contains("Dentist"))
        #expect(try notes.forget(kept.id))
        engine.refresh()
        let card = try #require(engine.tasks.first { $0.id == id })
        #expect(card.result == nil)
        #expect(card.step == DigestWords.removed)

        let again = try self.engine()
        let back = try #require(again.tasks.first { $0.id == id })
        #expect(back.result == nil)
        #expect(back.step == DigestWords.removed)
        // The file, the card, and everything either engine holds in memory.
        let after = try String(contentsOf: tasksFile, encoding: .utf8)
        for (place, held) in [("file", StoredWords(in: after)), ("card", StoredWords(in: back)),
                              ("engine", StoredWords(in: engine)), ("engine after relaunch", StoredWords(in: again))] {
            #expect(held.texts.contains { !$0.isEmpty }, "\(place): nothing read")
            for words in ["Dentist", "Thursday", "lemon cake", "Sam's birthday", DigestWords.heading] {
                #expect(!held.contains(words), "\(words) in the \(place)")
            }
        }
        // Nor the ids of the notes that went.
        for gone in [dentist.id, kept.id] { #expect(!after.contains(gone.uuidString), "\(gone) in the file") }
        // The probe does reach what the engine holds.
        #expect(StoredWords(in: engine).contains(DigestTask.title))
    }

    /// The last thing observers were told about a task.
    func lastHeard(_ heard: Heard, _ id: String) -> AgentTask? {
        heard.all.last?.tasks.first { $0.id == id }
    }

    /// A note the digest quoted, forgotten by any writer, through the store
    /// alone, leaves no word of it in any note: its line goes from the
    /// kept digest, the card shows the rest, and observers hear it. It
    /// stays gone after a relaunch.
    @Test func forgettingAQuotedNoteAnywhereTakesItsLineOut() throws {
        let (engine, id, kept) = try keepDigest()
        let heard = Heard()
        let watch = engine.observe { heard.add($0) }
        let cake = try #require(notes.notes().first { $0.text.contains("lemon cake") && $0.id != kept.id })
        #expect(try notes.forget(cake.id))
        let rest = DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)"
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
        #expect(notes.notes().first { $0.id == kept.id }?.text == rest)
        #expect(engine.tasks.first { $0.id == id }?.result == rest)
        #expect(lastHeard(heard, id)?.result == rest)
        watch.cancel()
        let again = try self.engine()
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
        #expect(again.tasks.first { $0.id == id }?.result == rest)
    }

    /// The app closing between forgetting a note and taking its line out,
    /// with no engine to hear it, leaves the line only until the next
    /// launch, which takes it out.
    @Test func aLineLeftWhenTheAppClosedGoesAtLaunch() throws {
        let id: String, kept: MemoryNote
        do {
            let (engine, keptID, note) = try keepDigest()
            id = keptID
            kept = note
            #expect(engine.tasks.first?.result == kept.text)
        }
        // The engine is gone, so nothing hears this.
        let cake = try #require(notes.notes().first { $0.text.contains("lemon cake") && $0.id != kept.id })
        #expect(try notes.forget(cake.id))
        #expect(notes.notes().contains { $0.text.contains("lemon cake") })
        let again = try self.engine()
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
        #expect(again.tasks.first { $0.id == id }?.result == DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)")
    }

    /// Changing a quoted note takes its earlier words out of the digest
    /// too, whoever changes it, as the notes promise the old words don't
    /// stay. The new words are never added: the yes wasn't for them.
    @Test func changingAQuotedNoteTakesItsEarlierWordsOut() throws {
        let (engine, id, kept) = try keepDigest()
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        _ = try notes.edit(sam.id, to: "Sam's birthday is May 15")
        let rest = DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)"
        #expect(notes.notes().first { $0.id == kept.id }?.text == rest)
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
        #expect(engine.forgetQuotes(of: sam) == .forgotten)
        #expect(engine.tasks.first { $0.id == id }?.result == rest)
    }

    // MARK: Forgetting a note the digest quoted

    /// Forgetting a note takes its line out of the digest note itself, so
    /// its words are nowhere in the notes. The rest of the digest stays and
    /// shows again, and once its last line goes the digest goes too, even
    /// after a relaunch.
    @Test func forgettingAQuotedNoteTakesItsLineOutOfTheDigestNote() throws {
        let id: String = try {
            let (engine, id, kept) = try keepDigest()
            let cake = try #require(notes.notes().first { $0.text.contains("lemon cake") && $0.id != kept.id })
            #expect(try notes.forget(cake.id))
            #expect(engine.forgetQuotes(of: cake) == .forgotten)
            #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
            let digest = try #require(notes.notes().first { $0.id == kept.id })
            #expect(digest.text == DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)")
            #expect(engine.tasks.first { $0.id == id }?.result == digest.text)
            #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.done)
            return id
        }()

        // Which line is whose comes back after a relaunch too, with only
        // the new engine to take it out.
        let again = try self.engine()
        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        #expect(try notes.forget(dentist.id))
        #expect(again.forgetQuotes(of: dentist) == .forgotten)
        #expect(!notes.notes().contains { $0.text.contains("Dentist") || $0.text.hasPrefix(DigestWords.heading) })
        // The card says it was taken out here, never that the person did.
        #expect(again.tasks.first { $0.id == id }?.step == DigestWords.tookOut)
        #expect(again.tasks.first { $0.id == id }?.result == nil)
        #expect(try self.engine().tasks.first { $0.id == id }?.step == DigestWords.tookOut)
    }

    /// Changing the last note a digest quoted takes the digest out too,
    /// and the card says so truly. One the person removes says they did.
    @Test func aDigestTakenOutHereSaysSoAndOneThePersonRemovedSaysThat() throws {
        let (engine, id, kept) = try keepDigest()
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        _ = try notes.edit(dentist.id, to: "Dentist on Friday at 4")
        #expect(!notes.notes().contains { $0.id == kept.id })
        #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.tookOut)
        #expect(engine.tasks.first { $0.id == id }?.state == .done)

        let (next, second, again) = try keepDigest()
        _ = try notes.forget(again.id)
        #expect(next.tasks.first { $0.id == second }?.step == DigestWords.removed)
    }

    /// A note nothing quoted is left alone, and so is every digest.
    @Test func aNoteNoDigestQuotedChangesNothing() throws {
        let (engine, _, kept) = try keepDigest()
        let old = try #require(notes.notes().first { $0.text.hasPrefix("Old note") })
        #expect(try notes.forget(old.id))
        #expect(engine.forgetQuotes(of: old) == .notQuoted)
        #expect(notes.notes().first { $0.id == kept.id } == kept)
    }

    /// A digest the person changed is theirs. While it still holds the
    /// forgotten note's words it is left as they made it, the engine says
    /// so, and the card says why it shows nothing.
    @Test func aDigestChangedByHandIsNeverCalledClean() throws {
        let (engine, id, kept) = try keepDigest()
        let mine = "My week: Sam's birthday is May 14. Loves lemon cake. Also the dentist."
        _ = try notes.edit(kept.id, to: mine)
        let cake = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(cake.id))
        #expect(engine.forgetQuotes(of: cake) == .stayed)
        #expect(notes.notes().first { $0.id == kept.id }?.text == mine)
        #expect(engine.tasks.first { $0.id == id }?.result == nil)
        #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.hiddenQuote)
    }

    /// A digest the person changed that keeps only part of a note, in its
    /// own words or in the digest's shape, is never guessed at: it is left
    /// as they made it and said to still hold the note, then and after a
    /// relaunch.
    @Test(arguments: [
        DigestWords.heading + ".\n• Sam's birthday is May 14 (You told me)\n• Dentist on Thursday at 3 (From Calendar)",
        "My week: Sam's birthday is May 14. Also the dentist.",
    ])
    func aDigestKeepingPartOfANoteStillHoldsIt(_ mine: String) throws {
        let (engine, id, kept) = try keepDigest()
        _ = try notes.edit(kept.id, to: mine)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .stayed)
        #expect(notes.notes().first { $0.id == kept.id }?.text == mine)
        #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.hiddenQuote)
        // The forgotten note's id leaves the file; the card still hides.
        let file = try String(contentsOf: tasksFile, encoding: .utf8)
        #expect(!file.contains(sam.id.uuidString))
        // Another note out of the same digest: still theirs, still said
        // so. Where only "the dentist" is left of it, the words may be
        // there, reworded, though they weren't found.
        let again = try self.engine()
        #expect(again.tasks.first { $0.id == id }?.step == DigestWords.hiddenQuote)
        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        #expect(try notes.forget(dentist.id))
        #expect(again.forgetQuotes(of: dentist) == (mine.contains("Dentist on Thursday") ? .stayed : .mayHaveStayed))
        #expect(notes.notes().first { $0.id == kept.id }?.text == mine)
    }

    /// A digest the person changed that no longer holds a forgotten note's
    /// words is never said to still hold them: it may, reworded, so the
    /// line says so.
    @Test func aLineThePersonAlreadyTookOutIsNeverSaidToStay() throws {
        let (engine, _, kept) = try keepDigest()
        let mine = DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)"
        _ = try notes.edit(kept.id, to: mine)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .mayHaveStayed)
        #expect(notes.notes().first { $0.id == kept.id }?.text == mine)
    }

    // MARK: A digest not yet kept

    /// A note forgotten or changed while the digest drawn from it waits for
    /// a yes: the question is withdrawn, the task stops and says why, and
    /// a yes given for the earlier words keeps nothing.
    @Test(arguments: [false, true])
    func aNoteChangingUnderAQuestionStopsIt(changed: Bool) throws {
        let engine = try engine()
        let (task, question) = try runToQuestion(engine)
        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        if changed { _ = try notes.edit(dentist.id, to: "Dentist on Friday at 4") } else { _ = try notes.forget(dentist.id) }
        let before = notes.notes()
        let stopped = try #require(engine.tasks.first { $0.id == task.id })
        #expect(stopped.state == .stopped)
        #expect(stopped.step == DigestWords.noteChanged)
        #expect(stopped.question == nil)
        #expect(stopped.wrapUp?.notDone == [DigestTask.saveTodo])
        #expect(rule.isClosed(question))
        #expect(rule.wasWithdrawn(question))
        // The yes for the earlier words does nothing. `approve()` mints a
        // yes the rule never saw, which only the sheet may do in the app;
        // here it stands for the worst case, a yes that reaches the engine
        // anyway, and the engine refuses it since the task moved on.
        #expect(rule.sayYes(to: question) == .timedOut)
        #expect(engine.resume(task.id, with: question.approve()) == .refused)
        #expect(notes.notes() == before)
        #expect(!notes.notes().contains { DigestTask.isDigest($0) })
    }

    /// The same while the notes are being read and the digest written.
    @Test(arguments: [1, 2])
    func aNoteGoingWhileTheDigestIsWrittenStopsIt(steps: Int) throws {
        let engine = try engine()
        let id = engine.start(DigestTask.request)
        for _ in 0..<steps { engine.runPending() }
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        _ = try notes.forget(sam.id)
        for _ in 0..<3 { engine.runPending() }
        let stopped = try #require(engine.tasks.first { $0.id == id })
        #expect(stopped.state == .stopped)
        #expect(stopped.step == DigestWords.noteChanged)
        #expect(stopped.question == nil)
        #expect(!notes.notes().contains { DigestTask.isDigest($0) })
    }

    /// A note nobody's digest drew from changes nothing under a question.
    @Test func anOldNoteChangingLeavesTheQuestionOpen() throws {
        let engine = try engine()
        let (task, question) = try runToQuestion(engine)
        let old = try #require(notes.notes().first { $0.text.hasPrefix("Old note") })
        _ = try notes.forget(old.id)
        #expect(engine.tasks.first { $0.id == task.id }?.state == .waitingOnYou)
        #expect(!rule.isClosed(question))
    }

    // MARK: A digest no task points to

    /// How a kept digest's task leaves the engine.
    enum LetGo: Sendable {
        case dismiss, ageOut
        /// Put away, then a new engine.
        case dismissThenRelaunch
        /// A new engine, after `prepare` does something to the task file.
        case relaunch(@Sendable () throws -> Void)
    }

    /// Lets a kept digest's task go and returns the engine left, the
    /// task's id and the digest note.
    func letGo(_ how: LetGo) throws -> (DeviceTaskEngine, String, MemoryNote) {
        var engine: DeviceTaskEngine?
        let (id, kept): (String, MemoryNote) = try {
            let (made, id, kept) = try keepDigest()
            engine = made
            return (id, kept)
        }()
        switch how {
        case .dismiss:
            #expect(engine?.dismiss(id) == true)
        case .ageOut:
            for _ in 0..<DeviceTaskEngine.endedLimit { engine?.start(TaskRequest(title: "Book a table")) }
        case .dismissThenRelaunch:
            #expect(engine?.dismiss(id) == true)
            engine = nil
            engine = try self.engine()
        case .relaunch(let prepare):
            // The engine that kept it is gone, so it can't clean up.
            engine = nil
            try prepare()
            engine = try self.engine()
        }
        let left = try #require(engine)
        #expect(!left.tasks.contains { $0.id == id })
        return (left, id, kept)
    }

    /// A digest whose card was put away, or let go as the oldest, still
    /// loses a forgotten note's line, then and after a relaunch: its ids
    /// outlive the card. The file holds no word of it, and its last line
    /// going takes the digest and those ids with it.
    @Test(arguments: [LetGo.dismiss, .ageOut, .dismissThenRelaunch])
    func aDigestWhoseCardWentStillLosesAForgottenNotesLine(_ how: LetGo) throws {
        let (left, _, kept) = try letGo(how)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(left.forgetQuotes(of: sam) == .forgotten)
        let rest = DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)"
        #expect(notes.notes().first { $0.id == kept.id }?.text == rest)
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
        let file = try String(contentsOf: tasksFile, encoding: .utf8)
        for words in Self.draftWords { #expect(!file.contains(words), "\(words) in the file") }
        #expect(file.contains(kept.id.uuidString))
        #expect(!file.contains(sam.id.uuidString))

        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        #expect(try notes.forget(dentist.id))
        #expect(left.forgetQuotes(of: dentist) == .forgotten)
        #expect(!notes.notes().contains { $0.id == kept.id || $0.text.contains("Dentist") })
        let after = (try? String(contentsOf: tasksFile, encoding: .utf8)) ?? ""
        for id in [kept.id, sam.id, dentist.id] { #expect(!after.contains(id.uuidString)) }
    }

    /// The same for a note changed rather than forgotten: its earlier
    /// words go from a digest whose card was put away.
    @Test func aChangedNoteLeavesADigestWhoseCardWasPutAway() throws {
        let (left, _, kept) = try letGo(.dismiss)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        _ = try notes.edit(sam.id, to: "Sam's birthday is May 15")
        #expect(left.forgetQuotes(of: sam) == .forgotten)
        #expect(notes.notes().first { $0.id == kept.id }?.text == DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)")
    }

    /// Keeps a digest, lets its task go with a task file that can't be
    /// read, and forgets a note it quoted on the memory screen's path.
    /// Which line is whose isn't known then, so the words are only looked
    /// for, and found, and never called gone.
    func forgetAfterLettingGo(_ how: LetGo) throws {
        let (left, _, kept) = try letGo(how)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(left.forgetQuotes(of: sam) == .stayed)
        #expect(notes.notes().first { $0.id == kept.id } == kept)
    }

    /// A digest whose first line the person changed, then put away, is
    /// theirs: a forgotten note's words found in it are said to stay, and
    /// nothing is taken out.
    @Test func aDigestWithItsHeadingChangedThenPutAwayIsNeverCalledClean() throws {
        let (left, _, kept) = try letGo(.dismiss)
        let mine = kept.text.replacingOccurrences(of: DigestWords.heading, with: "My week")
        _ = try notes.edit(kept.id, to: mine)
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(left.forgetQuotes(of: sam) == .stayed)
        #expect(notes.notes().first { $0.id == kept.id }?.text == mine)
    }

    /// A note the agent kept that no task knows of, such as a digest kept
    /// before its card was written down, is looked in whatever its first
    /// line says.
    @Test func aDigestNoTaskKnowsOfIsLookedInWhateverItsHeading() throws {
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        try notes.remember("My week\n" + DigestTask.line(for: sam), at: clock.now(), source: .inferred)
        let engine = try engine()
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .stayed)
        // One that never quoted it changes nothing.
        let old = try #require(notes.notes().first { $0.text.hasPrefix("Old note") })
        #expect(try notes.forget(old.id))
        #expect(engine.forgetQuotes(of: old) == .notQuoted)
    }

    @Test(.enabled(if: getuid() != 0, "root can read a locked file"))
    func aDigestFromATaskFileLeftUnreadIsNeverCalledClean() throws {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tasksFile.path) }
        let file = tasksFile
        try forgetAfterLettingGo(.relaunch {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        })
    }

    @Test func aDigestFromATaskFileThatCantBeReadIsNeverCalledClean() throws {
        let file = tasksFile
        try forgetAfterLettingGo(.relaunch { try Data("not tasks".utf8).write(to: file) })
    }

    /// A digest a task file that couldn't be read may have known of, and
    /// that the person changed past finding, is still not called clean:
    /// the words may be there, though they weren't found. Forgetting every
    /// task keeps that caution while the notes stay, as when they couldn't
    /// be erased, and only notes with nothing the agent kept end it.
    @Test func aChangedDigestFromALostTaskFileIsNeverCalledClean() throws {
        let (_, _, kept) = try keepDigest()
        _ = try notes.edit(kept.id, to: "My week was busy.")
        try Data("not tasks".utf8).write(to: tasksFile)
        let engine = try engine()
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .mayHaveStayed)
        // Every task forgotten, and the notes not.
        engine.clear()
        let dentist = try #require(notes.notes().first { $0.text.hasPrefix("Dentist") })
        #expect(try notes.forget(dentist.id))
        #expect(engine.forgetQuotes(of: dentist) == .mayHaveStayed)
        // Then the notes too: nothing is left to fear.
        try notes.forgetEverything()
        try notes.remember("Call the plumber", source: .toldMe)
        let plumber = try #require(notes.notes().first)
        #expect(try notes.forget(plumber.id))
        #expect(engine.forgetQuotes(of: plumber) == .notQuoted)
    }

    /// Forgetting every task while a kept digest stays in the notes keeps
    /// its words from being called gone: no task knows its lines then.
    @Test func forgettingEveryTaskButNotTheNotesKeepsTheDigestLookedIn() throws {
        let (engine, _, kept) = try keepDigest()
        engine.clear()
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .stayed)
        #expect(notes.notes().first { $0.id == kept.id } == kept)
    }

    /// Notes that can't be read when a note's earlier words are named: it
    /// says they stay, and takes them out at the next look that can read.
    @Test(.enabled(if: getuid() != 0, "root can read a locked file"))
    func earlierWordsNamedWhileTheNotesAreLockedGoOnceTheyOpen() throws {
        let kept = try keepDigest().2
        // Changed by a writer no engine hears, and the notes locked before
        // the engine first looks, so it never saw the earlier words.
        let sam = try #require(notes.notes().first { $0.text.hasPrefix("Sam's") })
        _ = try MemoryStore(fileURL: notes.fileURL).edit(sam.id, to: "Sam's birthday is in May")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notes.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notes.fileURL.path) }
        let engine = try engine()
        #expect(engine.forgetQuotes(of: sam) == .stayed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notes.fileURL.path)
        engine.refresh()
        #expect(notes.notes().first { $0.id == kept.id }?.text == DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)")
        #expect(!notes.notes().contains { $0.text.contains("lemon cake") })
    }

    /// Notes changed by any writer, not just the memory screen, reach the
    /// card at once, with no refresh.
    @Test func theCardFollowsTheStoresOwnChanges() throws {
        let (engine, id, kept) = try keepDigest()
        let heard = Heard()
        let watch = engine.observe { heard.add($0) }
        let changed = DigestWords.heading + ".\n• Dentist moved to Friday (You told me)"
        _ = try notes.edit(kept.id, to: changed)
        #expect(engine.tasks.first { $0.id == id }?.result == changed)
        #expect(heard.all.last?.tasks.first { $0.id == id }?.result == changed)
        _ = try notes.forget(kept.id)
        #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.removed)
        #expect(heard.all.last?.tasks.first { $0.id == id }?.result == nil)
        watch.cancel()
    }

    /// The notes are read once for the cards, not on every look. What was
    /// read stays until the notes change or `refresh()` asks again.
    @Test(.enabled(if: getuid() != 0, "root can read a locked file"))
    func theNotesAreReadOnceUntilTheyChange() throws {
        let (engine, id, kept) = try keepDigest()
        #expect(engine.tasks.first { $0.id == id }?.result == kept.text)
        let file = notes.fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(notes.contents() == .unavailable)
        #expect(engine.tasks.first { $0.id == id }?.result == kept.text)
        engine.refresh()
        #expect(engine.tasks.first { $0.id == id }?.result == nil)
        #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.notesLocked)
    }

    // MARK: Running twice

    /// Run twice in one week with nothing new, the digest is the same, so
    /// the second yes points at the one already kept, not a failure.
    @Test func aSecondDigestTheSameAsTheFirstIsAlreadyKept() throws {
        let (engine, first, kept) = try keepDigest()
        let (task, question) = try runToQuestion(engine)
        #expect(question.action.details == kept.text)
        guard case .approved(let approval) = rule.sayYes(to: question) else { Issue.record("no approval"); return }
        #expect(engine.resume(task.id, with: approval) == .proceeding)
        #expect(notes.notes().filter { $0.text == kept.text }.count == 1)
        let second = try #require(engine.tasks.first { $0.id == task.id })
        #expect(second.state == .done)
        #expect(second.step == DigestWords.alreadyKept)
        #expect(second.result == kept.text)
        #expect(second.wrapUp == nil)
        // Both cards point at the one note, so forgetting it clears both.
        _ = try notes.forget(kept.id)
        for id in [first, task.id] { #expect(engine.tasks.first { $0.id == id }?.step == DigestWords.removed) }
    }

    // MARK: Lines in the digest

    /// Taking a note out keeps the digest within a note's length and its
    /// count of the rest right, and a digest with no line left goes.
    /// Takes `gone` out of `written`, each line known from `week`.
    func drop(_ gone: [MemoryNote], from written: DigestTask.Written, week: [MemoryNote]) -> DigestTask.Dropped {
        DigestTask.dropping(Set(gone.map(\.id)), from: written.text, as: written,
                            lines: Dictionary(uniqueKeysWithValues: week.map { ($0.id, DigestTask.line(for: $0)) }))
    }

    /// A full week: more notes than fit, so some are only counted.
    var fullWeek: [MemoryNote] {
        let now = clock.now()
        return (0..<40).map { MemoryNote(text: "Note number \($0) " + String(repeating: "word ", count: 30),
                                         savedAt: now - Double($0) * 3_600, source: .toldMe) }
    }

    @Test func droppingANoteKeepsTheCountRight() throws {
        let now = clock.now()
        let week = fullWeek
        let written = DigestTask.write(week, now: now)
        #expect(written.text == DigestTask.digest(of: week, now: now))
        #expect(written.quoted.count + written.more.count == 40)
        #expect(written.text.hasSuffix(DigestWords.andMore(written.more.count)))

        // One counted in the last line: the count goes down by one.
        let counted = try #require(week.first { $0.id == written.more.first })
        guard case .edited(let fewer) = drop([counted], from: written, week: week) else {
            Issue.record("not edited"); return
        }
        #expect(fewer.text.hasSuffix(DigestWords.andMore(written.more.count - 1)))
        #expect(fewer.text.count <= written.text.count)
        #expect(fewer.quoted == written.quoted)

        // One with a line, from the middle: that line goes and the count stays.
        let shown = try #require(week.first { $0.id == written.quoted[1] })
        #expect(fewer.text.contains(DigestTask.line(for: shown)))
        guard case .edited(let shorter) = drop([shown], from: fewer, week: week) else {
            Issue.record("not edited"); return
        }
        #expect(!shorter.text.contains(DigestTask.line(for: shown)))
        #expect(!shorter.text.contains(String(shown.text.prefix(20))))
        #expect(shorter.text.components(separatedBy: "\n").count == fewer.text.components(separatedBy: "\n").count - 1)
        #expect(shorter.text.hasSuffix(DigestWords.andMore(fewer.more.count)))
        #expect(shorter.text.count <= MemoryStore.maxLength)

        // Every line gone: nothing is left to keep.
        var left = shorter
        for id in shorter.quoted.dropLast() {
            let note = try #require(week.first { $0.id == id })
            guard case .edited(let next) = drop([note], from: left, week: week) else {
                Issue.record("not edited"); return
            }
            left = next
        }
        let last = try #require(week.first { $0.id == left.quoted.first })
        #expect(drop([last], from: left, week: week) == .emptied)
    }

    /// The last counted note going takes the count's line with it, never
    /// leaving "And 0 more notes."
    @Test func theLastCountedNoteTakesItsLineWithIt() throws {
        let week = fullWeek
        let written = DigestTask.write(week, now: clock.now())
        let counted = written.more.compactMap { id in week.first { $0.id == id } }
        guard case .edited(let one) = drop(Array(counted.dropFirst()), from: written, week: week) else {
            Issue.record("not edited"); return
        }
        #expect(one.more.count == 1)
        #expect(one.text.hasSuffix(DigestWords.andMore(1)))
        guard case .edited(let none) = drop([counted[0]], from: one, week: week) else {
            Issue.record("not edited"); return
        }
        #expect(none.more.isEmpty)
        #expect(!none.text.contains("And 0"))
        #expect(!none.text.contains("more note"))
        #expect(none.text.components(separatedBy: "\n").last?.hasPrefix("• ") == true)
    }

    /// A line is taken out only once it is checked to be its note's, and
    /// every other line too. Words moved between lines, a line changed
    /// inside, or a line not known for a note that stays, leave the
    /// digest alone.
    @Test func aLineGoesOnlyOnceItIsCheckedToBeItsNotes() throws {
        let now = clock.now()
        let week = DigestTask.thisWeek(notes.notes(), now: now)
        let written = DigestTask.write(week, now: now)
        let (sam, dentist) = (week[0], week[1])
        var lines = written.text.components(separatedBy: "\n")
        #expect(lines[1] == DigestTask.line(for: sam))

        // Moved: the dentist's words in Sam's line and Sam's in the dentist's.
        lines.swapAt(1, 2)
        let moved = DigestTask.Written(text: lines.joined(separator: "\n"), quoted: written.quoted, more: written.more)
        #expect(drop([sam], from: moved, week: week) == .cantTell)
        // Changed inside the line of the note that stays.
        let changed = DigestTask.Written(text: written.text.replacingOccurrences(of: "Thursday", with: "Friday"),
                                         quoted: written.quoted, more: written.more)
        #expect(drop([sam], from: changed, week: week) == .cantTell)
        // A note gone before its words were read: known by where it sits,
        // once the rest check out.
        #expect(DigestTask.dropping([sam.id], from: written.text, as: written,
                                    lines: [dentist.id: DigestTask.line(for: dentist)])
                == .edited(DigestTask.Written(text: DigestWords.heading + ".\n" + DigestTask.line(for: dentist),
                                              quoted: [dentist.id], more: [])))
        // But never for a note that stays.
        #expect(DigestTask.dropping([sam.id], from: written.text, as: written,
                                    lines: [sam.id: DigestTask.line(for: sam)]) == .cantTell)
        // Nor for a line in that place the person added their own words
        // to, past where a line ends or longer than one is written.
        let samLine = DigestTask.line(for: sam)
        for theirs in [samLine + " Get candles", "• My own words, nothing from a note",
                       "• " + String(repeating: "a", count: DigestTask.lineLimit + 1) + " (You told me)",
                       samLine.replacingOccurrences(of: "(You told me)", with: "(Sam told me)")] {
            var lines = written.text.components(separatedBy: "\n")
            lines[1] = theirs
            let mixed = DigestTask.Written(text: lines.joined(separator: "\n"), quoted: written.quoted, more: written.more)
            #expect(DigestTask.dropping([sam.id], from: mixed.text, as: mixed,
                                        lines: [dentist.id: DigestTask.line(for: dentist)]) == .cantTell, "\(theirs)")
        }
        // Every line a note can have fits the shape, cut short or not.
        let long = MemoryNote(text: String(repeating: "word ", count: 40), source: .fromApp(String(repeating: "A", count: 40)))
        for note in week + [long, MemoryNote(text: "x", source: .inferred), MemoryNote(text: "y", source: .fromApp(" "))] {
            #expect(DigestTask.couldBeLine(DigestTask.line(for: note)), "\(DigestTask.line(for: note))")
        }
    }

    /// A kept digest is exactly the words written, byte for byte, so a
    /// line taken out right after keeping it checks out and is never
    /// mistaken for the person's change.
    @Test func aKeptDigestIsExactlyWhatWasWritten() throws {
        let (engine, id, kept) = try keepDigest()
        let week = DigestTask.thisWeek(notes.notes().filter { $0.id != kept.id }, now: clock.now())
        let written = DigestTask.write(week, now: clock.now())
        #expect(Array(kept.text.utf8) == Array(written.text.utf8))
        let sam = try #require(week.first { $0.text.hasPrefix("Sam's") })
        guard case .edited = drop([sam], from: DigestTask.Written(text: kept.text, quoted: written.quoted,
                                                                  more: written.more), week: week) else {
            Issue.record("not edited"); return
        }
        #expect(try notes.forget(sam.id))
        #expect(engine.forgetQuotes(of: sam) == .forgotten)
        #expect(engine.tasks.first { $0.id == id }?.result == DigestWords.heading + ".\n• Dentist on Thursday at 3 (From Calendar)")
    }

    /// Looking for a note in a digest whose lines aren't known leans to
    /// finding it: case, spacing and a small change don't hide it.
    @Test func aNoteIsFoundInADigestChangedALittle() throws {
        let sam = MemoryNote(text: "Sam's birthday is May 14. Loves lemon cake.", source: .toldMe)
        for text in [DigestWords.heading + ".\n• SAM'S BIRTHDAY  is May 14. Loves lemon cake. (You told me)",
                     DigestWords.heading + ".\n• Sam's birthday is May 14. Loves lemon cak (You told me)",
                     "My week. sam's birthday is may 14, loves cake",
                     "• Sam's birthday is May 14 and more"] {
            #expect(DigestTask.mayQuote(sam, in: text), "not found in: \(text)")
        }
        #expect(!DigestTask.mayQuote(sam, in: DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)"))
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
        let (task, question) = try runToQuestion(engine)
        #expect(!rule.isClosed(question))
        let again = try self.engine()
        // The question the engine before asked can't be said yes to now,
        // through either engine.
        #expect(rule.isClosed(question))
        #expect(rule.wasWithdrawn(question))
        #expect(rule.sayYes(to: question) == .timedOut)
        #expect(engine.resume(task.id, with: question.approve()) == .refused)
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
