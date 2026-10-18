#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// The real task engine on Today and in Forget everything, as the app
/// wires it: the offer starts the digest, its question opens the same
/// sheet as any other, and Forget everything erases its tasks and file.
@MainActor
struct DigestTodayTests {
    let folder: URL
    let notes: MemoryStore
    let rule = AskFirst.isolated()
    let engine: DeviceTaskEngine
    let feed: FeedModel

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("digest-today-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        try notes.remember("Dentist on Thursday at 3", at: Date() - 3_600, source: .toldMe)
        engine = try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, rule: rule, pace: nil))
        feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice)
    }

    var tasksFile: URL { folder.appendingPathComponent("tasks.json") }

    /// Starts the digest from Today's offer and runs it to its question.
    func startAndAsk() throws -> AgentTask {
        #expect(feed.offers == [DigestTask.request])
        feed.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        feed.refresh()
        return try #require(feed.feed.needsYou.compactMap(\.task).first)
    }

    @Test func todayOffersTheDigestAndShowsItsCard() throws {
        let task = try startAndAsk()
        #expect(task.title == DigestTask.title)
        #expect(feed.canApprove(task))
        // Not offered again while it is going, and not an example.
        #expect(feed.offers.isEmpty)
        #expect(!feed.isSample)
        #expect(!feed.isSample(FeedItem(id: task.id, kind: .task, time: Date(), title: "", body: "")))
    }

    @Test func approveOpensTheRealSheetAndOnlyItsYesSaves() throws {
        let before = notes.notes()
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        #expect(!feed.isSample(request))
        #expect(notes.notes() == before)
        // The yes goes through the sheet's own state, as a tap would.
        let sheet = ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) }, onDecline: {})
        sheet.tapPrimary()
        #expect(notes.notes().count == before.count + 1)
        #expect(engine.tasks.first?.state == .done)
        #expect(feed.offers == [DigestTask.request])
    }

    @Test func notNowInTheSheetSavesNothing() throws {
        let before = notes.notes()
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        let sheet = ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) },
                                      onDecline: { feed.closedQuestion(request) })
        sheet.cancel()
        #expect(notes.notes() == before)
        #expect(engine.tasks.first?.step == TaskWords.declined(DigestTask.saveTodo))
    }

    @Test func stopFromTheCardStopsTheTask() throws {
        feed.start(DigestTask.request)
        let task = try #require(engine.tasks.first)
        feed.stop(task)
        for _ in 0..<3 { engine.runPending() }
        #expect(engine.tasks.first?.state == .stopped)
        #expect(engine.tasks.first?.question == nil)
    }

    /// Forget everything: the tasks and their file go, the notes go, and
    /// the line says so. Each part goes whatever happens to the others.
    @Test func forgetEverythingErasesTheTasksAndTheirFile() throws {
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        let memory = MemoryModel(store: notes, place: .onDevice, onForgetEverything: { feed.forgetTasks() },
                                 othersStored: { feed.tasksStored })
        memory.forgetEverything()
        #expect(engine.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tasksFile.path))
        #expect(!notes.hasStoredFile)
        #expect(feed.reviewing == nil)
        #expect(rule.isClosed(request))
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!memory.hasStoredFile)
    }

    /// With the notes gone one by one, the tasks' file still holds a card,
    /// so Forget everything stays on offer until it is erased.
    @Test func forgetEverythingStaysWhileOnlyTheTaskFileIsLeft() throws {
        _ = try startAndAsk()
        for note in notes.notes() { _ = try notes.forget(note.id) }
        #expect(!notes.hasStoredFile)
        let memory = MemoryModel(store: notes, place: .onDevice, onForgetEverything: { feed.forgetTasks() },
                                 othersStored: { feed.tasksStored })
        #expect(memory.hasStoredFile)
        memory.forgetEverything()
        #expect(!memory.hasStoredFile)
    }

    /// Tasks whose file couldn't be erased are never said to be gone.
    @Test func theLineIsHonestWhenTheTaskFileStays() {
        let stayed = ClearedTasks(forgotten: 1, underway: 0, erased: false)
        let line = MemoryModel.forgotLineWithTasks
        #expect(line(true, nil, stayed) == TaskWords.forgotNotesNotTasks)
        #expect(line(false, nil, stayed) == MemoryWords.couldNotForget + " " + TaskWords.couldNotEraseTasks)
        let gone = ClearedTasks(forgotten: 1, underway: 0, erased: true)
        #expect(line(true, nil, gone) == MemoryWords.forgotten)
        #expect(line(false, nil, gone) == MemoryWords.couldNotForgetNotes)
    }

    @Test(.enabled(if: getuid() != 0, "root can remove files from a locked folder"))
    func aTaskFileThatStaysIsSaidSo() throws {
        _ = try startAndAsk()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let memory = MemoryModel(store: notes, place: .onDevice, onForgetEverything: { feed.forgetTasks() },
                                 othersStored: { feed.tasksStored })
        memory.forgetEverything()
        #expect(engine.tasks.isEmpty)
        #expect(!feed.tasksForgotten)
        #expect(memory.status?.contains(TaskWords.couldNotEraseTasks) == true)
        #expect(memory.hasStoredFile)
    }
}
#endif
