#if canImport(SwiftUI)
import Combine
import Foundation
import PebbleCore
import PebbleModel
import ReconTestSupport
import SwiftUI
import Testing
@testable import PebbleUI

/// Counts every start the chat asks for.
@MainActor
final class Starts {
    var topics: [String] = []
    /// Whether each start was asked from a chat that stays on this device.
    var onDevice: [Bool] = []
    var answer = true
    func start(_ topic: String, onDevice: Bool = true) -> Bool {
        topics.append(topic)
        self.onDevice.append(onDevice)
        return answer
    }
}

/// A limit for the whole suite, so an await whose preview or summary never
/// comes fails here rather than hanging CI.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReconUITests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!

    func chat(starts: Starts?) -> ChatController {
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        if let starts { controller.lookInto = { starts.start($0, onDevice: $1) } }
        return controller
    }

    func settle(_ controller: ChatController) async throws {
        await eventually { !controller.isReplying }
        #expect(!controller.isReplying)
    }

    func scratchMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recon-memory-\(UUID().uuidString).json")
        return MemoryStore(fileURL: url)
    }

    // MARK: The offer in the chat

    @Test func theChatOffersAndWaitsForATap() {
        let starts = Starts()
        let controller = chat(starts: starts)
        controller.submit("Can you look into the Riverside pool reopening for me?")
        #expect(controller.reconOffer?.topic == "the Riverside pool reopening")
        #expect(controller.conversation.turns.last?.text == ReconWords.offer("the Riverside pool reopening"))
        #expect(controller.reconOffer?.turnID == controller.conversation.turns.last?.id)
        // Nothing has started, and no model was asked.
        #expect(starts.topics.isEmpty)
        #expect(!controller.isReplying)

        controller.acceptReconOffer()
        #expect(starts.topics == ["the Riverside pool reopening"])
        #expect(controller.reconOffer == nil)
        #expect(controller.conversation.turns.last?.text == ReconWords.started)
        // A second tap can't start it again.
        controller.acceptReconOffer()
        #expect(starts.topics.count == 1)
    }

    @Test func notNowStartsNothing() {
        let starts = Starts()
        let controller = chat(starts: starts)
        controller.submit("research quiet dishwashers")
        #expect(controller.reconOffer != nil)
        controller.declineReconOffer()
        #expect(controller.reconOffer == nil)
        #expect(starts.topics.isEmpty)
        #expect(controller.conversation.turns.last?.text == ReconWords.offerDeclined)
        controller.acceptReconOffer()
        #expect(starts.topics.isEmpty)
    }

    @Test func sayingSomethingElseLetsTheOfferGo() async throws {
        let starts = Starts()
        let controller = chat(starts: starts)
        controller.submit("find out about the library's new Sunday hours")
        #expect(controller.reconOffer != nil)
        controller.submit("Actually, plan my morning")
        #expect(controller.reconOffer == nil)
        try await settle(controller)
        controller.acceptReconOffer()
        #expect(starts.topics.isEmpty)
    }

    @Test func aStartThatCouldntHappenSaysSo() {
        let starts = Starts()
        starts.answer = false
        let controller = chat(starts: starts)
        controller.submit("look into the bus strike")
        controller.acceptReconOffer()
        #expect(controller.conversation.turns.last?.text == ReconWords.couldNotStart)
    }

    @Test func ordinaryMessagesGoToTheModel() async throws {
        let starts = Starts()
        let controller = chat(starts: starts)
        controller.submit("Research shows coffee is fine, right?")
        #expect(controller.reconOffer == nil)
        #expect(controller.isReplying)
        try await settle(controller)
        #expect(controller.conversation.turns.last?.speaker == .agent)
        #expect(controller.conversation.turns.last?.text != ReconWords.offer("shows coffee is fine, right"))
    }

    @Test func aChatThatCantStartOneNeverOffers() async throws {
        let controller = chat(starts: nil)
        controller.submit("look into the Riverside pool reopening")
        #expect(controller.reconOffer == nil)
        try await settle(controller)
    }

    // MARK: Care comes first

    @Test func wordsOfCrisisGetCareAndNoOffer() async throws {
        let starts = Starts()
        let controller = chat(starts: starts)
        controller.submit("look into how to kill myself")
        #expect(controller.reconOffer == nil)
        try await settle(controller)
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
        // While care goes on, a request to look into something is not offered either.
        controller.submit("research the pool for me")
        #expect(controller.reconOffer == nil)
        try await settle(controller)
        #expect(controller.conversation.turns.last?.text == CareCheck.followUp)
        #expect(starts.topics.isEmpty)
    }

    // MARK: The feed

    func feed(memory: MemoryStore?, provider: any SourceProvider = ReconTestData.sources)
        -> (FeedModel, LocalFakeEngine, ReconRunner) {
        let engine = LocalFakeEngine(rule: .isolated(), origin: ShowcaseScene.morning)
        let runner = ReconRunner(engine: engine, provider: provider)
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: runner,
                              place: .onDevice, memory: memory, now: { ShowcaseScene.morning })
        return (model, engine, runner)
    }

    /// Today over an engine and pages that aren't examples, so its points
    /// may be kept. Move it on through the scripted engine underneath.
    func realFeed(memory: MemoryStore?) -> (FeedModel, LocalFakeEngine, ReconRunner) {
        let played = realRecon(at: ShowcaseScene.morning)
        let runner = played.runner
        let engine = (runner.engine as! PlainEngine).inner
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: runner,
                              place: .onDevice, memory: memory, now: { ShowcaseScene.morning })
        return (model, engine, runner)
    }

    @Test func aFeedCardStartsItOnTapAndItLandsBackInTheFeed() throws {
        let (model, engine, runner) = feed(memory: nil)
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        #expect(card.action == .lookInto(SampleSources.poolTopic))
        #expect(runner.tasks.isEmpty)
        var talked: [String] = []
        model.perform(card) { talked.append($0) }
        #expect(talked.isEmpty)
        let task = try #require(runner.tasks.first)
        // Live while it reads, with no Change course.
        #expect(model.feed.working.map(\.id) == [task.id])
        #expect(!model.canRedirect(task))
        engine.advance(by: 4)
        #expect(model.feed.working.first?.task?.step == "Reading 4 sources")
        engine.advance(by: 20)
        #expect(model.feed.working.isEmpty)
        let done = try #require(model.feed.groups.flatMap(\.items).first { $0.id == task.id }?.task)
        let summary = try #require(model.summary(for: done))
        #expect(summary.topic == SampleSources.poolTopic)
        #expect(model.isSample)
    }

    @Test func withoutARunnerTheFeedAsksInTheChat() throws {
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), place: .onDevice)
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        var talked: [String] = []
        model.perform(card) { talked.append($0) }
        #expect(talked == [ReconWords.askLine(SampleSources.poolTopic)])
        #expect(ReconIntent.topic(in: talked[0]) == SampleSources.poolTopic)
    }

    /// A Today that can't start a recon never shows a card promising to:
    /// the card offers to talk about it, which is what its tap does, and
    /// nothing starts. One that can start it keeps Look into it.
    @Test func aCardThatCantStartOneSaysTalkAboutIt() throws {
        func card(_ model: FeedModel) throws -> FeedItem {
            try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        }
        let (able, _, _) = feed(memory: nil)
        #expect(try card(able).action == .lookInto(SampleSources.poolTopic))
        let unableRunners = [ReconRunner(engine: OwnStepsEngine(), provider: ReconTestData.sources),
                             ReconRunner(engine: ReplayEngine(), provider: FarPages())]
        let unable = unableRunners.map {
            FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: $0,
                      place: .onDevice, now: { ShowcaseScene.morning })
        } + [FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), place: .onDevice)]
        for model in unable {
            #expect(!model.canLookInto)
            let item = try card(model)
            #expect(item.action == .talk(ReconWords.askLine(SampleSources.poolTopic)))
            #expect(item.action?.title == FeedWords.talkTitle)
            #expect(item.action?.hint != ReconWords.lookIntoHint)
            // Still an example, and still said to be one.
            #expect(model.isSample(item))
            var talked: [String] = []
            model.perform(item) { talked.append($0) }
            #expect(talked == [ReconWords.askLine(SampleSources.poolTopic)])
            #expect(model.recon?.tasks.isEmpty ?? true)
        }
    }

    /// The cloud setting changing on another thread still withdraws
    /// Today's preview, on the main thread, and nothing is sent.
    @Test(.timeLimit(.minutes(1)))
    func aCloudSettingPublishedOffTheMainThreadIsSafe() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        let settings = PassthroughSubject<CloudHelpSettings, Never>()
        model.follow(cloudSettings: settings.eraseToAnyPublisher())
        settings.send(CloudHelpSettings(isOn: true))
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { review.pending != nil }
        #expect(review.pending != nil)
        // Plain, not tied to the main actor, so a change off it is noted
        // rather than stopping the run.
        let log = ThreadLog()
        let watch = review.objectWillChange.sink { @Sendable _ in log.note() }
        defer { watch.cancel() }
        let sent = Flag()
        // A subject may be sent to from any thread; that is the point here.
        nonisolated(unsafe) let offThread = settings
        DispatchQueue.global().async {
            offThread.send(CloudHelpSettings(isOn: false))
            Task { await sent.raise() }
        }
        await sent.wait()
        await eventually { review.pending == nil }
        #expect(review.pending == nil)
        await runner.settle(id)
        #expect(maker.wire.sent.isEmpty)
        // The withdraw was published, and only ever on the main thread.
        #expect(!log.onMain.isEmpty)
        #expect(log.onMain.allSatisfy { $0 })
    }

    /// On the main thread the change withdraws Today's preview in the same
    /// turn, so a Send tapped straight after, with nothing awaited between,
    /// sends nothing. A hop to a later turn would let that Send go.
    @Test func aCloudSettingOnTheMainThreadWithdrawsBeforeALateSend() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        let settings = PassthroughSubject<CloudHelpSettings, Never>()
        model.follow(cloudSettings: settings.eraseToAnyPublisher())
        settings.send(CloudHelpSettings(isOn: true))
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { review.pending != nil }
        let preview = try #require(review.pending)
        // All three in one turn.
        settings.send(CloudHelpSettings(isOn: false))
        #expect(review.pending == nil)
        review.answer(.send, for: preview.id)
        await runner.settleEverything()
        runner.advance(by: 30)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    /// The path a person takes: Today's cloud preview is up, and Forget
    /// everything is tapped on the memory screen the home screen made. With
    /// the real cloud summarizer and Today's own gate, the preview goes at
    /// once, and a Send tapped late on it sends nothing.
    @Test func forgetEverythingFromTheMemoryScreenWithdrawsTodaysPreview() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, engine, runner) = feed(memory: notes)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 12)
        await eventually { review.pending != nil }
        let preview = try #require(review.pending)

        let screen = HomeView.memoryModel(store: notes, place: .mayLeaveDevice, cloud: cloud, feed: model)
        screen.forgetEverything()
        // Gone with its sheet, not on a later turn.
        #expect(review.pending == nil)
        review.answer(.send, for: preview.id)
        await runner.settleEverything()
        engine.advance(by: 60)
        model.refresh()
        #expect(maker.wire.sent.isEmpty)
        #expect(review.pending == nil)
        #expect(runner.tasks.isEmpty)
        #expect(runner.summary(for: id) == nil)
        #expect(runner.summariesMayLeaveDevice == 0)
    }

    @Test func aFollowUpOpensTheChatWithAQuestionReady() throws {
        let (model, engine, runner) = feed(memory: nil)
        let id = try #require(model.lookInto(SampleSources.libraryTopic) ? runner.tasks.first?.id : nil)
        engine.advance(by: 30)
        let summary = try #require(runner.summary(for: id))
        var talked: [String] = []
        model.followUp(summary) { talked.append($0) }
        #expect(talked == ["Tell me more about the library's new Sunday hours."])
        // The follow-up is a question, not another request to look into it.
        #expect(ReconIntent.topic(in: talked[0]) == nil)
    }

    @Test func aPointIsRememberedOnlyOnTap() throws {
        let memory = scratchMemory()
        defer { discard(memory) }
        let (model, engine, runner) = realFeed(memory: memory)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        // Finishing, opening the sources and opening the choice save nothing.
        model.readingSources = summary
        model.choosingPoint = summary
        model.refresh()
        #expect(memory.notes().isEmpty)

        let point = try #require(summary.points.first)
        #expect(model.remember(point, in: summary))
        #expect(model.rememberStatus == MemoryWords.saved(.onDevice))
        #expect(model.isRemembered(point, in: summary))
        let notes = memory.notes()
        #expect(notes.count == 1)
        #expect(notes.first?.text == summary.note(for: point))
        #expect(notes.first?.source == .lookedUp("City of Riverside Parks"))
        // Tapping again doesn't keep it twice.
        #expect(!model.remember(point, in: summary))
        #expect(memory.notes().count == 1)
        #expect(!summary.points.dropFirst().contains { model.isRemembered($0, in: summary) })
    }

    @Test func rememberingWithNoMemorySaysSoKindly() throws {
        let (model, engine, runner) = realFeed(memory: nil)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        #expect(!model.remember(try #require(summary.points.first), in: summary))
        #expect(model.rememberStatus == MemoryWords.couldNotOpen)
    }

    @Test func forgetEverythingTakesEveryReconAndClosesItsSheets() throws {
        let memory = scratchMemory()
        defer { discard(memory) }
        let (model, engine, runner) = realFeed(memory: memory)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        #expect(model.remember(try #require(summary.points.first), in: summary))
        model.readingSources = summary
        model.choosingPoint = summary

        let cleared = model.forgetTasks()
        #expect(cleared.forgotten == 1)
        #expect(cleared.underway == 0)
        #expect(model.forgotUnderway == nil)
        #expect(model.tasksForgotten)
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
        #expect(model.readingSources == nil)
        #expect(model.choosingPoint == nil)
        #expect(model.rememberStatus == nil)
        #expect(!summary.points.contains { model.isRemembered($0, in: summary) })
        #expect(model.feed.working.isEmpty)
        #expect(!model.feed.groups.flatMap(\.items).contains { $0.id == id })
    }

    /// What forgetting does to a kept point: it is the person's own note,
    /// so it stays when the card goes and when every task is forgotten, as
    /// the remember sheet and the forget question both say. Forget
    /// everything, which erases the notes, takes it too.
    @Test func aKeptPointStaysInTheNotesUntilTheyAreForgotten() throws {
        let memory = scratchMemory()
        defer { discard(memory) }
        let (model, engine, runner) = realFeed(memory: memory)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        let point = try #require(summary.points.first)
        #expect(model.remember(point, in: summary))
        model.forgetTasks()
        #expect(runner.tasks.isEmpty)
        #expect(memory.notes().map(\.text) == [summary.note(for: point)])
        // The words promise exactly that.
        for place in [PrivacyPlace.onDevice, .mayLeaveDevice] {
            #expect(ReconWords.rememberDetail(place).contains("It's still there after this card goes, until you delete it or forget everything."))
        }
        #expect(TaskWords.forgetTasksDetail.contains("Your notes aren't touched."))
    }

    /// Forget everything, through the memory screen's model as the home
    /// screen makes it, with a kept point in the notes and a recon still
    /// putting a summary together in the cloud: the notes are empty, every
    /// task is gone, and nothing is left that may leave the device.
    @Test(.timeLimit(.minutes(1)))
    func forgetEverythingErasesAKeptPointAndStopsARunningRecon() async throws {
        let memory = scratchMemory()
        defer { discard(memory) }
        let (model, engine, runner) = realFeed(memory: memory)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        #expect(model.remember(try #require(summary.points.first), in: summary))
        #expect(memory.notes().count == 1)
        // A second recon, its summary held in the cloud's hands.
        let gate = Gate()
        model.summarizer = { HeldSummarizer(gate: gate, mark: ThreadMark(), leaves: true) }
        #expect(model.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 30)
        let running = try #require(runner.tasks.first { $0.isActive }?.id)
        #expect(runner.summariesMayLeaveDevice == 1)

        let screen = HomeView.memoryModel(store: memory, place: .onDevice, cloud: nil, feed: model)
        screen.forgetEverything()
        #expect(memory.notes().isEmpty)
        #expect(runner.tasks.isEmpty)
        #expect(runner.summariesMayLeaveDevice == 0)
        #expect(!runner.isRecon(running))
        // The held summary comes in late, and nothing keeps it. Its work
        // has returned before anything is checked.
        await gate.open()
        await runner.settleEverything()
        #expect(runner.tasks.isEmpty)
        #expect(runner.summary(for: running) == nil)
        #expect(memory.notes().isEmpty)
    }

    @Test func dismissingAReadyCardClosesItsSheets() throws {
        let (model, engine, runner) = feed(memory: nil)
        #expect(model.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 30)
        let task = try #require(runner.tasks.first)
        let summary = try #require(model.summary(for: task))
        model.readingSources = summary
        model.dismiss(task)
        #expect(model.readingSources == nil)
        #expect(runner.tasks.isEmpty)
        #expect(!model.hasTasks)
    }

    @Test func aReadyCardFromExamplesSaysSoAndCanBeDismissed() throws {
        let summary = try ReconTestData.pool()
        let card = ReconCard(summary: summary, time: "9:40 AM", gathered: "", isSample: true)
        #expect(card.spoken.hasPrefix(FeedWords.exampleMarker))
        #expect(card.actions.last == .dismiss)
        #expect(!ReconCard(summary: summary, time: "9:40 AM", gathered: "").spoken.hasPrefix(FeedWords.exampleMarker))
    }

    // MARK: Cloud off and on

    @Test func withTheCloudOffNothingLeavesTheDevice() async throws {
        let maker = TransportMaker()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(.off), endpoint: endpoint, memory: nil,
                              transport: { maker.make() })
        let (model, engine, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        await runner.settle(id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == nil)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(review.pending == nil)
    }

    @Test func withTheCloudOnThePersonSeesItFirstAndCanKeepItHere() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        _ = try notes.remember("Coach Priya teaches the Saturday lessons.", source: .toldMe)
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, engine, runner) = feed(memory: nil, provider: PagesNamingSomeone())
        // Today's own gate, as the home screen wires it.
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        // The card stays live while the question waits.
        #expect(runner.tasks.first?.state == .running)
        #expect(runner.tasks.first?.step == ReconWords.puttingTogether)
        await eventually { review.pending != nil }
        let preview = try #require(review.pending)
        #expect(preview.request.text.contains("Riverside Pool reopens on November 10"))
        // A page names someone in the person's notes. The name is masked on
        // its way through Today too.
        #expect(!preview.request.text.contains("Priya"))
        #expect(preview.request.text.contains("[name]"))
        #expect(maker.wire.sent.isEmpty)
        review.answer(.cancel, for: preview.id)
        await runner.settle(id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.declinedCloud)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func stoppingWhileThePreviewWaitsSendsNothing() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        // The preview comes only once the card says it is putting it together.
        #expect(review.pending == nil)
        runner.advance(by: 12)
        #expect(runner.tasks.first?.step == ReconWords.puttingTogether)
        await eventually { review.pending != nil }
        #expect(review.pending != nil)
        let task = try #require(runner.tasks.first)
        model.stop(task)
        await eventually { review.pending == nil }
        #expect(review.pending == nil)
        await runner.settle(id)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id) == nil)
    }

    /// Send, then Stop while the request is on its way. The reply still
    /// comes back, and the summary is dropped all the same: the card says
    /// stopped and keeps nothing.
    @Test(.timeLimit(.minutes(1)))
    func stoppingWhileTheSendIsOnItsWayKeepsNothing() async throws {
        let wire = HeldWire(reply: """
            POINT: The pool reopens on November 10. [2]
            POINT: Family swim is on Saturdays. [2]
            """)
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { URLSessionCloudTransport(load: wire.load) })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { review.pending != nil }
        let preview = try #require(review.pending)
        review.answer(.send, for: preview.id)
        await eventually { wire.sentCount == 1 }
        #expect(wire.sentCount == 1)
        // On its way: Stop.
        model.stop(try #require(runner.tasks.first))
        #expect(runner.tasks.first?.state == .stopped)
        await wire.gate.open()
        // Waits for the summary's work itself to return, reply parsed and
        // all, not for a guessed time.
        await runner.settleEverything()
        #expect(wire.answered)
        runner.advance(by: 30)
        model.refresh()
        #expect(wire.sentCount == 1)
        #expect(runner.summary(for: id) == nil)
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(model.feed.groups.flatMap(\.items).first { $0.id == id }?.task?.state == .stopped)
        #expect(model.summary(for: try #require(runner.tasks.first)) == nil)
    }

    /// The control: the same send, with no Stop, lands as a summary worded
    /// in the cloud. So the test above drops it because of Stop.
    @Test(.timeLimit(.minutes(1)))
    func theSameSendLandsWhenNothingIsStopped() async throws {
        let wire = HeldWire(reply: """
            POINT: The pool reopens on November 10. [2]
            POINT: Family swim is on Saturdays. [2]
            """)
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { URLSessionCloudTransport(load: wire.load) })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { review.pending != nil }
        review.answer(.send, for: try #require(review.pending).id)
        await eventually { wire.sentCount == 1 }
        await wire.gate.open()
        await runner.settle(id)
        runner.advance(by: 30)
        let summary = try #require(runner.summary(for: id))
        #expect(!summary.madeOnDevice)
        #expect(summary.note == ReconWords.wordedInCloud)
    }

    /// Turning the cloud off withdraws Today's preview too, unsent, as it
    /// does a chat's: the setting knows Today's gate once it made a model for it.
    @Test func turningTheCloudOffWithdrawsTodaysPreview() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { review.pending != nil }
        #expect(review.pending != nil)
        _ = cloud.setOn(false)
        await eventually { review.pending == nil }
        #expect(review.pending == nil)
        await runner.settle(id)
        runner.advance(by: 30)
        #expect(maker.wire.sent.isEmpty)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        // The person didn't decline it, so the card doesn't say they did.
        #expect(summary.note == ReconWords.cloudWithdrawn)
    }

    // MARK: Rendering

    @Test(arguments: [ColorScheme.light, .dark], [CGFloat(393), 1024])
    func theReadyCardRenders(scheme: ColorScheme, width: CGFloat) throws {
        let summary = try ReconTestData.pool()
        let card = ReconCard(summary: summary, time: "9:40 AM", gathered: ReconWords.gathered(summary.gatheredAt, now: summary.gatheredAt))
            .environment(\.colorScheme, scheme)
            .frame(width: width)
        let image = try #require(ImageRenderer(content: card).cgImage)
        #expect(image.width > 0)
    }

    @Test func theReadyCardOffersRememberOnlyWithPoints() throws {
        let summary = try ReconTestData.pool()
        #expect(ReconCard(summary: summary, time: "", gathered: "").actions == [.sources, .followUp, .remember, .dismiss])
        let empty = ReconSummary(id: "t", topic: "volcanoes", overview: ReconWords.nothingFound("volcanoes"),
                                 points: [], sources: [], gatheredAt: summary.gatheredAt, madeOnDevice: true)
        #expect(ReconCard(summary: empty, time: "", gathered: "").actions == [.followUp, .dismiss])
    }

    @Test func voiceOverHearsWhoSaidEachPoint() throws {
        let summary = try ReconTestData.pool()
        let point = try #require(summary.points.first { $0.disagreement != nil })
        let spoken = ReconPointRow(point: point, summary: summary).spoken
        #expect(spoken.hasPrefix(point.text))
        #expect(spoken.contains("Sources don't agree on this."))
        // Only the page that says the point is named as its source. The
        // Gazette, which says otherwise, is heard in the disagreement.
        #expect(spoken.hasSuffix("From City of Riverside Parks."))
        #expect(point.disagreement?.text.contains("Riverside Gazette says November 3.") == true)
    }

    @Test func aReconCardHidesChangeCourse() throws {
        let (model, _, runner) = feed(memory: nil)
        #expect(model.lookInto(SampleSources.poolTopic))
        let task = try #require(runner.tasks.first)
        let card = TaskCard(task: task, time: "", canRedirect: model.canRedirect(task))
        #expect(card.actions == [.stop])
    }
}

/// The sample pages, with one more that names someone from the person's notes.
struct PagesNamingSomeone: SourceProvider {
    var runsOnDevice: Bool { true }
    /// Said outright, so a change to the protocol's default can't make it one.
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] {
        try ReconTestData.sources.sources(for: task) + [
            ReconSource(id: "test:club", title: "Swim club news", publisher: "Riverside Swim Club",
                        url: URL(string: "https://swim.example.org/news")!, published: ShowcaseScene.morning - 86_400,
                        text: "Coach Priya runs the Saturday lessons when the pool reopens."),
        ]
    }
}

/// Stands in for URLSession: records each request, then holds the answer
/// back until the test opens the gate, so a test can act while a send is
/// on its way. Never touches the network.
final class HeldWire: @unchecked Sendable {
    let gate = Gate()
    private let reply: String
    private let lock = NSLock()
    private var sent = 0
    private var done = false

    init(reply: String) { self.reply = reply }

    var sentCount: Int { lock.withLock { sent } }
    /// The wire has answered. Set as the reply leaves `load`, so the caller
    /// may not have it in hand yet; wait on the work itself for that.
    var answered: Bool { lock.withLock { done } }

    @Sendable func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { sent += 1 }
        await gate.wait()
        defer { lock.withLock { done = true } }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (try JSONEncoder().encode(["reply": reply]), response)
    }
}

enum ReconTestData {
    /// The sample pages, read at the showcase's morning.
    static let sources = SampleSources(now: { ShowcaseScene.morning })

    static func pool() throws -> ReconSummary {
        let task = try #require(ReconTask(topic: SampleSources.poolTopic))
        return LocalReconSummarizer().summary(task, id: "task:1", sources: try sources.sources(for: task),
                                              gatheredAt: ShowcaseScene.morning)
    }
}
#endif
