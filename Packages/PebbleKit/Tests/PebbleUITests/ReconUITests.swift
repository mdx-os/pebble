#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
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

@MainActor
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
        for _ in 0..<500 where controller.isReplying { try await Task.sleep(for: .milliseconds(10)) }
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
        defer { try? memory.forgetEverything() }
        let (model, engine, runner) = feed(memory: memory)
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
        let (model, engine, runner) = feed(memory: nil)
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        #expect(!model.remember(try #require(summary.points.first), in: summary))
        #expect(model.rememberStatus == MemoryWords.couldNotOpen)
    }

    @Test func forgetEverythingTakesEveryReconAndClosesItsSheets() throws {
        let memory = scratchMemory()
        defer { try? memory.forgetEverything() }
        let (model, engine, runner) = feed(memory: memory)
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
        defer { try? notes.forgetEverything() }
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
        var pending: CloudPreview?
        for _ in 0..<500 {
            pending = review.pending
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let preview = try #require(pending)
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
        defer { try? notes.forgetEverything() }
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
        for _ in 0..<500 where review.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(review.pending != nil)
        let task = try #require(runner.tasks.first)
        model.stop(task)
        for _ in 0..<500 where review.pending != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(review.pending == nil)
        await runner.settle(id)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id) == nil)
    }

    /// Turning the cloud off withdraws Today's preview too, unsent, as it
    /// does a chat's: the setting knows Today's gate once it made a model for it.
    @Test func turningTheCloudOffWithdrawsTodaysPreview() async throws {
        let maker = TransportMaker()
        let notes = scratchMemory()
        defer { try? notes.forgetEverything() }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, _, runner) = feed(memory: nil)
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        for _ in 0..<500 where review.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(review.pending != nil)
        _ = cloud.setOn(false)
        for _ in 0..<500 where review.pending != nil { try await Task.sleep(for: .milliseconds(10)) }
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
    func sources(for task: ReconTask) throws -> [ReconSource] {
        try ReconTestData.sources.sources(for: task) + [
            ReconSource(id: "test:club", title: "Swim club news", publisher: "Riverside Swim Club",
                        url: URL(string: "https://swim.example.org/news")!, published: ShowcaseScene.morning - 86_400,
                        text: "Coach Priya runs the Saturday lessons when the pool reopens."),
        ]
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
