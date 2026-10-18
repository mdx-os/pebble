#if canImport(SwiftUI)
import Combine
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

    /// Start takes the offer, and VoiceOver's place, away, so the first
    /// step is said at once, even right after another line, and only once.
    @Test func startSaysTheFirstStepAtOnce() throws {
        var heard: [TaskAnnouncer.Line] = []
        feed.announce = { heard.append($0) }
        // Something was just said: a task asking, then stopping.
        let first = try startAndAsk()
        feed.stop(first)
        #expect(!heard.isEmpty)
        heard.removeAll()
        feed.start(DigestTask.request)
        let reading = TaskAnnouncer.Line(text: DigestTask.title + ". " + DigestWords.reading, urgent: true)
        #expect(heard == [reading])
        feed.refresh()
        #expect(heard == [reading])
    }

    /// The memory screen looks again as tasks change elsewhere, so Forget
    /// everything shows once a task's file is made, with no other nudge.
    @Test func theMemoryScreenFollowsTheTasks() throws {
        for note in notes.notes() { _ = try notes.forget(note.id) }
        let memory = MemoryModel(store: notes, place: .onDevice, othersStored: { feed.tasksStored },
                                 othersChanged: feed.$tasksSeen.map { _ in () }.eraseToAnyPublisher())
        #expect(!memory.hasStoredFile)
        feed.start(DigestTask.request)
        #expect(memory.hasStoredFile)
    }

    /// The memory screen is told only when the task file comes or goes,
    /// not at every step, so a running task doesn't make it read the notes
    /// again each time.
    @Test func theMemoryScreenLooksAgainOnlyWhenTheTaskFileComesOrGoes() throws {
        var looks = 0
        let watch = feed.$tasksSeen.dropFirst().sink { _ in looks += 1 }
        defer { watch.cancel() }
        feed.start(DigestTask.request)
        #expect(looks == 1)
        for _ in 0..<3 { engine.runPending() }
        feed.refresh()
        #expect(feed.feed.needsYou.compactMap(\.task).count == 1)
        #expect(looks == 1)
        _ = feed.forgetTasks()
        #expect(looks == 2)
    }

    /// Forgetting the kept digest on the memory screen takes its words
    /// off Today's card, and closes them if they are open.
    @Test func forgettingTheDigestNoteTakesItsWordsOffToday() throws {
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) }, onDecline: {}).tapPrimary()
        let done = try #require(engine.tasks.first)
        #expect(done.result != nil)
        feed.open(done)
        #expect(feed.reading != nil)
        let memory = MemoryModel(store: notes, place: .onDevice, onNotesChanged: { feed.refresh() })
        let digest = try #require(memory.notes.first { $0.text.hasPrefix(DigestWords.heading) })
        memory.forget(digest)
        let card = try #require(feed.feed.groups.flatMap(\.items).compactMap(\.task).first { $0.id == done.id })
        #expect(card.result == nil)
        #expect(card.step == DigestWords.removed)
        #expect(feed.reading == nil)
    }

    /// Keeps a digest through the sheet, as a tap would.
    func keepDigest() throws -> AgentTask {
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) }, onDecline: {}).tapPrimary()
        return try #require(engine.tasks.first { $0.id == task.id && $0.result != nil })
    }

    /// The memory screen as the app wires it to Today.
    func memoryScreen() -> MemoryModel {
        HomeView.memoryModel(store: notes, place: .onDevice, onForgetEverything: { feed.forgetTasks() },
                             othersStored: { feed.tasksStored }, onNotesChanged: { feed.notesChanged() },
                             forgetQuotes: { feed.forgetQuotes(of: $0) })
    }

    /// The digest note on the memory screen.
    func digestNote(_ memory: MemoryModel) -> MemoryNote? {
        memory.notes.first { $0.text.hasPrefix(DigestWords.heading) }
    }

    /// A digest the person changed keeping only part of a note: the screen
    /// never guesses the rest went, and says the words are still there.
    @Test func aDigestKeepingPartOfANoteIsSaidToStillHoldIt() throws {
        try notes.remember("Sam's birthday is May 14. Loves lemon cake.", at: Date() - 7_200, source: .toldMe)
        _ = try keepDigest()
        let memory = memoryScreen()
        let digest = try #require(digestNote(memory))
        memory.beginEdit(digest)
        memory.editDraft = DigestWords.heading + ".\n• Sam's birthday is May 14 (You told me)\n• Dentist on Thursday at 3 (You told me)"
        memory.saveEdit()
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.forget(sam)
        #expect(memory.status == DigestWords.stillInDigest)
        #expect(digestNote(memory)?.text.contains("Sam's birthday is May 14") == true)
    }

    /// Changing a note the digest quoted takes its earlier words out of the
    /// digest, and the screen says only that it saved.
    @Test func changingAQuotedNoteTakesItsEarlierWordsOutOfTheDigest() throws {
        try notes.remember("Sam's birthday is May 14", at: Date() - 7_200, source: .toldMe)
        let done = try keepDigest()
        let memory = memoryScreen()
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.beginEdit(sam)
        memory.editDraft = "Sam's birthday is May 15"
        memory.saveEdit()
        #expect(memory.status == MemoryWords.saved(.onDevice))
        #expect(!notes.notes().contains { $0.text.contains("May 14") })
        #expect(todayCards.first { $0.id == done.id }?.result == DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)")
    }

    /// When a digest the person changed keeps a changed note's earlier
    /// words, the screen says so plainly.
    @Test func earlierWordsLeftInAChangedDigestAreSaidSo() throws {
        _ = try keepDigest()
        let memory = memoryScreen()
        let digest = try #require(digestNote(memory))
        memory.beginEdit(digest)
        memory.editDraft = "Busy week. Dentist on Thursday at 3, then rest."
        memory.saveEdit()
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.beginEdit(dentist)
        memory.editDraft = "Dentist on Friday at 4"
        memory.saveEdit()
        #expect(memory.status == DigestWords.earlierWordsInDigest)
        #expect(notes.notes().contains { $0.text.contains("Thursday at 3") })
    }

    /// A note forgotten while its digest's question is open in the sheet:
    /// the sheet goes, the task says why it stopped, and a yes from the
    /// sheet left behind keeps nothing.
    @Test func forgettingANoteUnderAnOpenQuestionClosesIt() throws {
        let task = try startAndAsk()
        feed.review(task)
        let request = try #require(feed.reviewing)
        let sheet = ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) },
                                      onDecline: { feed.closedQuestion(request) })
        let memory = memoryScreen()
        var heard: [TaskAnnouncer.Line] = []
        feed.announce = { heard.append($0) }
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.forget(dentist)
        #expect(memory.status == MemoryWords.forgotten)
        #expect(feed.reviewing == nil)
        // The sheet VoiceOver was in is gone, so the stop is said at once.
        #expect(heard == [TaskAnnouncer.Line(text: DigestTask.title + ". " + DigestWords.noteChanged, urgent: true)])
        let card = try #require(todayCards.first { $0.id == task.id })
        #expect(card.step == DigestWords.noteChanged)
        #expect(card.question == nil)
        #expect(!feed.canApprove(card))
        sheet.tapPrimary()
        #expect(notes.notes().isEmpty)
        #expect(feed.offers == [DigestTask.request])
    }

    var todayCards: [AgentTask] { feed.feed.groups.flatMap(\.items).compactMap(\.task) }

    /// Forgetting a note on the memory screen forgets it everywhere: its
    /// line leaves the kept digest note, Today shows the rest, and only
    /// then does the screen say it is gone.
    @Test func forgettingAQuotedNoteForgetsItEverywhere() throws {
        try notes.remember("Sam's birthday is May 14", at: Date() - 7_200, source: .toldMe)
        let done = try keepDigest()
        let memory = memoryScreen()
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.forget(sam)
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!notes.notes().contains { $0.text.contains("Sam's birthday") })
        #expect(!memory.notes.contains { $0.text.contains("Sam's birthday") })
        let card = try #require(todayCards.first { $0.id == done.id })
        #expect(card.result == DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)")

        // The last line it quoted goes, and the digest goes with it.
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.forget(dentist)
        #expect(memory.status == MemoryWords.forgotten)
        #expect(notes.notes().isEmpty)
        // Taken out here, so the card never says the person removed it.
        #expect(todayCards.first { $0.id == done.id }?.step == DigestWords.tookOut)
    }

    /// A kept digest whose card was put away on Today still loses a note
    /// forgotten on the memory screen, which then says it is gone.
    @Test func forgettingANoteAfterTheCardWasPutAwayForgetsItEverywhere() throws {
        try notes.remember("Sam's birthday is May 14", at: Date() - 7_200, source: .toldMe)
        let done = try keepDigest()
        feed.dismiss(done)
        #expect(!todayCards.contains { $0.id == done.id })
        let memory = memoryScreen()
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.forget(sam)
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!notes.notes().contains { $0.text.contains("Sam's birthday") })
        #expect(digestNote(memory)?.text == DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)")
    }

    /// With a task file that can't be read, the memory screen never says
    /// a note is gone while a digest may hold it: found, it says the words
    /// are still there; not found in a digest changed past finding, that
    /// they may be.
    @Test func aDigestFromATaskFileThatCantBeReadIsSaidToHoldTheWords() throws {
        try notes.remember("Sam's birthday is May 14", at: Date() - 7_200, source: .toldMe)
        // Kept by an engine before this one, whose file can't be read now.
        let week = DigestTask.thisWeek(notes.notes(), now: Date())
        try notes.remember(DigestTask.write(week, now: Date()).text, source: .inferred)
        try Data("not tasks".utf8).write(to: tasksFile)
        let engine = try #require(OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, rule: rule, pace: nil))
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: engine, place: .onDevice)
        let memory = HomeView.memoryModel(store: notes, place: .onDevice, onNotesChanged: { feed.notesChanged() },
                                          forgetQuotes: { feed.forgetQuotes(of: $0) })
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.forget(sam)
        #expect(memory.status == DigestWords.stillInDigest)
        let digest = try #require(digestNote(memory))
        memory.beginEdit(digest)
        memory.editDraft = "My week was busy."
        memory.saveEdit()
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.forget(dentist)
        #expect(memory.status == DigestWords.mayStillBeInDigest)
    }

    /// A digest the person changed that no longer has a note's line: the
    /// screen says its words may be there, never that they are.
    @Test func aLineThePersonTookOutIsSaidToMaybeStay() throws {
        try notes.remember("Sam's birthday is May 14", at: Date() - 7_200, source: .toldMe)
        _ = try keepDigest()
        let memory = memoryScreen()
        let digest = try #require(digestNote(memory))
        memory.beginEdit(digest)
        memory.editDraft = DigestWords.heading + ".\n• Dentist on Thursday at 3 (You told me)"
        memory.saveEdit()
        let sam = try #require(memory.notes.first { $0.text.hasPrefix("Sam's") })
        memory.beginEdit(sam)
        memory.editDraft = "Sam's birthday is May 15"
        memory.saveEdit()
        #expect(memory.status == DigestWords.earlierWordsMayBeInDigest)
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.beginEdit(try #require(digestNote(memory)))
        memory.editDraft = "Quiet week."
        memory.saveEdit()
        memory.forget(dentist)
        #expect(memory.status == DigestWords.mayStillBeInDigest)
    }

    /// While a digest the person changed still holds the note's words, the
    /// screen never says it is all gone, and Today says why it shows none.
    @Test func aNoteLeftInAChangedDigestIsSaidSo() throws {
        let done = try keepDigest()
        let memory = memoryScreen()
        let digest = try #require(memory.notes.first { $0.text.hasPrefix(DigestWords.heading) })
        memory.beginEdit(digest)
        memory.editDraft = "Busy week. Dentist on Thursday at 3, then rest."
        memory.saveEdit()
        let dentist = try #require(memory.notes.first { $0.text.hasPrefix("Dentist") })
        memory.forget(dentist)
        #expect(memory.status == DigestWords.stillInDigest)
        #expect(memory.status != MemoryWords.forgotten)
        #expect(todayCards.first { $0.id == done.id }?.step == DigestWords.hiddenQuote)
    }

    /// When the person removes a kept digest themselves, its card says
    /// nothing more to VoiceOver: they did it.
    @Test func removingTheDigestSaysNothingMore() throws {
        final class Clock { var now = ContinuousClock.now }
        let clock = Clock()
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: rule), tasks: engine,
                             place: .onDevice, clock: { clock.now })
        feed.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        feed.refresh()
        let task = try #require(feed.feed.needsYou.compactMap(\.task).first)
        feed.review(task)
        let request = try #require(feed.reviewing)
        ConfirmationState(request: request, rule: rule, onApprove: { feed.approved($0) }, onDecline: {}).tapPrimary()
        #expect(engine.tasks.first?.result != nil)
        var heard: [TaskAnnouncer.Line] = []
        feed.announce = { heard.append($0) }
        // Long after the last line, so nothing waits its turn.
        clock.now += .seconds(60)
        let memory = MemoryModel(store: notes, place: .onDevice, forgetQuotes: { feed.forgetQuotes(of: $0) })
        let digest = try #require(memory.notes.first { $0.text.hasPrefix(DigestWords.heading) })
        memory.forget(digest)
        #expect(engine.tasks.first?.step == DigestWords.removed)
        clock.now += .seconds(60)
        feed.refresh()
        #expect(heard.isEmpty)
    }

    /// Today is told after a change that was kept, and not after one the
    /// store refused.
    @Test func onlyAKeptEditTellsToday() throws {
        var told = 0
        let memory = MemoryModel(store: notes, place: .onDevice, onNotesChanged: { told += 1 })
        let note = try #require(memory.notes.first)
        memory.beginEdit(note)
        memory.editDraft = "   "
        memory.saveEdit()
        #expect(memory.status == MemoryWords.needsWords)
        #expect(told == 0)
        memory.editDraft = "Dentist on Friday at 3"
        memory.saveEdit()
        #expect(told == 1)
    }

    /// An edit the store couldn't write tells Today nothing, and says so
    /// plainly, without calling the notes unreadable.
    @Test(.enabled(if: getuid() != 0, "root can write to a locked folder"))
    func anEditThatCantBeWrittenTellsTodayNothing() throws {
        var told = 0
        let memory = MemoryModel(store: notes, place: .onDevice, onNotesChanged: { told += 1 })
        let note = try #require(memory.notes.first)
        memory.beginEdit(note)
        memory.editDraft = "Dentist on Friday at 3"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        memory.saveEdit()
        #expect(told == 0)
        #expect(memory.status == MemoryWords.couldNotSave)
        #expect(memory.savedCount == 0)
        #expect(notes.notes().first?.text == note.text)
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
