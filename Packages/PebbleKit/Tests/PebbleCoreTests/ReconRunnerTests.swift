import Foundation
@testable import PebbleCore
import Testing

/// The runner's promises about when a summary is begun, kept, let go and
/// begun again, on the scripted engine and on one that picks its own steps.
struct ReconRunnerTests {
    static let readOn = ReconTests.readOn
    static let sources = ReconTests.sources

    // MARK: The summary begins when the card says so

    @Test func theSummaryBeginsOnlyAtPuttingItTogether() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        func step() -> String? { runner.tasks.first { $0.id == id }?.step }
        // Planning, reading and checking dates: no summary is begun, so no
        // cloud preview can show while the card says something else.
        for (seconds, words) in [(0.0, ReconWords.planning), (3, "Reading 4 sources"), (6, ReconWords.checkingDates)] {
            engine.advance(by: seconds)
            #expect(step() == words)
            #expect(runner.held(id)?.begun == false)
            #expect(runner.held(id)?.working == false)
        }
        engine.advance(by: 3)
        #expect(step() == ReconWords.puttingTogether)
        #expect(runner.held(id)?.begun == true)
        #expect(runner.held(id)?.working == true)
    }

    @Test func onAnEngineThatPicksItsOwnStepsItBeginsWhenTheEngineIsDone() throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.libraryTopic))
        #expect(runner.held(id)?.begun == false)
        engine.finish(id)
        #expect(runner.held(id)?.hasSummary == true)
        #expect(runner.summary(for: id) != nil)
    }

    // MARK: Stop keeps nothing

    @Test func stoppingClearsTheSummaryAndWhatWasRead() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.held(id)?.sources == 4)
        // On "Putting it together", the summary on this device is ready at once.
        engine.advance(by: 12)
        #expect(runner.held(id)?.hasSummary == true)
        #expect(runner.stop(id))
        let held = try #require(runner.held(id))
        #expect(!held.hasSummary)
        #expect(held.sources == 0)
        engine.advance(by: 60)
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.summary(for: id) == nil)
    }

    @Test func stoppingBeforeAnyStepKeepsNoSourceText() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.stop(id))
        #expect(runner.held(id)?.sources == 0)
        engine.advance(by: 60)
        #expect(runner.held(id)?.begun == false)
    }

    // MARK: Retry

    /// A recon stopped while its summary was coming, then tried again on an
    /// engine that plays it once more: it puts a new summary together and
    /// ends, rather than sit on "Putting it together" with no way out.
    @Test func retryingAStoppedReconPutsANewSummaryTogether() async throws {
        let engine = ReplayEngine()
        let clock = HandClock(Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { clock.now })
        let gate = Gate()
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        engine.finish(id)
        #expect(runner.held(id)?.working == true)
        #expect(runner.stop(id))
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)

        clock.now = Self.readOn + 3_600
        #expect(runner.retry(id))
        engine.finish(id)
        let shown = try #require(runner.tasks.first { $0.id == id })
        #expect(shown.state == .running)
        #expect(shown.step == ReconWords.puttingTogether)
        #expect(runner.held(id)?.working == true)

        await gate.open()
        await runner.settle(id)
        let task = try #require(runner.tasks.first { $0.id == id })
        #expect(task.state == .done)
        let summary = try #require(runner.summary(for: id))
        // Read again, at the time of the retry, by a second run of the
        // summarizer: the first run was given the earlier time.
        #expect(summary.gatheredAt == clock.now)
        // And it can be cleared away like any ended card.
        #expect(runner.dismiss(id))
    }

    @Test func retryingNeverBringsBackAnOldSummary() throws {
        let engine = ReplayEngine()
        let clock = HandClock(Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { clock.now })
        let id = try #require(runner.lookInto(SampleSources.libraryTopic))
        #expect(runner.stop(id))
        clock.now = Self.readOn + 86_400
        #expect(runner.retry(id))
        #expect(runner.held(id)?.hasSummary == false)
        engine.finish(id)
        #expect(try #require(runner.summary(for: id)).gatheredAt == clock.now)
    }

    @Test func aTaskTheEngineWontRetryStaysAsItWas() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 60)
        let before = runner.summary(for: id)
        #expect(before != nil)
        #expect(!runner.retry(id))
        #expect(runner.summary(for: id) == before)
    }

    // MARK: The engine's cap

    @Test func theCapCancelsASummaryStillWaitingSoNoPreviewOutlivesItsCard() async throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let cancelled = Flag()
        let id = try #require(runner.lookInto(SampleSources.poolTopic,
                                              with: GatedSummarizer(gate: gate, onCancel: cancelled)))
        engine.advance(by: 60)
        #expect(runner.held(id)?.working == true)
        // The engine counts it as ended, so enough newer ended tasks let it go.
        for _ in 0..<LocalFakeEngine.endedLimit {
            runner.start(TaskRequest(title: SampleTasks.planTitle))
            engine.advance(by: 60)
        }
        #expect(!engine.tasks.contains { $0.id == id })
        #expect(!runner.tasks.contains { $0.id == id })
        #expect(runner.held(id) == nil)
        // Its work was cancelled, which is what withdraws a waiting preview.
        await cancelled.wait()
        await gate.open()
        #expect(runner.summary(for: id) == nil)
    }

    // MARK: Examples, per task

    @Test func onlyAReconFromSampleSourcesIsAnExample() throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let real = runner.start(TaskRequest(title: "Book the car service"))
        let recon = try #require(runner.lookInto(SampleSources.libraryTopic))
        #expect(runner.isSample(recon))
        #expect(!runner.isSample(real))
        #expect(!runner.isSample)

        let plain = ReconRunner(engine: ReplayEngine(), provider: DeviceProvider(), now: { Self.readOn })
        let read = try #require(plain.lookInto(SampleSources.libraryTopic))
        #expect(!plain.isSample(read))
    }

    // MARK: A provider that fails

    @Test func aProviderThatFailsSaysSoRatherThanNothingFound() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: FailingProvider())
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.advance(by: 60)
        let task = try #require(runner.tasks.first { $0.id == id })
        #expect(task.state == .failed)
        #expect(task.step == ReconWords.couldNotRead)
        #expect(task.step != ReconWords.nothingFoundLine)
        #expect(task.wrapUp?.notDoneLine == "I didn't read the sources.")
        #expect(runner.summary(for: id) == nil)
        #expect(runner.held(id)?.begun == false)
        #expect(runner.dismiss(id))
    }

    // MARK: Pages

    @Test func sampleSourcesAreNeverFutureDated() {
        for readOn in [Date(), Self.readOn, Date(timeIntervalSinceReferenceDate: 0)] {
            let pages = SampleSources(now: { readOn }).documents
            #expect(pages.allSatisfy { $0.published <= readOn })
            #expect(pages.filter { $0.isOld(at: readOn) }.map(\.id) == ["sample:council-pool"])
        }
    }

    @Test func onlyHttpsPagesCanBeOpened() throws {
        func source(_ address: String) throws -> ReconSource {
            ReconSource(id: "x", title: "T", publisher: "P", url: try #require(URL(string: address)),
                        published: Self.readOn, text: "Words.")
        }
        #expect(try source("https://gazette.example.org/pool").link != nil)
        #expect(try source("HTTPS://gazette.example.org/pool").link != nil)
        for address in ["http://gazette.example.org/pool", "tel:4165550199", "mailto:a@example.org",
                        "someapp://open", "file:///etc/hosts", "javascript:alert(1)"] {
            #expect(try source(address).link == nil, "opens: \(address)")
        }
    }

    @Test func aSummaryNotMadeOnTheDeviceSaysSo() {
        let page = Self.sources.documents[0]
        let summary = ReconSummary(id: "t", topic: "the pool", overview: "Words.",
                                   points: [ReconPoint(id: "a", text: "Retold.", sourceIDs: [page.id])],
                                   sources: [page], gatheredAt: Self.readOn, madeOnDevice: false)
        #expect(summary.note == ReconWords.wordedInCloud)
        let local = ReconSummary(id: "t", topic: "the pool", overview: "Words.",
                                 points: [ReconPoint(id: "a", text: "Said.", sourceIDs: [page.id])],
                                 sources: [page], gatheredAt: Self.readOn, madeOnDevice: true)
        #expect(local.note == nil)
    }

    @Test func aPointOnlyOnOldPagesIsKnownAsOld() throws {
        let summary = try ReconTests.summary(SampleSources.poolTopic)
        let council = try #require(summary.points.first { $0.sourceIDs == ["sample:council-pool"] })
        #expect(summary.restsOnOldPages(council))
        #expect(!summary.points.filter { !$0.sourceIDs.contains("sample:council-pool") }.contains { summary.restsOnOldPages($0) })
    }
}

/// An engine that picks its own steps, with a test moving each task on.
/// Unlike `LocalFakeEngine`, it plays a task again from any end on retry,
/// as a looser engine might.
final class ReplayEngine: TaskEngine, @unchecked Sendable {
    let rule = AskFirst.isolated()
    private let lock = NSLock()
    private var list: [AgentTask] = []
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var sequence = 0
    private var made = 0

    var tasks: [AgentTask] { lock.lock(); defer { lock.unlock() }; return list }

    func start(_ request: TaskRequest) -> String {
        change { () -> String in
            made += 1
            let id = "replay:\(made)"
            list.insert(AgentTask(id: id, title: request.title, step: "Working", startedAt: Date(timeIntervalSince1970: 0)), at: 0)
            return id
        }
    }

    func finish(_ id: String) { set(id, .done) }

    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        let key = UUID()
        lock.lock()
        observers[key] = onChange
        let snapshot = TaskSnapshot(sequence: sequence, tasks: list)
        lock.unlock()
        onChange(snapshot)
        return TaskObservation { [weak self] in
            self?.lock.lock()
            self?.observers[key] = nil
            self?.lock.unlock()
        }
    }

    func redirect(_ id: String, with instructions: String) -> Bool { false }

    func stop(_ id: String) -> Bool {
        guard tasks.first(where: { $0.id == id })?.isActive == true else { return false }
        set(id, .stopped)
        return true
    }

    func dismiss(_ id: String) -> Bool {
        change {
            guard let index = list.firstIndex(where: { $0.id == id }), !list[index].isActive else { return false }
            list.remove(at: index)
            return true
        }
    }

    func clear() -> ClearedTasks {
        change {
            let count = list.count
            list.removeAll()
            return ClearedTasks(forgotten: count)
        }
    }

    func retry(_ id: String) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        set(id, .running)
        return true
    }

    func resume(_ id: String, with approval: Approval) -> TaskApproval { .refused }
    func questionClosed(_ request: ConfirmationRequest) {}
    func refresh() {}

    private func set(_ id: String, _ state: TaskState) {
        change {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].state = state
            list[index].step = state == .done ? "Done" : "Working"
        }
    }

    private func change<T>(_ body: () -> T) -> T {
        lock.lock()
        let value = body()
        sequence += 1
        let snapshot = TaskSnapshot(sequence: sequence, tasks: list)
        let listeners = Array(observers.values)
        lock.unlock()
        for listener in listeners { listener(snapshot) }
        return value
    }
}

/// A clock a test moves by hand.
final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); date = newValue; lock.unlock() }
    }
}

/// Raised once; anyone waiting goes on.
actor Flag {
    private var raised = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func raise() {
        raised = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func wait() async {
        if raised { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// Reads the sample pages, on this device, but not as examples.
struct DeviceProvider: SourceProvider {
    var runsOnDevice: Bool { true }
    func sources(for task: ReconTask) throws -> [ReconSource] {
        try ReconTests.sources.sources(for: task)
    }
}

/// On this device, and can't be read.
struct FailingProvider: SourceProvider {
    struct Unreadable: Error {}
    var runsOnDevice: Bool { true }
    func sources(for task: ReconTask) throws -> [ReconSource] { throw Unreadable() }
}
