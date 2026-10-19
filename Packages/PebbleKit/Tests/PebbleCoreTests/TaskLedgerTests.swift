import Foundation
@testable import PebbleCore
import SourceScan
import Testing
import TestScratch

/// A clock tests move by hand. Nothing here reads the wall clock.
final class LedgerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        time = start
    }

    var now: Date { lock.lock(); defer { lock.unlock() }; return time }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        time += seconds
        lock.unlock()
    }
}

/// Every task ends with one line that says how, a done only with proof, and
/// a task that goes quiet says so on its own.
struct TaskLedgerTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let page = TaskProof.source(title: "Maple Dental hours", url: URL(string: "https://mapledental.example/hours")!)
    static let list = TaskProof.artifact(name: "Saturday dentists", kind: .list, reference: "made/list.json")
    static let made = KnownArtifacts(["made/list.json"])

    static func task(_ id: String = "task:1", step: String = "Reading the third page", state: TaskState = .running,
                     question: ConfirmationRequest? = nil, proofs: [TaskProof] = [], started: Date = start) -> AgentTask {
        var task = AgentTask(id: id, title: "Find a dentist", step: step, state: state, question: question,
                             startedAt: started)
        task.proofs = proofs
        return task
    }

    static func book(_ store: any TaskLedgerStoring = InMemoryTaskLedgerStore(), clock: LedgerClock,
                     artifacts: any TaskArtifactResolving = made) -> TaskLedgerBook {
        TaskLedgerBook(store: store, artifacts: artifacts, clock: { clock.now })
    }

    @Test(arguments: [false, true])
    func reconciledTerminalTaskIsNotAnOrphan(delayedRead: Bool) throws {
        let clock = LedgerClock()
        let disk = InMemoryTaskLedgerStore()
        let earlier = Self.book(disk, clock: clock)
        earlier.record(TaskSnapshot(sequence: 1, tasks: [Self.task(), Self.task("orphan")]))
        disk.locked = delayedRead
        let book = Self.book(disk, clock: clock)
        let restored = Self.task(state: .done, proofs: [Self.page])
        book.launch(live: [restored])
        disk.locked = false
        // A restored terminal task is present, even before its observation
        // reaches the ledger. Only the absent task may be stopped at launch.
        #expect(book.takeStoppedAtLaunch().map(\.taskID) == ["orphan"])
        book.record(TaskSnapshot(sequence: 1, tasks: [restored]))
        #expect(try #require(book.ledger(restored.id)).end?.kind == .done(proofs: [Self.page]))
        #expect(book.ledger("orphan")?.end?.kind == .stopped(why: LedgerWords.stoppedWhenClosed))
    }

    // MARK: One end, and nothing after it

    @Test(arguments: [
        TaskLedgerEntry.Kind.done(proofs: [page]), .finishedUnchecked, .failed(reason: "Sorry, I couldn't finish this."),
        .stopped(why: "I stopped, as you asked."),
    ])
    func nothingIsWrittenAfterAnEnd(end: TaskLedgerEntry.Kind) {
        var ledger = TaskLedger(key: .init(task: "task:1", startedAt: Self.start))
        let opened = [ledger.append(.queued, at: Self.start, artifacts: Self.made),
                      ledger.append(.working(step: "Looking"), at: Self.start, artifacts: Self.made),
                      ledger.append(end, at: Self.start + 1, artifacts: Self.made)]
        #expect(opened == [true, true, true])
        let ended = ledger
        for kind: TaskLedgerEntry.Kind in [.working(step: "Again"), .stillWorking(step: "Again"),
                                           .done(proofs: [Self.page]), .finishedUnchecked, .failed(reason: "x"),
                                           .stopped(why: "x"), .stuck(reason: "x", next: "y"), .queued] {
            let written = ledger.append(kind, at: Self.start + 2, artifacts: Self.made)
            #expect(!written)
        }
        #expect(ledger == ended)
        #expect(ledger.entries.filter(\.kind.isEnd).count == 1)
        #expect(ledger.entries.last?.kind.isEnd == true)
    }

    /// A file changed by hand is read as `append` would have written it.
    @Test func aFileChangedByHandCantPutALineAfterAnEnd() {
        let key = TaskLedger.Key(task: "task:1", startedAt: Self.start)
        let entries: [TaskLedgerEntry] = [
            .init(.queued, at: Self.start), .init(.done(proofs: []), at: Self.start + 1),
            .init(.working(step: "After"), at: Self.start + 2), .init(.stopped(why: "x"), at: Self.start + 3),
        ]
        let data = try! JSONEncoder().encode(["key": AnyEncodable(key), "entries": AnyEncodable(entries)])
        let tampered = try! JSONDecoder().decode(TaskLedger.self, from: data)
        #expect(tampered.entries.count == 4)
        let read = tampered.replayed(artifacts: Self.made)
        #expect(read.entries.map(\.kind) == [.queued, .finishedUnchecked])
    }

    // MARK: Done only with proof

    @Test func aDoneWithNoProofIsFinishedUnchecked() {
        var ledger = TaskLedger(key: .init(task: "task:1", startedAt: Self.start))
        ledger.append(.done(proofs: []), at: Self.start, artifacts: Self.made)
        #expect(ledger.entries.map(\.kind) == [.finishedUnchecked])
        #expect(ledger.finish == .unchecked)
        #expect(ledger.finish?.line == "Finished, but I couldn't check the result.")

        var proven = TaskLedger(key: .init(task: "task:2", startedAt: Self.start))
        proven.append(.done(proofs: [Self.page, Self.list, .check("All three open on Saturdays")]), at: Self.start,
                      artifacts: Self.made)
        #expect(proven.finish == .proven([Self.page, Self.list, .check("All three open on Saturdays")]))
        #expect(proven.finish?.line == nil)
    }

    @Test func aSourceNeedsAWebAddress() {
        let bad = ["ftp://mapledental.example/hours", "file:///etc/hosts", "mailto:hi@mapledental.example",
                   "javascript:alert(1)", "https://", "mapledental.example/hours", "data:text/plain,hi"]
        for address in bad {
            let url = URL(string: address)!
            #expect(TaskProof.checked([.source(title: "Hours", url: url)], artifacts: Self.made).isEmpty, "\(address)")
            var ledger = TaskLedger(key: .init(task: "task:1", startedAt: Self.start))
            ledger.append(.done(proofs: [.source(title: "Hours", url: url)]), at: Self.start, artifacts: Self.made)
            #expect(ledger.finish == .unchecked, "\(address)")
        }
        for address in ["https://mapledental.example/hours", "http://mapledental.example", "HTTPS://mapledental.example"] {
            let proof = TaskProof.source(title: "Hours", url: URL(string: address)!)
            #expect(TaskProof.checked([proof], artifacts: Self.made) == [proof], "\(address)")
        }
        // A title no one could read is no proof either.
        let page = URL(string: "https://mapledental.example")!
        for title in ["", "   ", "Hours\u{202E}", "\u{200B}"] {
            #expect(TaskProof.checked([.source(title: title, url: page)], artifacts: Self.made).isEmpty)
        }
    }

    @Test func anArtifactMustResolveOnThisDevice() {
        let elsewhere = TaskProof.artifact(name: "Saturday dentists", kind: .list, reference: "made/other.json")
        #expect(TaskProof.checked([elsewhere], artifacts: Self.made).isEmpty)
        #expect(TaskProof.checked([Self.list], artifacts: NoArtifacts()).isEmpty)
        #expect(TaskProof.checked([Self.list], artifacts: Self.made) == [Self.list])
        let empty = TaskProof.artifact(name: "Saturday dentists", kind: .list, reference: "")
        #expect(TaskProof.checked([empty], artifacts: KnownArtifacts([""])).isEmpty)
        var ledger = TaskLedger(key: .init(task: "task:1", startedAt: Self.start))
        ledger.append(.done(proofs: [elsewhere]), at: Self.start, artifacts: Self.made)
        #expect(ledger.finish == .unchecked)
        // Only the real ones stay, each once.
        var mixed = TaskLedger(key: .init(task: "task:2", startedAt: Self.start))
        mixed.append(.done(proofs: [elsewhere, Self.list, Self.list, .check("  ")]), at: Self.start, artifacts: Self.made)
        #expect(mixed.finish == .proven([Self.list]))
    }

    @Test(.scratchFiles) func aFolderResolvesOnlyFilesInsideIt() throws {
        let root = try #require(Scratch.folder).appendingPathComponent("made", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lists"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("lists/saturday.json"))
        try Data("x".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("outside.json"))
        let folder = FolderArtifacts(root: root)
        #expect(folder.resolves("lists/saturday.json"))
        for reference in ["lists/missing.json", "lists", "../outside.json", "lists/../../outside.json",
                          root.appendingPathComponent("lists/saturday.json").path, "", "lists//saturday.json",
                          "./lists/saturday.json"] {
            #expect(!folder.resolves(reference), "\(reference)")
        }
    }

    @Test func aChipSaysWhatItIs() {
        #expect(Self.page.spoken == "Source: Maple Dental hours")
        #expect(Self.list.spoken == "Made: Saturday dentists")
        #expect(TaskProof.check("All three open on Saturdays").spoken == "Checked: All three open on Saturdays")
        #expect(Self.page.title == "Maple Dental hours")
        #expect(Self.list.title == "Saturday dentists")
    }

    // MARK: What an engine reports

    @Test func aRunIsWrittenDownStepByStep() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.start)
        let book = TaskLedgerBook(store: InMemoryTaskLedgerStore(),
                                  artifacts: KnownArtifacts([SampleTasks.dentistListReference]),
                                  clock: { [engine] in engine.currentDate })
        let following = book.follow(engine)
        let id = engine.start(SampleTasks.dentist)
        // A second at a time, so every moment the engine reports is seen.
        for _ in 0..<43 { engine.advance(by: 1) }
        let asked = try #require(engine.task(id)?.question)
        #expect(engine.resume(id, with: asked.approve()) == .proceeding)
        for _ in 0..<10 { engine.advance(by: 1) }
        following.cancel()
        let ledger = try #require(book.ledger(id))
        let kinds = ledger.entries.map(\.kind)
        #expect(kinds.first == .queued)
        #expect(kinds.contains(.working(step: "Looking at dentists near you")))
        // The slow clinic page: stuck for a moment, then on again.
        #expect(kinds.contains(.stuck(reason: LedgerWords.slowReason, next: LedgerWords.slowNext)))
        #expect(kinds.contains(.needsYou(question: asked.id)))
        #expect(kinds.contains(.answered(yes: true)))
        #expect(kinds.last == .done(proofs: SampleTasks.dentist.proofs))
        #expect(ledger.entries.map(\.at) == ledger.entries.map(\.at).sorted())
    }

    @Test func aQuestionClosedWithoutAYesIsANo() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.start)
        let book = TaskLedgerBook(store: InMemoryTaskLedgerStore(), clock: { [engine] in engine.currentDate })
        let following = book.follow(engine)
        let id = engine.start(SampleTasks.dentist)
        engine.advance(by: 43)
        let asked = try #require(engine.task(id)?.question)
        rule.withdraw(asked)
        engine.questionClosed(asked)
        following.cancel()
        let kinds = try #require(book.ledger(id)).entries.map(\.kind)
        // Done with the pages it read. Its list isn't kept on this device, so it is no proof.
        let pages = SampleTasks.dentist.proofs.filter { if case .source = $0 { true } else { false } }
        #expect(kinds.suffix(2) == [.answered(yes: false), .done(proofs: pages)])
    }

    @Test func aStalledTaskIsStuck() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        clock.advance(20)
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task(step: TaskWords.stalled, state: .stalled)]))
        let kinds = try #require(book.ledger("task:1")).entries.map(\.kind)
        #expect(kinds.last == .stuck(reason: "This step is slow.", next: "I'll try another way in a moment."))
        // Out of tries, waiting on the person to say try again.
        book.record(TaskSnapshot(sequence: 3, tasks: [Self.task(step: TaskWords.stuck, state: .waitingOnYou)]))
        #expect(try #require(book.ledger("task:1")).entries.last?.kind
            == .stuck(reason: "I couldn't get past this step after a few tries.",
                      next: "I'll try again when you say so, or you can stop me."))
    }

    @Test func aLateSnapshotIsNotWrittenDown() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 5, tasks: [Self.task(step: "Second")]))
        book.record(TaskSnapshot(sequence: 4, tasks: [Self.task(step: "First")]))
        #expect(try #require(book.ledger("task:1")).entries.map(\.kind) == [.queued, .working(step: "Second")])
    }

    @Test func aTaskAnEngineLetsGoOfStillEnds() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        book.record(TaskSnapshot(sequence: 2, tasks: []))
        #expect(try #require(book.ledger("task:1")).entries.last?.kind == .stopped(why: "I lost track of this one, so I can't say how it ended."))
    }

    /// A long task that ends after many later ones have is let go only
    /// after its end was told, so its ledger has its real end.
    @Test func aTaskThatEndsAfterManyOthersStillSaysHowItEnded() throws {
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [], origin: Self.start)
        let book = TaskLedgerBook(store: InMemoryTaskLedgerStore(), clock: { [engine] in engine.currentDate })
        let following = book.follow(engine)
        let long = engine.start(TaskScript(title: "Long", steps: [.init("Reading", duration: 600, todo: "read")],
                                           doneLine: "Done.", proofs: [Self.page]))
        for index in 0..<(LocalFakeEngine.endedLimit + 2) {
            engine.start(TaskScript(title: "Short \(index)", steps: [.init("Looking", duration: 1, todo: "look")],
                                    doneLine: "Done."))
        }
        engine.advance(by: 5)
        engine.advance(by: 600)
        following.cancel()
        #expect(engine.task(long)?.state == .done)
        #expect(try #require(book.ledger(long)).entries.last?.kind == .done(proofs: [Self.page]))
    }

    /// An engine that starts its ids over can't put a new task in an old one's ledger.
    @Test func aNewTaskWithAnOldIdGetsItsOwnLedger() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task(state: .done, proofs: [Self.page])]))
        let later = Self.start + 3600
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task(step: "Starting again", started: later)]))
        #expect(book.ledgers.count == 2)
        #expect(try #require(book.ledger("task:1")).entries.last?.kind == .working(step: "Starting again"))
    }

    // MARK: QuietWatch

    @Test func aQuietTaskSaysItIsStillOnItsLastStep() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task(step: "Reading the third page")]))
        clock.advance(QuietWatch.period - 1)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.count == 2)
        clock.advance(1)
        book.watch()
        let ledger = try #require(book.ledger("task:1"))
        #expect(ledger.entries.last?.kind == .stillWorking(step: "Reading the third page"))
        #expect(ledger.entries.last?.watched == true)
        #expect(ledger.quietLine == "Still on it: reading the third page.")
        // Said once a period, not at every look.
        book.watch()
        clock.advance(60)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.count == 3)
    }

    @Test func threeQuietPeriodsInARowAreStuck() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        for _ in 0..<35 {
            clock.advance(60)
            book.watch()
        }
        let ledger = try #require(book.ledger("task:1"))
        let quiet = ledger.entries.filter(\.watched).map(\.kind)
        #expect(quiet == [.stillWorking(step: "Reading the third page"), .stillWorking(step: "Reading the third page"),
                          .stuck(reason: LedgerWords.quietReason, next: LedgerWords.quietNext)])
        #expect(ledger.entries.filter(\.watched).map(\.at) == [600, 1200, 1800].map { Self.start + $0 })
        #expect(ledger.quietLine == "I haven't moved forward on this in a while. I'll keep trying, or you can stop me here.")
        // Said once: stuck stays the last line until something moves.
        clock.advance(3600)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.count == ledger.entries.count)
    }

    /// One look after a long sleep says stuck at once, not a backlog.
    @Test func oneLookAfterALongQuietIsStuck() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        clock.advance(35 * 60)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.last?.kind
            == .stuck(reason: LedgerWords.quietReason, next: LedgerWords.quietNext))
    }

    @Test func aNewStepStartsTheQuietOver() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task(step: "First")]))
        clock.advance(QuietWatch.period * 2)
        book.watch()
        clock.advance(10)
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task(step: "Second")]))
        #expect(try #require(book.ledger("task:1")).quietLine == nil)
        clock.advance(QuietWatch.period - 10)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.last?.kind == .working(step: "Second"))
        clock.advance(10)
        book.watch()
        #expect(try #require(book.ledger("task:1")).entries.last?.kind == .stillWorking(step: "Second"))
    }

    @Test func aTaskWaitingOnThePersonOrEndedIsLeftAlone() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        let rule = AskFirst.isolated()
        let question = try #require(rule.ask(SampleTasks.holdVisit))
        book.record(TaskSnapshot(sequence: 1, tasks: [
            Self.task("task:1", state: .waitingOnYou, question: question),
            Self.task("task:2", state: .done, proofs: [Self.page]),
            Self.task("task:3", state: .failed),
        ]))
        let before = book.ledgers
        clock.advance(QuietWatch.period * 5)
        book.watch()
        #expect(book.ledgers == before)
    }

    @Test func theStillLineReadsAsASentence() {
        #expect(LedgerWords.stillOnIt("Reading the third page") == "Still on it: reading the third page.")
        #expect(LedgerWords.stillOnIt("PTA notes, page two.") == "Still on it: PTA notes, page two.")
        #expect(LedgerWords.stillOnIt("I'm reading reviews") == "Still on it: I'm reading reviews.")
        #expect(LedgerWords.stillOnIt("Checking hours?") == "Still on it: checking hours?")
    }

    // MARK: At launch

    @Test func atLaunchATaskNoEngineHasStopsWhenTheAppClosed() throws {
        let clock = LedgerClock()
        let store = InMemoryTaskLedgerStore()
        let before = Self.book(store, clock: clock)
        before.record(TaskSnapshot(sequence: 1, tasks: [
            Self.task("task:1"), Self.task("task:2", step: "Still going"), Self.task("task:3", state: .done, proofs: [Self.page]),
        ]))
        clock.advance(600)
        let book = Self.book(store, clock: clock)
        book.launch(live: [Self.task("task:2", step: "Still going")])
        #expect(try #require(book.ledger("task:1")).entries.last
            == TaskLedgerEntry(.stopped(why: "This stopped when the app closed."), at: Self.start + 600))
        #expect(try #require(book.ledger("task:2")).entries.last?.kind == .working(step: "Still going"))
        #expect(try #require(book.ledger("task:3")).entries.last?.kind == .done(proofs: [Self.page]))
        // Handed over once, for an offer to pick it up again.
        #expect(book.takeStoppedAtLaunch().map(\.taskID) == ["task:1"])
        #expect(book.takeStoppedAtLaunch().isEmpty)
        // Once a launch.
        book.launch(live: [])
        #expect(try #require(book.ledger("task:2")).entries.last?.kind == .working(step: "Still going"))
        #expect(store.ledgers == book.ledgers)
    }

    @Test func launchWaitsUntilTheLedgerCanBeRead() throws {
        let clock = LedgerClock()
        let store = InMemoryTaskLedgerStore()
        Self.book(store, clock: clock).record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1")]))
        store.locked = true
        clock.advance(60)
        let book = Self.book(store, clock: clock)
        book.launch(live: [])
        // Begun this launch while it couldn't be read: never taken for one from before.
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:9", step: "New", started: Self.start + 60)]))
        clock.advance(60)
        store.locked = false
        let ledger = try #require(book.ledger("task:1"))
        #expect(ledger.entries.last == TaskLedgerEntry(.stopped(why: LedgerWords.stoppedWhenClosed), at: Self.start + 60))
        #expect(try #require(book.ledger("task:9")).entries.last?.kind == .working(step: "New"))
    }

    // MARK: Kept on the device

    @Test func nothingIsWrittenWhileLockedAndAllOfItOnceUnlocked() throws {
        let clock = LedgerClock()
        let kept = TaskLedger(key: .init(task: "task:0", startedAt: Self.start)).appending(.finishedUnchecked, at: Self.start)
        let store = InMemoryTaskLedgerStore([kept], locked: true)
        let book = Self.book(store, clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1")]))
        clock.advance(QuietWatch.period)
        book.watch()
        book.remove("task:5")
        #expect(store.writes == 0)
        #expect(store.ledgers == [kept])
        store.locked = false
        let read = book.ledgers
        #expect(read.map(\.taskID) == ["task:0", "task:1"])
        #expect(store.ledgers == read)
        #expect(store.writes == 1)
    }

    /// A store that can't be read yet is never written, even one that would
    /// take the write: what it holds would be lost under it.
    @Test func nothingIsWrittenOverAStoreThatCantBeRead() {
        final class Unreadable: TaskLedgerStoring, @unchecked Sendable {
            var written: [[TaskLedger]] = []
            func read() -> [TaskLedger]? { nil }
            func write(_ ledgers: [TaskLedger]) -> Bool { written.append(ledgers); return true }
            func erase() -> Bool { true }
        }
        let clock = LedgerClock()
        let store = Unreadable()
        let book = Self.book(store, clock: clock)
        book.launch(live: [])
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1", state: .done, proofs: [Self.page])]))
        clock.advance(QuietWatch.period * 4)
        book.watch()
        book.remove("task:9")
        #expect(store.written.isEmpty)
        #expect(book.ledger("task:1")?.finish == .proven([Self.page]))
    }

    @Test func aTaskPickedUpWhileLockedJoinsItsLedger() throws {
        let clock = LedgerClock()
        let store = InMemoryTaskLedgerStore()
        Self.book(store, clock: clock).record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1", step: "Before")]))
        store.locked = true
        let book = Self.book(store, clock: clock)
        clock.advance(60)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1", step: "After")]))
        store.locked = false
        #expect(try #require(book.ledger("task:1")).entries.map(\.kind)
            == [.queued, .working(step: "Before"), .working(step: "After")])
    }

    @Test func forgetEmptiesEveryLedgerReadOrNot() throws {
        let clock = LedgerClock()
        let kept = TaskLedger(key: .init(task: "task:0", startedAt: Self.start)).appending(.queued, at: Self.start)
        let store = InMemoryTaskLedgerStore([kept], locked: true)
        let book = Self.book(store, clock: clock)
        book.record(TaskSnapshot(sequence: 3, tasks: [Self.task("task:1")]))
        book.forget()
        #expect(store.ledgers.isEmpty)
        store.locked = false
        #expect(book.ledgers.isEmpty)
        // A late snapshot from before the forget writes nothing back.
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task("task:1")]))
        #expect(book.ledgers.isEmpty)
        #expect(store.ledgers.isEmpty)
    }

    @Test func clearingATaskTakesItsLedger() {
        let clock = LedgerClock()
        let store = InMemoryTaskLedgerStore()
        let book = Self.book(store, clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1", state: .done, proofs: [Self.page]),
                                                      Self.task("task:2", state: .failed)]))
        book.remove("task:1")
        #expect(book.ledgers.map(\.taskID) == ["task:2"])
        #expect(store.ledgers.map(\.taskID) == ["task:2"])
    }

    @Test func onlyTheNewestEndedLedgersAreKept() {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        let ended = (0..<(TaskLedgerBook.endedLimit + 5)).map { Self.task("task:\($0)", state: .failed) }
        book.record(TaskSnapshot(sequence: 1, tasks: ended.reversed() + [Self.task("task:going")]))
        #expect(book.ledgers.count == TaskLedgerBook.endedLimit + 1)
        #expect(book.ledger("task:going") != nil)
        #expect(book.ledger("task:0") == nil)
    }

    @Test func clearingWhileUnreadableStaysClearedAfterReadsRecover() {
        final class RecoveringStore: TaskLedgerStoring, @unchecked Sendable {
            var ledgers: [TaskLedger] = []
            var readable = false
            var writable = false
            func read() -> [TaskLedger]? { readable ? ledgers : nil }
            func write(_ value: [TaskLedger]) -> Bool {
                guard writable else { return false }
                ledgers = value
                return true
            }
            func erase() -> Bool { ledgers = []; return true }
        }
        let clock = LedgerClock()
        let store = RecoveringStore()
        store.ledgers = ["task:clear", "task:keep"].map {
            TaskLedger(key: .init(task: $0, startedAt: Self.start)).appending(.queued, at: Self.start)
        }
        let book = Self.book(store, clock: clock)
        book.remove("task:clear")
        #expect(store.ledgers.count == 2)
        store.readable = true
        #expect(book.ledgers.map(\.taskID) == ["task:keep"])
        #expect(store.ledgers.count == 2, "a failed save must keep the deletion pending")
        // A snapshot still carrying the cleared card must not undo that pending deletion.
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:clear"), Self.task("task:keep")]))
        #expect(book.ledger("task:clear") == nil)
        store.writable = true
        #expect(book.ledgers.map(\.taskID) == ["task:keep"])
        #expect(store.ledgers.map(\.taskID) == ["task:keep"])
        #expect(Self.book(store, clock: clock).ledgers.map(\.taskID) == ["task:keep"])
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task("task:clear", started: Self.start + 1)]))
        #expect(book.ledger("task:clear")?.key.startedAt == Self.start + 1,
                "a successful save retires the pending deletion so a new run can reuse the id")
    }

    @Test func aLongTaskOutlastsSixtyEarlierFinishes() throws {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        var long = Self.task("task:long")
        var tasks = [long]
        book.record(TaskSnapshot(sequence: 1, tasks: tasks))
        for index in 0..<TaskLedgerBook.endedLimit {
            clock.advance(1)
            tasks.insert(Self.task("task:short:\(index)", state: .done, proofs: [Self.page]), at: 0)
            book.record(TaskSnapshot(sequence: index + 2, tasks: tasks))
        }
        clock.advance(1)
        long.state = .done
        long.proofs = [Self.page]
        tasks[tasks.count - 1] = long
        book.record(TaskSnapshot(sequence: 100, tasks: tasks))
        #expect(try #require(book.ledger(for: long)).end?.kind == .done(proofs: [Self.page]))
        #expect(book.ledger("task:short:0") == nil)
        book.record(TaskSnapshot(sequence: 101, tasks: tasks))
        #expect(book.ledgers.count == TaskLedgerBook.endedLimit)
        #expect(book.ledgers.allSatisfy { $0.isEnded })
        #expect(book.ledger(for: long)?.finish == .proven([Self.page]))
        #expect(book.ledger("task:short:0") == nil)
    }

    @Test func anEvictedEndIsNotRecreatedByAnUnchangedSnapshot() {
        let clock = LedgerClock()
        let book = Self.book(clock: clock)
        let tasks = (0...TaskLedgerBook.endedLimit).map { Self.task("task:\($0)", state: .failed) }
        book.record(TaskSnapshot(sequence: 1, tasks: tasks.reversed()))
        #expect(book.ledger("task:0") == nil)
        book.record(TaskSnapshot(sequence: 2, tasks: tasks.reversed()))
        #expect(book.ledgers.count == TaskLedgerBook.endedLimit)
        #expect(book.ledger("task:0") == nil)
        #expect(book.ledgers.allSatisfy { $0.isEnded })
    }

    @Test(.scratchFiles) func aFolderRejectsSymlinksOutsideItsRoot() throws {
        let base = try #require(Scratch.folder)
        let root = base.appendingPathComponent("made")
        let outside = base.appendingPathComponent("made-elsewhere")
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("note.txt"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("file.txt"),
                                      withDestinationURL: outside.appendingPathComponent("note.txt"))
        let folder = FolderArtifacts(root: root)
        #expect(!folder.resolves("link/note.txt"))
        #expect(!folder.resolves("file.txt"))
        // A link that stays inside still resolves, and so does a root
        // reached through a link of its own.
        try Data("[]".utf8).write(to: root.appendingPathComponent("list.json"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("same.json"),
                                      withDestinationURL: root.appendingPathComponent("list.json"))
        #expect(folder.resolves("same.json"))
        let alias = base.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: root)
        let throughAlias = FolderArtifacts(root: alias)
        #expect(throughAlias.resolves("list.json"))
        #expect(!throughAlias.resolves("link/note.txt"))
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot, arguments: [false, true])
    func forgetTriesDeletionWhenItsMarkerCannotBeWritten(blockDeletion: Bool) throws {
        let base = try #require(Scratch.folder)
        let folder = base.appendingPathComponent("data")
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ledger.json")
        let staged = folder.appendingPathComponent(".ledger.json.next")
        let markerParent = base.appendingPathComponent("not-a-folder")
        try Data().write(to: markerParent)
        let marker = markerParent.appendingPathComponent("forgotten")
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
        let book = Self.book(store, clock: LedgerClock())
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        try Data(contentsOf: file).write(to: staged)
        if blockDeletion { try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        book.forget()
        #expect(store.erase() == !blockDeletion)
        #expect(!manager.fileExists(atPath: marker.path))
        if blockDeletion {
            #expect(store.read() == nil)
            #expect(!store.write([]))
            #expect(book.ledgers.isEmpty)
            #expect(manager.fileExists(atPath: file.path))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        #expect(store.read() == [])
        #expect(book.ledgers.isEmpty)
        #expect(!manager.fileExists(atPath: file.path))
        #expect(!manager.fileExists(atPath: staged.path))
        #expect(TaskLedgerFileStore(fileURL: file, forgetMarker: marker).read() == [])
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot)
    func anInaccessibleFolderIsNotProofThatErasureFinished() throws {
        let base = try #require(Scratch.folder)
        let folder = base.appendingPathComponent("hidden")
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ledger.json")
        let marker = base.appendingPathComponent("erase-owed")
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
        Self.book(store, clock: LedgerClock()).record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(!store.erase())
        #expect(store.read() == nil)
        #expect(manager.fileExists(atPath: marker.path))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(store.read() == [])
        #expect(!manager.fileExists(atPath: file.path))
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot)
    func directoryReadFailurePreservesHistoryAfterRecovery() throws {
        let base = try #require(Scratch.folder)
        let folder = base.appendingPathComponent("hidden")
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ledger.json")
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: base.appendingPathComponent("erase-owed"))
        Self.book(store, clock: LedgerClock()).record(TaskSnapshot(sequence: 1, tasks: [
            Self.task("original", state: .done, proofs: [Self.page]),
        ]))
        let original = try #require(store.read()?.first)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(store.read() == nil)
        let book = Self.book(store, clock: LedgerClock())
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("new")]))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task("new", state: .done, proofs: [Self.page])]))
        #expect(book.ledger("original") == original)
        #expect(store.read()?.first { $0.taskID == "original" } == original)
        #expect(store.read()?.count == 2)
    }

    @Test func delayedLaunchUsesTheCurrentSnapshot() throws {
        let clock = LedgerClock()
        let store = InMemoryTaskLedgerStore()
        Self.book(store, clock: clock).record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        store.locked = true
        let book = Self.book(store, clock: clock)
        book.launch(live: [])
        store.locked = false
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task()]))
        #expect(book.ledger("task:1")?.isEnded == false)
        book.record(TaskSnapshot(sequence: 2, tasks: [Self.task(state: .done, proofs: [Self.page])]))
        #expect(book.ledger("task:1")?.finish == .proven([Self.page]))
        #expect(book.takeStoppedAtLaunch().isEmpty)
    }

    // MARK: The file

    @Test(.scratchFiles) func theFileIsKeptBesideTheTasksAndReadBackAsWritten() throws {
        let base = try #require(Scratch.folder)
        let (file, marker) = TaskLedgerFileStore.location(base: base)
        #expect(file.deletingLastPathComponent() == TaskStore.location(base: base, app: TaskStore.appFolder).file
            .deletingLastPathComponent())
        #expect(marker.deletingLastPathComponent() == TaskStore.location(base: base, app: TaskStore.appFolder).marker
            .deletingLastPathComponent())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
        #expect(store.read() == [])
        let clock = LedgerClock()
        let book = Self.book(store, clock: clock)
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1", state: .done, proofs: [Self.page, Self.list])]))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let again = Self.book(TaskLedgerFileStore(fileURL: file, forgetMarker: marker), clock: clock)
        #expect(again.ledgers == book.ledgers)
        #expect(again.ledger("task:1")?.finish == .proven([Self.page, Self.list]))
        // Read with what this device has: a list no longer here is no proof.
        let elsewhere = Self.book(TaskLedgerFileStore(fileURL: file, forgetMarker: marker), clock: clock,
                                  artifacts: NoArtifacts())
        #expect(elsewhere.ledger("task:1")?.finish == .proven([Self.page]))
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot)
    func aFileThatCantBeReadYetIsNeverWrittenOver() throws {
        let base = try #require(Scratch.folder)
        let (file, marker) = TaskLedgerFileStore.location(base: base)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clock = LedgerClock()
        Self.book(TaskLedgerFileStore(fileURL: file, forgetMarker: marker), clock: clock)
            .record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1")]))
        let before = try Data(contentsOf: file)
        // As before the device is first unlocked.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
        #expect(store.read() == nil)
        #expect(!store.write([]))
        let book = Self.book(store, clock: clock)
        book.launch(live: [])
        book.record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:2", started: Self.start + 1)]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before)
        // Unlocked: both are there, and the one no engine had has stopped.
        #expect(book.ledgers.map(\.taskID) == ["task:1", "task:2"])
        #expect(book.ledger("task:1")?.entries.last?.kind == .stopped(why: LedgerWords.stoppedWhenClosed))
        #expect(try Data(contentsOf: file) != before)
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot)
    func anEraseThatCantFinishIsOwedAndNeverRead() throws {
        let base = try #require(Scratch.folder)
        let (file, marker) = TaskLedgerFileStore.location(base: base)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = LedgerClock()
        Self.book(TaskLedgerFileStore(fileURL: file, forgetMarker: marker), clock: clock)
            .record(TaskSnapshot(sequence: 1, tasks: [Self.task("task:1")]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let store = TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
        #expect(!store.erase())
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // A later launch never reads it.
        #expect(TaskLedgerFileStore(fileURL: file, forgetMarker: marker).read() == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(TaskLedgerFileStore(fileURL: file, forgetMarker: marker).read() == [])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(.scratchFiles) func aFileNoOneCanUnderstandGoes() throws {
        let base = try #require(Scratch.folder)
        let (file, marker) = TaskLedgerFileStore.location(base: base)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a ledger".utf8).write(to: file)
        #expect(TaskLedgerFileStore(fileURL: file, forgetMarker: marker).read() == [])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// PERMANENT GUARD. Written as the kept tasks are: protected until the
    /// device is first unlocked, and the marker, which holds nothing,
    /// written while it may still be locked. Every write goes through these.
    @Test func theFileIsProtectedLikeTheTasks() throws {
        let mask = Data.WritingOptions.fileProtectionMask
        #expect(TaskLedgerFileStore.fileWriting(protected: true) == TaskStore.fileWriting(protected: true))
        #expect(TaskLedgerFileStore.fileWriting(protected: true).intersection(mask)
            == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(TaskLedgerFileStore.markerWriting(protected: true).intersection(mask) == .noFileProtection)
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleCore/TaskLedger.swift"),
                              encoding: .utf8)
        let writes = SwiftSource(text).calls(named: ["write"]).filter { $0.arguments.hasPrefix("to:") }
        #expect(writes.count == 2, "\(writes.map(\.arguments))")
        for call in writes {
            #expect(["Self.fileWriting()", "Self.markerWriting()"].contains { call.arguments.contains($0) },
                    "\(call.arguments)")
        }
    }
}

extension TaskLedger {
    func appending(_ kind: TaskLedgerEntry.Kind, at: Date) -> TaskLedger {
        var ledger = self
        ledger.append(kind, at: at, artifacts: NoArtifacts())
        return ledger
    }
}

/// Encodes whatever it wraps, to build a file by hand.
struct AnyEncodable: Encodable {
    let encode: (Encoder) throws -> Void
    init(_ value: some Encodable) { encode = value.encode }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}

extension LedgerWords {
    /// Every ledger line a person can see or hear, with sample words where
    /// a line takes some. Read by the dash test.
    static var all: [String] {
        [unchecked, stillOnIt("Reading the third page"), gettingStarted, quietReason, quietNext, slowReason, slowNext,
         triedReason, triedNext, stoppedWhenClosed, letGo, spokenSource("Maple Dental hours"),
         spokenMade("Saturday dentists"), spokenCheck("All three open on Saturdays")]
        + SampleTasks.all.flatMap { $0.proofs.map(\.title) }
    }
}
