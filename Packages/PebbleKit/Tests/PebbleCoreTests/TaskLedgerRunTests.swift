import Foundation
@testable import PebbleCore
import Testing

/// The same numbers every run, from a seed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fifty scripted tasks with outcomes drawn from a seed, played on
/// `LocalFakeEngine`'s own clock, with `QuietWatch` looking each minute.
/// The rule this guards: no task ever ends silently.
struct TaskLedgerRunTests {
    @Test(arguments: [false, true])
    func thirteenTasksFinishingTogetherAllReachTheirLedgers(reentrant: Bool) throws {
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [])
        let book = TaskLedgerBook(store: InMemoryTaskLedgerStore(), clock: { engine.currentDate })
        let refreshing = reentrant ? engine.observe { _ in engine.refresh() } : nil
        let following = book.follow(engine)
        defer { following.cancel(); refreshing?.cancel() }
        let ids = (0..<13).map { index in
            engine.start(TaskScript(title: "Short \(index)",
                                    steps: [.init("Reading", duration: 1, todo: "read")],
                                    doneLine: "Ready.", proofs: [.check("Read the note")]))
        }
        engine.advance(by: 2)
        #expect(engine.tasks.count == LocalFakeEngine.endedLimit)
        for id in ids {
            #expect(try #require(book.ledger(id)).end?.kind == .done(proofs: [.check("Read the note")]))
        }
    }

    @Test func concurrentRefreshCannotTrimUnpublishedCompletions() throws {
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [])
        let book = TaskLedgerBook(store: InMemoryTaskLedgerStore(), clock: { engine.currentDate })
        let following = book.follow(engine)
        defer { following.cancel() }
        let ids = (0..<13).map { index in
            engine.start(TaskScript(title: "Short \(index)",
                                    steps: [.init("Reading", duration: 1, todo: "read")],
                                    doneLine: "Ready.", proofs: [.check("Read the note")]))
        }
        let unlocked = DispatchSemaphore(value: 0)
        let publish = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        engine.beforeNextPublication {
            unlocked.signal()
            #expect(publish.wait(timeout: .now() + 10) == .success)
        }
        DispatchQueue.global().async {
            engine.advance(by: 2)
            finished.signal()
        }
        defer { publish.signal() }
        try #require(unlocked.wait(timeout: .now() + 10) == .success)
        // The completing mutation has unlocked but has not published.
        // This unchanged mutation must neither publish nor trim its ends.
        engine.refresh()
        #expect(engine.tasks.count == 13)
        #expect(ids.allSatisfy { book.ledger($0)?.end == nil })
        publish.signal()
        try #require(finished.wait(timeout: .now() + 10) == .success)
        #expect(engine.tasks.count == LocalFakeEngine.endedLimit)
        for id in ids {
            #expect(try #require(book.ledger(id)).end?.kind == .done(proofs: [.check("Read the note")]))
        }
    }

    enum Outcome: CaseIterable {
        case doneWithProof, doneWithoutProof, doneWithFalseProof, fails, stalls, stuck, stopped, closedMidTask, quiet
    }

    struct Planned {
        let title: String
        let outcome: Outcome
        let startsAt: Int
        /// For a stop, the minute it comes.
        let stopsAt: Int
    }

    static let made = KnownArtifacts(["made/plan.json", "made/list.json"])
    static let realProofs: [TaskProof] = [
        .source(title: "Maple Dental hours", url: URL(string: "https://mapledental.example/hours")!),
        .source(title: "Library hours", url: URL(string: "http://library.example/hours")!),
        .artifact(name: "Your week", kind: .plan, reference: "made/plan.json"),
        .artifact(name: "Saturday dentists", kind: .list, reference: "made/list.json"),
        .check("All three open on Saturdays"),
    ]
    static let falseProofs: [TaskProof] = [
        .source(title: "Hours", url: URL(string: "ftp://mapledental.example/hours")!),
        .source(title: "Hours", url: URL(string: "file:///etc/hosts")!),
        .artifact(name: "A list", kind: .list, reference: "made/not-here.json"),
        .artifact(name: "A list", kind: .list, reference: "../made/list.json"),
        .check("   "),
    ]

    static func script(_ planned: Planned, random: inout SeededRandom) -> TaskScript {
        func work(_ index: Int, _ seconds: TimeInterval, stalls: Int = 0) -> TaskScript.Step {
            .init("Step \(index + 1) of \(planned.title)", kind: .work(stalls: stalls), duration: seconds,
                  todo: "do step \(index + 1)")
        }
        let count = Int.random(in: 1...4, using: &random)
        var steps = (0..<count).map { work($0, TimeInterval(Int.random(in: 20...420, using: &random))) }
        var proofs: [TaskProof] = []
        switch planned.outcome {
        case .doneWithProof:
            proofs = Array(realProofs.shuffled(using: &random).prefix(Int.random(in: 1...3, using: &random)))
        case .doneWithoutProof:
            break
        case .doneWithFalseProof:
            proofs = Array(falseProofs.shuffled(using: &random).prefix(Int.random(in: 1...3, using: &random)))
        case .fails:
            steps.append(.init("Trying the last step", kind: .fails, todo: "finish"))
        case .stalls:
            // Slow, then on again within the tries it has.
            steps.insert(work(count, 30, stalls: Int.random(in: 1...2, using: &random)), at: 0)
            proofs = [realProofs[0]]
        case .stuck:
            // Out of tries: waits on the person.
            steps.insert(work(count, 30, stalls: 3), at: 0)
        case .stopped, .closedMidTask:
            steps += (0..<4).map { work(count + $0, TimeInterval(Int.random(in: 300...900, using: &random))) }
        case .quiet:
            steps.insert(work(count, TimeInterval(35 * 60 + Int.random(in: 1...300, using: &random))), at: 0)
            proofs = [realProofs[4]]
        }
        return TaskScript(title: planned.title, steps: steps, determinate: Bool.random(using: &random),
                          doneLine: "Done with \(planned.title).", proofs: proofs)
    }

    /// The checks that hold at every look, for every ledger.
    static func expectSound(_ book: TaskLedgerBook, at now: Date, _ where: String) {
        for ledger in book.ledgers {
            let ends = ledger.entries.indices.filter { ledger.entries[$0].kind.isEnd }
            #expect(ends.count <= 1, "\(ledger.taskID) has \(ends.count) ends \(`where`)")
            if let end = ends.first { #expect(end == ledger.entries.count - 1, "a line after the end of \(ledger.taskID)") }
            for entry in ledger.entries {
                guard case .done(let proofs) = entry.kind else { continue }
                #expect(!proofs.isEmpty, "\(ledger.taskID) done without a proof")
                #expect(TaskProof.checked(proofs, artifacts: made) == proofs, "\(ledger.taskID) done with a false proof")
            }
            guard !ledger.isEnded, let last = ledger.entries.last else { continue }
            let quietFor = now.timeIntervalSince(last.at)
            if case .stuck = last.kind { continue }
            #expect(quietFor < QuietWatch.period, "\(ledger.taskID) silent for \(quietFor)s \(`where`)")
        }
    }

    @Test(arguments: [UInt64(20261018), 7, 99])
    func fiftySeededTasksNeverEndSilently(seed: UInt64) throws {
        var random = SeededRandom(seed: seed)
        let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Every outcome at least once, the rest drawn from the seed.
        let outcomes = Outcome.allCases + (0..<(50 - Outcome.allCases.count)).map { _ in
            Outcome.allCases.randomElement(using: &random)!
        }
        let planned = outcomes.enumerated().map { index, outcome in
            Planned(title: "Task \(index + 1)", outcome: outcome, startsAt: Int.random(in: 0...20, using: &random),
                    stopsAt: Int.random(in: 22...40, using: &random))
        }
        let scripts = Dictionary(uniqueKeysWithValues: planned.map { ($0.title, Self.script($0, random: &random)) })
        // Slow enough that a stall is seen at a five second look.
        let policy = RetryPolicy(timeout: 20, maxRetries: 2, backoff: 10, maxBackoff: 30)

        // The app that stays open, and one that closes at minute 30.
        let engine = LocalFakeEngine(rule: .isolated(), policy: policy, scripts: [], origin: origin)
        let closing = LocalFakeEngine(rule: .isolated(), policy: policy, scripts: [], origin: origin)
        let store = InMemoryTaskLedgerStore()
        let closingStore = InMemoryTaskLedgerStore()
        let book = TaskLedgerBook(store: store, artifacts: Self.made, clock: { [engine] in engine.currentDate })
        let closingBook = TaskLedgerBook(store: closingStore, artifacts: Self.made,
                                         clock: { [closing] in closing.currentDate })
        let following = book.follow(engine)
        var closingFollow: TaskObservation? = closingBook.follow(closing)
        var ids: [String: String] = [:]
        let closesAt = 30

        for minute in 0..<120 {
            for task in planned where task.startsAt == minute {
                let script = try #require(scripts[task.title])
                ids[task.title] = task.outcome == .closedMidTask ? closing.start(script) : engine.start(script)
            }
            for task in planned where task.outcome == .stopped && task.stopsAt == minute {
                engine.stop(try #require(ids[task.title]))
            }
            if minute == closesAt {
                // The app closes: nothing more is heard from it.
                closingFollow?.cancel()
                closingFollow = nil
            }
            for _ in 0..<12 {
                engine.advance(by: 5)
                if closingFollow != nil { closing.advance(by: 5) }
            }
            book.watch()
            if closingFollow != nil { closingBook.watch() }
            Self.expectSound(book, at: engine.currentDate, "at minute \(minute + 1)")
        }

        // The closed app opens again, with no engine going on its tasks.
        let reopened = TaskLedgerBook(store: closingStore, artifacts: Self.made,
                                      clock: { origin + TimeInterval(closesAt * 60 + 90) })
        reopened.launch(live: [])
        let stopped = reopened.takeStoppedAtLaunch()
        Self.expectSound(reopened, at: origin + TimeInterval(closesAt * 60 + 90), "after the app opened again")

        for task in planned {
            let id = try #require(ids[task.title])
            let ledger = try #require(task.outcome == .closedMidTask ? reopened.ledger(id) : book.ledger(id),
                                      "\(task.title) has no ledger")
            let kinds = ledger.entries.map(\.kind)
            switch task.outcome {
            case .doneWithProof:
                let proofs = try #require(scripts[task.title]).proofs
                #expect(kinds.last == .done(proofs: proofs), "\(task.title)")
            case .doneWithoutProof, .doneWithFalseProof:
                #expect(kinds.last == .finishedUnchecked, "\(task.title)")
            case .fails:
                #expect(kinds.last == .failed(reason: TaskWords.failed), "\(task.title)")
            case .stalls:
                #expect(kinds.contains(.stuck(reason: LedgerWords.slowReason, next: LedgerWords.slowNext)), "\(task.title)")
                #expect(kinds.last == .done(proofs: [Self.realProofs[0]]), "\(task.title)")
            case .stuck:
                #expect(kinds.last == .stuck(reason: LedgerWords.triedReason, next: LedgerWords.triedNext), "\(task.title)")
            case .stopped:
                #expect(kinds.last == .stopped(why: TaskWords.stopped), "\(task.title)")
            case .closedMidTask:
                // Ended before the app closed, or stopped as it opened again.
                #expect(ledger.isEnded, "\(task.title)")
                if kinds.last == .stopped(why: LedgerWords.stoppedWhenClosed) {
                    #expect(stopped.contains { $0.key == ledger.key }, "\(task.title)")
                }
            case .quiet:
                // Its first step is the long one: still on it twice, then stuck, then done.
                let step = try #require(scripts[task.title]?.steps.first?.text)
                let watched = ledger.entries.filter(\.watched).map(\.kind)
                #expect(watched.prefix(3) == [.stillWorking(step: step), .stillWorking(step: step),
                                              .stuck(reason: LedgerWords.quietReason, next: LedgerWords.quietNext)],
                        "\(task.title): \(watched)")
                #expect(kinds.last == .done(proofs: [Self.realProofs[4]]), "\(task.title)")
            }
        }
        #expect(stopped.contains { $0.entries.last?.kind == .stopped(why: LedgerWords.stoppedWhenClosed) })

        // Nothing goes in after an end, whatever an engine says next.
        let ended = book.ledgers.filter(\.isEnded)
        #expect(!ended.isEmpty)
        let revived = ended.map {
            AgentTask(id: $0.taskID, title: "Again", step: "Working again", startedAt: $0.key.startedAt)
        }
        book.record(TaskSnapshot(sequence: Int.max, tasks: revived))
        for _ in 0..<5 { book.watch() }
        for ledger in ended { #expect(book.ledgers.first { $0.key == ledger.key } == ledger) }
        following.cancel()
        // Every ledger in the store is the book's own.
        #expect(store.ledgers == book.ledgers)
    }
}
