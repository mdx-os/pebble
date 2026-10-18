#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// The recon's promises on Today and in the chat: examples said per card,
/// an on-device chat's promise kept, updates landing on the main thread,
/// a clock that moves only while something is live, and the card's words.
@MainActor
struct ReconFeedTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!
    let morning = ShowcaseScene.morning

    func feed(drivesTasks: Bool = false) -> (FeedModel, LocalFakeEngine, ReconRunner) {
        let engine = LocalFakeEngine(rule: .isolated(), origin: morning)
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources)
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: runner,
                              drivesTasks: drivesTasks, place: .onDevice, now: { [morning] in morning })
        return (model, engine, runner)
    }

    // MARK: Examples, per card

    @Test func aRealTaskBesideASampleReconIsNeverCalledAnExample() throws {
        let inner = LocalFakeEngine(rule: .isolated(), origin: morning)
        let runner = ReconRunner(engine: PlainEngine(inner), provider: ReconTestData.sources)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              now: { [morning] in morning })
        let real = runner.start(TaskRequest(title: "Book the car service"))
        #expect(model.lookInto(SampleSources.libraryTopic))
        let recon = try #require(runner.tasks.first { $0.id != real }?.id)
        model.refresh()
        let items = model.feed.working
        let realItem = try #require(items.first { $0.id == real })
        let reconItem = try #require(items.first { $0.id == recon })
        #expect(!model.isSample(realItem))
        #expect(model.isSample(reconItem))
        let card = TaskCard(task: try #require(realItem.task), time: "9:40 AM", isSample: model.isSample(realItem))
        #expect(!card.spoken.contains(FeedWords.exampleMarker))
        // The note at the top still says some of Today is examples.
        #expect(model.isSample)
    }

    // MARK: The chat's offer

    @Test func theOfferSaysTheSourcesAreExamplesWhileTheyAre() {
        let (model, _, _) = feed()
        #expect(model.readsExamples)
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        controller.lookInto = { _, _ in true }
        controller.reconReadsExamples = model.readsExamples
        controller.submit("look into the Riverside pool reopening")
        let line = controller.conversation.turns.last?.text ?? ""
        #expect(line == ReconWords.offer("the Riverside pool reopening", examples: true, place: .onDevice))
        #expect(line.contains("example pages kept on this device"))
        #expect(!ReconWords.offer("the pool").contains("example"))
    }

    @Test func aRealProviderIsNotCalledExamples() {
        let runner = ReconRunner(engine: LocalFakeEngine(rule: .isolated()), provider: RealPages())
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice)
        #expect(!model.readsExamples)
    }

    // MARK: An on-device chat keeps its promise

    @Test func anOnDeviceChatStartsItOnDevice() {
        let starts = Starts()
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        controller.lookInto = { starts.start($0, onDevice: $1) }
        controller.submit("research quiet dishwashers")
        controller.acceptReconOffer()
        #expect(starts.onDevice == [true])
    }

    @Test func withTheCloudTurnedOnSinceAnOnDeviceChatNothingIsSent() throws {
        let maker = TransportMaker()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: nil, transport: { maker.make() })
        let (model, engine, runner) = feed()
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel())) }
        // Asked from a chat that said it stays on this device.
        #expect(model.lookInto(SampleSources.poolTopic, onDevice: true))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == nil)
        #expect(cloud.review.pending == nil)
        #expect(maker.made == 0)
        #expect(maker.transport.sent.isEmpty)
    }

    // MARK: Updates land on the main thread

    @Test(.timeLimit(.minutes(1)))
    func aSummaryFinishedOffTheMainThreadReachesTheFeedOnIt() async throws {
        let (model, engine, runner) = feed()
        let gate = UIGate()
        let mark = ThreadMark()
        model.summarizer = { HeldSummarizer(gate: gate, mark: mark) }
        var heardOnMain: [Bool] = []
        model.announce = { _ in heardOnMain.append(Thread.isMainThread) }
        #expect(model.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        #expect(runner.tasks.first?.state == .running)
        await gate.open()
        await runner.settle(id)
        // The summary was finished, and the runner told its observers, off the main thread.
        #expect(mark.finishedOnMain == false)
        // The feed takes it in on the main thread, once it gets there.
        for await feed in model.$feed.values
            where feed.groups.flatMap(\.items).contains(where: { $0.id == id && $0.task?.state == .done }) {
            break
        }
        #expect(model.summary(for: try #require(runner.tasks.first)) != nil)
        #expect(!heardOnMain.isEmpty)
        #expect(heardOnMain.allSatisfy { $0 })
    }

    // MARK: The clock ticks only while something is live

    @Test func theClockTicksOnlyWhileACardIsLive() {
        let (model, engine, _) = feed(drivesTasks: true)
        #expect(!model.ticks)
        #expect(model.lookInto(SampleSources.libraryTopic))
        #expect(model.ticks)
        engine.advance(by: 30)
        model.refresh()
        #expect(model.feed.working.isEmpty)
        #expect(!model.ticks)
        // A feed that doesn't drive its engine never ticks.
        let (still, _, _) = feed(drivesTasks: false)
        #expect(still.lookInto(SampleSources.libraryTopic))
        #expect(!still.ticks)
    }

    // MARK: Forget everything while the cloud has it

    @Test func forgettingWhileACloudSummaryIsUnderWaySaysItCantBeCalledBack() async throws {
        let (model, engine, runner) = feed()
        let gate = UIGate()
        model.summarizer = { HeldSummarizer(gate: gate, mark: ThreadMark(), leaves: true) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        #expect(runner.summariesMayLeaveDevice == 1)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
        await gate.open()
        #expect(runner.tasks.isEmpty)
    }

    @Test func forgettingAnOnDeviceSummarySaysNothingAboutTheCloud() throws {
        let (model, engine, _) = feed()
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        model.forgetTasks()
        #expect(model.forgotUnderway == nil)
    }

    // MARK: The card's words

    @Test func theCardsHeadingIsTheTitleAndTheOverviewIsReadAsText() throws {
        let summary = try ReconTestData.pool()
        let card = ReconCard(summary: summary, time: "9:40 AM", gathered: "", isSample: true)
        #expect(card.spoken == "\(FeedWords.exampleMarker). \(FeedWords.readyLabel). 9:40 AM")
        #expect(!card.spoken.contains(summary.overview))
    }

    @Test func aPointOnlyOnAnOldPageSaysSoOnItsRow() throws {
        let summary = try ReconTestData.pool()
        let old = try #require(summary.points.first { $0.sourceIDs == ["sample:council-pool"] })
        let row = ReconPointRow(point: old, summary: summary)
        #expect(row.oldLabel == ReconWords.olderLabel)
        #expect(row.spoken.hasSuffix("\(ReconWords.olderLabel)."))
        let fresh = try #require(summary.points.first { $0.disagreement != nil })
        #expect(ReconPointRow(point: fresh, summary: summary).oldLabel == nil)
    }

    @Test func theRememberSheetHasATitle() throws {
        #expect(ReconRememberSheet.title == ReconWords.rememberTitle)
        let (model, _, _) = feed()
        let sheet = ReconRememberSheet(model: model, summary: try ReconTestData.pool())
        #expect(ImageRenderer(content: sheet.frame(width: 393, height: 800)).cgImage != nil)
    }

    @Test func aCloudWordedCardSaysSo() throws {
        let pool = try ReconTestData.pool()
        let cloudy = ReconSummary(id: pool.id, topic: pool.topic, overview: pool.overview, points: pool.points,
                                  sources: pool.sources, gatheredAt: pool.gatheredAt, madeOnDevice: false)
        #expect(cloudy.note == ReconWords.wordedInCloud)
        let card = ReconCard(summary: cloudy, time: "9:40 AM", gathered: "Gathered today at 9:40 AM")
        #expect(ImageRenderer(content: card.frame(width: 393)).cgImage != nil)
    }
}

/// A real engine's stand-in: the scripted engine underneath, but not an
/// example, and not one that plays a recon's own steps.
final class PlainEngine: TaskEngine, @unchecked Sendable {
    let inner: LocalFakeEngine
    init(_ inner: LocalFakeEngine) { self.inner = inner }
    var rule: AskFirst { inner.rule }
    var tasks: [AgentTask] { inner.tasks }
    func start(_ request: TaskRequest) -> String { inner.start(request) }
    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation { inner.observe(onChange) }
    func redirect(_ id: String, with instructions: String) -> Bool { inner.redirect(id, with: instructions) }
    func stop(_ id: String) -> Bool { inner.stop(id) }
    func dismiss(_ id: String) -> Bool { inner.dismiss(id) }
    func clear() -> ClearedTasks { inner.clear() }
    func retry(_ id: String) -> Bool { inner.retry(id) }
    func resume(_ id: String, with approval: Approval) -> TaskApproval { inner.resume(id, with: approval) }
    func questionClosed(_ request: ConfirmationRequest) { inner.questionClosed(request) }
    func refresh() { inner.refresh() }
}

/// Pages on this device that aren't examples.
struct RealPages: SourceProvider {
    var runsOnDevice: Bool { true }
    func sources(for task: ReconTask) throws -> [ReconSource] { [] }
}

/// Holds a summary back until the test lets it go.
actor UIGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Where a summary was finished: on the main thread or not.
final class ThreadMark: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: Bool?
    var finishedOnMain: Bool? { lock.lock(); defer { lock.unlock() }; return onMain }
    func mark() {
        let main = Thread.isMainThread
        lock.lock(); onMain = main; lock.unlock()
    }
}

/// Waits for the gate, then puts the summary together on this device. Says
/// it may leave the device when `leaves`, as a cloud one would.
struct HeldSummarizer: ReconSummarizer {
    let gate: UIGate
    let mark: ThreadMark
    var leaves = false

    var mayLeaveDevice: Bool { leaves }

    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        await gate.wait()
        mark.mark()
        return LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}
#endif
