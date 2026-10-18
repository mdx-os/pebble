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
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        // Asked from a chat that said it stays on this device.
        #expect(model.lookInto(SampleSources.poolTopic, onDevice: true))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == nil)
        #expect(review.pending == nil)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: The home screen's wiring

    /// Today, as the home screen makes it, asks the cloud through its own
    /// gate, never a chat's, and its first chat can offer to look into things.
    @Test func theHomeScreensTodayAsksThroughItsOwnGate() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: ReconTestData.sources, place: .mayLeaveDevice,
                                            memory: notes, model: LocalStubModel(), cloud: cloud, now: { [morning] in morning })
        #expect(model.summarizer().mayLeaveDevice)
        let chat = HomeView.wired(HomeView.newChat(brand: brand, model: LocalStubModel(),
                                                   names: InMemoryAgentNameStore(stored: "Pip"), cloud: cloud,
                                                   conversation: nil), to: model)
        #expect(chat.lookInto != nil)
        #expect(chat.reconReadsExamples == model.readsExamples)
        chat.submit("look into the Riverside pool reopening")
        chat.acceptReconOffer()
        let runner = try #require(model.recon)
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        for _ in 0..<500 where model.cloudReview.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.cloudReview.pending != nil)
        #expect(chat.review?.pending == nil)
        // The screen going away withdraws it, as the home screen does.
        model.cloudReview.cancelPending()
        await runner.settle(id)
        runner.advance(by: 30)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    /// Two previews waiting at once: the first to come shows, the other
    /// waits. One alone never waits.
    @Test func onlyOnePreviewShowsAtATime() {
        #expect(!PreviewTurn(chatPending: true, todayPending: false, todayFirst: false).chatWaits)
        #expect(!PreviewTurn(chatPending: false, todayPending: true, todayFirst: true).todayWaits)
        #expect(!PreviewTurn(chatPending: false, todayPending: true, todayFirst: false).todayWaits)
        for todayFirst in [true, false] {
            let both = PreviewTurn(chatPending: true, todayPending: true, todayFirst: todayFirst)
            #expect(both.chatWaits != both.todayWaits)
            #expect(both.todayWaits == !todayFirst)
        }
    }

    /// The chat's preview shows, Today's waits; the chat's closes, so
    /// Today's shows; then a new chat preview comes. Today's stays on
    /// screen and the new one waits for it.
    @Test func aPreviewOnScreenIsNeverSwappedOut() {
        var turn = PreviewTurn(chatPending: false, todayPending: false, todayFirst: false)
        turn.chatChanged(to: true)
        turn.todayChanged(to: true)
        #expect(turn.todayWaits)
        #expect(!turn.chatWaits)
        turn.chatChanged(to: false)
        #expect(!turn.todayWaits)
        turn.chatChanged(to: true)
        #expect(!turn.todayWaits)
        #expect(turn.chatWaits)
        // Once Today's closes, the chat's shows.
        turn.todayChanged(to: false)
        #expect(!turn.chatWaits)
        #expect(!turn.todayWaits)
    }

    /// A chat's preview and Today's both waiting at once: nothing goes
    /// while they wait, and turning the cloud off withdraws both.
    @Test func turningTheCloudOffWithdrawsBothPreviewsWaitingAtOnce() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, engine, runner) = feed()
        let today = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: today)) }
        let chat = HomeView.newChat(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                                    cloud: cloud, conversation: nil)
        let chatReview = try #require(chat.review)
        chat.send("Help me plan Saturday.")
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 30)
        for _ in 0..<500 where chatReview.pending == nil || today.pending == nil {
            #expect(maker.wire.sent.isEmpty)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatReview.pending != nil)
        #expect(today.pending != nil)
        #expect(maker.wire.sent.isEmpty)
        _ = cloud.setOn(false)
        for _ in 0..<500 where chatReview.pending != nil || today.pending != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chatReview.pending == nil)
        #expect(today.pending == nil)
        await runner.settle(id)
        for _ in 0..<500 where chat.isReplying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    /// A recon tried again with the cloud on asks again, with a fresh
    /// preview. A Send given to an earlier preview is never used for it.
    @Test func aRetryWithTheCloudOnAsksAgain() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let engine = HandEngine()
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources, now: { [morning] in morning })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .mayLeaveDevice,
                              now: { [morning] in morning })
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.finish(id)
        let first = await review.shown()
        review.answer(.send, for: first.id)
        await runner.settle(id)
        #expect(maker.wire.sent.count == 1)
        #expect(runner.summary(for: id) != nil)

        #expect(runner.retry(id))
        engine.finish(id)
        for _ in 0..<500 where review.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = try #require(review.pending)
        #expect(second.id != first.id)
        // The earlier Send, given again, does nothing.
        review.answer(.send, for: first.id)
        #expect(review.pending?.id == second.id)
        #expect(maker.wire.sent.count == 1)
        review.answer(.cancel, for: second.id)
        await runner.settle(id)
        #expect(maker.wire.sent.count == 1)
        #expect(runner.summary(for: id)?.note == ReconWords.declinedCloud)
    }

    // MARK: Today's follow-up only drafts

    /// What `onTalk` does with a follow-up: the question waits in the
    /// composer, so the hint "Nothing is sent." is true.
    @Test func aFollowUpIsDraftedAndNeverSent() throws {
        let (model, engine, runner) = feed()
        #expect(model.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        let chat = ChatController.make(brand: brand, model: LocalStubModel(),
                                       names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        let before = chat.conversation.turns
        model.followUp(summary) { HomeView.draft($0, in: chat) }
        #expect(chat.draft == ReconWords.followUpDraft(summary.topic))
        #expect(chat.conversation.turns == before)
        #expect(!chat.isReplying)
        #expect(chat.sentCount == 0)
        #expect(ReconWords.followUpHint.contains("Nothing is sent."))
        // Words the person had typed are kept.
        chat.draft = "My own words"
        model.followUp(summary) { HomeView.draft($0, in: chat) }
        #expect(chat.draft == "My own words")
    }

    // MARK: Taps and repeats

    @Test func tappingThePoolCardAgainStartsNoSecondRecon() throws {
        let (model, engine, runner) = feed()
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        var talked: [String] = []
        for _ in 0..<3 { model.perform(card) { talked.append($0) } }
        #expect(runner.tasks.count == 1)
        engine.advance(by: 30)
        model.perform(card) { talked.append($0) }
        #expect(runner.tasks.count == 1)
        #expect(talked.isEmpty)
        // Once stopped, it can be asked for again.
        let (again, _, other) = feed()
        again.perform(card) { _ in }
        again.stop(try #require(other.tasks.first))
        again.perform(card) { _ in }
        #expect(other.tasks.count == 2)
    }

    @Test func aSecondSavedInARowIsSaidToo() throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { try? memory.forgetEverything() }
        let engine = LocalFakeEngine(rule: .isolated(), origin: morning)
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        let told = model.rememberTold
        #expect(model.remember(summary.points[0], in: summary))
        let first = model.rememberStatus
        #expect(model.remember(summary.points[1], in: summary))
        #expect(model.rememberStatus == first)
        #expect(model.rememberTold == told + 2)
    }

    /// Drawing the feed asks the runner for a card's summary once per
    /// snapshot, however many times the card is drawn.
    @Test func aCardsSummaryIsAskedForOncePerSnapshot() throws {
        let inner = LocalFakeEngine(rule: .isolated(), origin: morning)
        let engine = PlainEngine(inner)
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              now: { [morning] in morning })
        #expect(model.lookInto(SampleSources.libraryTopic))
        inner.advance(by: 30)
        let task = try #require(runner.tasks.first)
        let before = engine.reads
        for _ in 0..<10 { #expect(model.summary(for: task) != nil) }
        #expect(engine.reads - before <= 1)
        // A new snapshot asks again, so a dismissed card has no summary.
        model.dismiss(task)
        #expect(model.summary(for: task) == nil)
    }

    @Test func aDisagreementStandingAloneIsSaidOnce() throws {
        let pool = try ReconTestData.pool()
        let ids = pool.sources.prefix(2).map(\.id)
        let words = "The sources give different dates."
        let alone = ReconPoint(id: "point:9", text: words, sourceIDs: ids,
                               disagreement: ReconDisagreement(text: words, sourceIDs: ids))
        let row = ReconPointRow(point: alone, summary: pool)
        #expect(row.standsAlone)
        #expect(row.pointLine == nil)
        #expect(row.spoken.components(separatedBy: words).count == 2)
        let carried = try #require(pool.points.first { $0.disagreement != nil })
        #expect(ReconPointRow(point: carried, summary: pool).pointLine == carried.text)
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
        let mark = ThreadMark()
        model.summarizer = { HeldSummarizer(gate: gate, mark: mark, leaves: true) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        #expect(runner.summariesMayLeaveDevice == 1)
        let id = try #require(runner.tasks.first?.id)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
        await gate.open()
        // The summary is still put together, late, and nothing keeps it.
        for _ in 0..<500 where mark.finishedOnMain == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(mark.finishedOnMain != nil)
        try await Task.sleep(for: .milliseconds(50))
        model.refresh()
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
        #expect(runner.summary(for: id) == nil)
        #expect(runner.summariesMayLeaveDevice == 0)
        #expect(!model.feed.groups.flatMap(\.items).contains { $0.id == id })
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
/// example.
final class PlainEngine: ScriptedTaskEngine, @unchecked Sendable {
    let inner: LocalFakeEngine
    private let lock = NSLock()
    private var count = 0
    init(_ inner: LocalFakeEngine) { self.inner = inner }
    /// How many times its tasks were asked for.
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    var rule: AskFirst { inner.rule }
    var tasks: [AgentTask] {
        lock.lock(); count += 1; lock.unlock()
        return inner.tasks
    }
    func start(_ request: TaskRequest) -> String { inner.start(request) }
    func start(_ script: TaskScript) -> String { inner.start(script) }
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

/// A scripted engine that shows none of a script's steps, moved on by the
/// test, and that plays a task again from any end on retry.
final class HandEngine: ScriptedTaskEngine, @unchecked Sendable {
    let rule = AskFirst.isolated()
    private let lock = NSLock()
    private var list: [AgentTask] = []
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var sequence = 0

    var tasks: [AgentTask] { lock.lock(); defer { lock.unlock() }; return list }

    func start(_ script: TaskScript) -> String { start(TaskRequest(title: script.title)) }

    func start(_ request: TaskRequest) -> String {
        change { () -> String in
            let id = "hand:\(list.count + 1)"
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
