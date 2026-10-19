#if canImport(SwiftUI)
import Combine
import Foundation
import PebbleCore
import PebbleModel
import ReconTestSupport
import SourceScan
import SwiftUI
import Testing
@testable import PebbleUI

/// The recon's promises on Today and in the chat: examples said per card,
/// an on-device chat's promise kept, updates landing on the main thread,
/// a clock that moves only while something is live, and the card's words.
/// A limit for the whole suite, so an await that never ends fails rather
/// than hanging CI.
@MainActor
@Suite(.timeLimit(.minutes(1)))
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
        controller.lookInto = { _, _ in .started }
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
        controller.lookInto = { starts.start($0, place: $1) }
        controller.submit("research quiet dishwashers")
        controller.acceptReconOffer()
        #expect(starts.onDevice == [true])
    }

    @Test func withTheCloudTurnedOnSinceAnOnDeviceChatNothingIsSent() throws {
        let maker = TransportMaker()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: nil, transport: { maker.make() })
        let (model, engine, runner) = feed()
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        // Asked from a chat that said it stays on this device.
        #expect(model.lookInto(SampleSources.poolTopic, place: .onDevice))
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
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: ReconTestData.sources, place: .mayLeaveDevice,
                                            memory: notes, model: LocalStubModel(), cloud: cloud, now: { [morning] in morning })
        #expect(model.summarizer().mayUseCloud)
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
        await eventually { model.cloudReview.pending != nil }
        #expect(model.cloudReview.pending != nil)
        #expect(chat.review?.pending == nil)
        // The screen going away withdraws it, as the home screen does.
        model.cloudReview.cancelPending()
        await runner.settle(id)
        runner.advance(by: 30)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    /// Today as the home screen makes it, with no engine given, sits quiet
    /// for a while, so its scripted clock isn't moved. A recon started then
    /// says it was gathered at the wall time, today, and its card's time is
    /// the wall time too, not when the screen was made.
    @Test func aReconAfterAQuietSpellSaysWhenItWasReallyGathered() throws {
        let wall = HandClock(morning)
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: ReconTestData.sources, place: .onDevice,
                                            memory: nil, model: LocalStubModel(), cloud: nil, now: { wall.now })
        let runner = try #require(model.recon)
        // Ninety minutes with nothing live, so nothing ticks.
        #expect(!model.ticks)
        wall.now = morning + 90 * 60
        let started = wall.now
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        #expect(runner.tasks.first?.startedAt == started)
        // Played to its end the way the screen plays it, a second at a time.
        for _ in 0..<30 {
            wall.now += 1
            model.tick(1)
        }
        let summary = try #require(runner.summary(for: id))
        #expect(summary.gatheredAt == started)
        let line = ReconWords.gathered(summary.gatheredAt, now: wall.now)
        #expect(line == "Gathered today at \(started.formatted(date: .omitted, time: .shortened))")
        let card = try #require(runner.tasks.first { $0.id == id })
        #expect(card.updatedAt >= started)
        #expect(card.updatedAt <= wall.now)
    }

    /// The home screen reads only from a provider on this device, the
    /// promise an on-device chat makes for the topic it asks for. One that
    /// would read elsewhere is never used, so Today and the chat never offer.
    @Test func theHomeScreenReadsOnlyOnThisDevice() throws {
        let clock: @Sendable () -> Date = { [morning] in morning }
        let refused = HomeView.reconSources(FarPages(), now: clock)
        #expect(!(refused is FarPages))
        #expect(!refused.runsOnDevice)
        #expect(try refused.sources(for: try #require(ReconTask(topic: SampleSources.poolTopic))).isEmpty)
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: refused, place: .onDevice,
                                            memory: nil, model: LocalStubModel(), cloud: nil, now: clock)
        #expect(!model.canLookInto)
        let chat = HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(),
                                                      names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil),
                                  to: model)
        #expect(chat.lookInto == nil)
        // A provider on this device, examples or not, is used as given.
        #expect(HomeView.reconSources(RealPages(), now: clock) is RealPages)
        #expect(HomeView.reconSources(ReconTestData.sources, now: clock) is SampleSources)
    }

    /// With none given, the sample pages are dated by the screen's own
    /// clock, the one the time they were gathered is read from, so a page
    /// never reads as newer, or older, than it is when the showcase holds
    /// its clock still.
    @Test func theSamplePagesShareTheScreensClock() throws {
        let still = morning - 3 * 86_400
        let pages = try #require(HomeView.reconSources(nil, now: { still }) as? SampleSources)
        #expect(pages.now() == still)
        let gazette = try #require(pages.documents.first { $0.id == "sample:gazette-pool" })
        #expect(gazette.published == still - 7 * 86_400)
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: pages, place: .onDevice, memory: nil,
                                            model: LocalStubModel(), cloud: nil, now: { still })
        let runner = try #require(model.recon)
        #expect(model.lookInto(SampleSources.poolTopic))
        model.tick(30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        #expect(summary.gatheredAt == still)
        #expect(summary.sources.allSatisfy { $0.published < still })
        #expect(summary.oldSources.map(\.id) == ["sample:council-pool"])
    }

    /// The chat's Look into it checks Today first. A topic already going
    /// there, in any case of letters, starts nothing more and says so.
    @Test func theChatNeverStartsATopicTodayIsAlreadyOn() throws {
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: ReconTestData.sources,
                                            place: .onDevice, memory: nil, model: LocalStubModel(), cloud: nil,
                                            now: { [morning] in morning })
        let runner = try #require(model.recon)
        // From the card, in lower case.
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        model.perform(card) { _ in }
        #expect(runner.tasks.count == 1)
        let chat = HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(),
                                                      names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil,
                                                      replyBeat: .zero), to: model)
        chat.submit("Look into The Riverside Pool Reopening")
        #expect(chat.reconOffer != nil)
        chat.acceptReconOffer()
        #expect(runner.tasks.count == 1)
        #expect(chat.conversation.turns.last?.text == ReconWords.alreadyOn)
        #expect(ChatView.replyLanded(in: chat, covered: false) == ReconWords.alreadyOn)
        // A new topic still starts.
        chat.submit("look into the library's new Sunday hours")
        chat.acceptReconOffer()
        #expect(runner.tasks.count == 2)
        #expect(chat.conversation.turns.last?.text == ReconWords.started)
        // Once it is ready, it isn't something I'm "on": the line says it's ready.
        model.tick(60)
        #expect(runner.tasks.allSatisfy { $0.state == .done })
        chat.submit("look into the Riverside pool reopening")
        chat.acceptReconOffer()
        #expect(runner.tasks.count == 2)
        #expect(chat.conversation.turns.last?.text == ReconWords.alreadyReady)
    }

    /// Forget everything takes a chat's offer away, so a tap after it can
    /// never start a recon on a topic from before.
    @Test func forgetEverythingTakesTheChatsOffer() throws {
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: ReconTestData.sources,
                                            place: .onDevice, memory: nil, model: LocalStubModel(), cloud: nil,
                                            now: { [morning] in morning })
        let runner = try #require(model.recon)
        let chat = HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(),
                                                      names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil,
                                                      replyBeat: .zero), to: model)
        chat.submit("Look into the Riverside pool reopening")
        #expect(chat.reconOffer != nil)
        model.forgetEverything()
        #expect(chat.reconOffer == nil)
        chat.acceptReconOffer()
        #expect(runner.tasks.isEmpty)
    }

    /// With the cloud on, Today's recon may be put into words there. An
    /// on-device chat asking for the same topic is told so, so its promise
    /// to stay on this device stays true. Nothing is sent by the ask.
    @Test func anOnDeviceChatIsToldWhenTodaysOneMayUseTheCloud() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: ReconTestData.sources,
                                            place: .mayLeaveDevice, memory: notes, model: LocalStubModel(),
                                            cloud: cloud, now: { [morning] in morning })
        let runner = try #require(model.recon)
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        model.perform(card) { _ in }
        let id = try #require(runner.tasks.first?.id)
        #expect(runner.mayUseCloud(id))
        let chat = HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(),
                                                      names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil,
                                                      replyBeat: .zero), to: model)
        #expect(chat.privacyPlace.staysOnDevice)
        chat.submit("look into the Riverside pool reopening")
        chat.acceptReconOffer()
        #expect(runner.tasks.count == 1)
        #expect(chat.conversation.turns.last?.text == ReconWords.alreadyOnWithCloud)
        #expect(ReconWords.alreadyOnWithCloud.contains("cloud"))
        // A chat that may leave the device anyway gets the plain line.
        #expect(model.alreadyLine(for: SampleSources.poolTopic, place: .mayLeaveDevice) == ReconWords.alreadyOn)
        // With the cloud off when Today started it, the plain line is true too.
        let local = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: ReconTestData.sources,
                                            place: .onDevice, memory: nil, model: LocalStubModel(), cloud: nil,
                                            now: { [morning] in morning })
        #expect(local.lookInto(SampleSources.poolTopic))
        #expect(local.alreadyLine(for: SampleSources.poolTopic, place: .onDevice) == ReconWords.alreadyOn)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A kept point too long for the notes gets a line of its own, never
    /// the composer's ask to shorten words the person didn't write.
    @Test func aPointTooLongForTheNotesSaysWhereItIsInFull() async throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { discard(memory) }
        let played = realRecon(at: morning)
        let runner = played.runner
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        let long = String(repeating: "The pool reopens in November after the roof work. ", count: 14)
        model.summarizer = { CloudWorded(reply: "POINT: \(long)[2]") }
        #expect(model.lookInto(SampleSources.poolTopic))
        played.advance(30)
        let id = try #require(runner.tasks.first?.id)
        await runner.settle(id)
        let summary = try #require(runner.summary(for: id))
        let point = try #require(summary.points.first)
        #expect(try #require(summary.note(for: point)).count > MemoryStore.maxLength)
        #expect(!model.remember(point, in: summary))
        #expect(model.rememberStatus == ReconWords.pointTooLong)
        #expect(model.rememberStatus != MemoryWords.tooLong)
        #expect(memory.notes().isEmpty)
        #expect(ReconWords.all.contains(ReconWords.pointTooLong))
    }

    /// A point worded on this device whose own words, with no dispute,
    /// are longer than a note may be: the too-long line, nothing saved, and
    /// Open sources, which the line sends the person to, has every word.
    @Test func aPointLongerThanANoteSaysSoAndOpenSourcesHasItAll() async throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { discard(memory) }
        let inner = LocalFakeEngine(rule: .isolated(), origin: morning)
        let provider = CountingProvider(now: { [morning] in morning })
        let words = Array(repeating: "the Riverside pool reopening brings swim lessons and family swim", count: 10)
            .joined(separator: " and ") + "."
        provider.give([ReconSource(id: "long", title: "Riverside pool reopening", publisher: "Riverside Gazette",
                                   url: URL(string: "https://gazette.example.org/long")!, published: morning - 86_400,
                                   text: words)])
        let runner = ReconRunner(engine: PlainEngine(inner), provider: provider, now: { [morning] in morning })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        #expect(model.lookInto(SampleSources.poolTopic))
        inner.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        let point = try #require(summary.points.first)
        #expect(point.disagreement == nil)
        #expect(point.text.count > MemoryStore.maxLength)
        #expect(model.canRemember(summary))
        #expect(!model.remember(point, in: summary))
        #expect(model.rememberStatus == ReconWords.pointTooLong)
        #expect(memory.notes().isEmpty)
        #expect(!memory.hasStoredFile)
        // The line names the card's own button, which the card shows.
        let card = ReconCard(summary: summary, time: "", gathered: "", canRemember: true)
        #expect(card.actions.contains(.sources))
        #expect(ReconWords.pointTooLong.contains(ReconCard.title(.sources)))
        // And that sheet shows the point whole, as the card can't.
        let sheet = ReconSourcesSheet(summary: summary)
        let row = try #require(sheet.points.first { $0.point.id == point.id })
        #expect(row.pointLine == point.text)
        #expect(row.spoken.contains(point.text))
        #expect(sheet.points.map(\.point) == summary.points)
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
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
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
        await eventually { chatReview.pending != nil && today.pending != nil }
        #expect(chatReview.pending != nil)
        #expect(today.pending != nil)
        #expect(maker.wire.sent.isEmpty)
        _ = cloud.setOn(false)
        await eventually { chatReview.pending == nil && today.pending == nil }
        #expect(chatReview.pending == nil)
        #expect(today.pending == nil)
        await runner.settle(id)
        await eventually { !chat.isReplying }
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    /// A recon tried again with the cloud on asks again, with a fresh
    /// preview. A Send given to an earlier preview is never used for it.
    @Test func aRetryWithTheCloudOnAsksAgain() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let engine = ReplayEngine()
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
        await eventually { review.pending != nil }
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
        defer { discard(memory) }
        let played = realRecon(at: morning)
        let runner = played.runner
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        #expect(model.lookInto(SampleSources.poolTopic))
        played.advance(30)
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
        // A fresh snapshot, so nothing is held from before.
        model.refresh()
        let before = engine.reads
        for _ in 0..<10 { #expect(model.summary(for: task) != nil) }
        #expect(engine.reads - before == 1)
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
        let gate = Gate()
        let mark = ThreadMark()
        model.summarizer = { HeldSummarizer(gate: gate, mark: mark) }
        // Plain, not tied to the main actor, so a line said off it is noted
        // rather than stopping the run.
        let heard = ThreadLog()
        model.announce = { _ in heard.note() }
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
        #expect(!heard.onMain.isEmpty)
        #expect(heard.onMain.allSatisfy { $0 })
    }

    /// A summarizer that comes back on a background queue, as a cloud reply
    /// does: every change Today publishes still happens on the main thread.
    @Test(.timeLimit(.minutes(1)))
    func aSummaryLandingOnABackgroundQueuePublishesOnlyOnTheMainThread() async throws {
        let (model, engine, runner) = feed()
        let mark = ThreadMark()
        model.summarizer = { BackgroundSummarizer(mark: mark) }
        // Plain, not tied to the main actor, so a change off it is noted
        // rather than stopping the run.
        let log = ThreadLog()
        let watch = model.objectWillChange.sink { @Sendable _ in log.note() }
        defer { watch.cancel() }
        #expect(model.lookInto(SampleSources.libraryTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        await runner.settle(id)
        // It was finished, and the runner told its observers, off the main thread.
        #expect(mark.finishedOnMain == false)
        for await feed in model.$feed.values
            where feed.groups.flatMap(\.items).contains(where: { $0.id == id && $0.task?.state == .done }) {
            break
        }
        #expect(!log.onMain.isEmpty)
        #expect(log.onMain.allSatisfy { $0 })
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

    /// The scripted clock is moved by the home screen, not by Today's view,
    /// so Today is shown only inside the home screen, and every showcase
    /// scene with live tasks is a home screen. Then no scene's cards sit
    /// still for want of a clock.
    @Test func everySceneThatPlaysTasksHasTheClock() throws {
        let sources = try ContrastGuardTests.sources()
        let showing = sources.filter { !SwiftSource($0.text).calls(named: ["FeedView"]).isEmpty }.map(\.name)
        #expect(showing == ["HomeView.swift"])
        let home = try #require(sources.first { $0.name == "HomeView.swift" }?.text)
        #expect(home.contains(".task(id: feed.ticks)"))
        // In the showcase, the one scene that plays tasks live does it
        // through `taskHome`, a home screen.
        let showcase = SwiftSource(try #require(sources.first { $0.name == "ShowcaseScene.swift" }?.text))
        let live = showcase.calls(named: ["HomeView"]).filter { $0.arguments.contains("drivesTasks:") }
        #expect(live.count == 1)
        #expect(showcase.calls(named: ["FeedModel"]).isEmpty)
        for scene in ShowcaseScene.allCases where scene.tasks(rule: .isolated()) != nil {
            #expect(scene.needsYou() != nil, "\(scene) has tasks but no home screen")
        }
    }

    // MARK: Forget everything while the cloud has it

    /// The person said yes, and the summary is still on its way: what it
    /// read may have gone, so Today says it may.
    @Test func forgettingWhileACloudSummaryIsUnderWaySaysItCantBeCalledBack() async throws {
        let (model, engine, runner) = feed()
        let gate = Gate()
        let mark = ThreadMark()
        model.summarizer = { HeldSummarizer(gate: gate, mark: mark, leaves: true, saysYes: true) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        #expect(runner.summariesMayLeaveDevice == 1)
        await eventually { runner.summariesPastAYes == 1 }
        let id = try #require(runner.tasks.first?.id)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
        await gate.open()
        // The summary is still put together, late, and nothing keeps it.
        await runner.settleEverything()
        #expect(mark.finishedOnMain != nil)
        model.refresh()
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
        #expect(runner.summary(for: id) == nil)
        #expect(runner.summariesMayLeaveDevice == 0)
        #expect(!model.feed.groups.flatMap(\.items).contains { $0.id == id })
    }

    /// A summary that may go through the cloud, still working before any
    /// yes: nothing was asked and nothing went, so no line says it may have.
    @Test func forgettingACloudSummaryBeforeAnyYesSaysNothingAboutTheCloud() async throws {
        let (model, engine, runner) = feed()
        let gate = Gate()
        model.summarizer = { HeldSummarizer(gate: gate, mark: ThreadMark(), leaves: true) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        #expect(runner.summariesMayLeaveDevice == 1)
        #expect(runner.summariesPastAYes == 0)
        model.forgetTasks()
        #expect(model.forgotUnderway == nil)
        await gate.open()
        await runner.settleEverything()
        #expect(runner.tasks.isEmpty)
    }

    /// With the real cloud summarizer and Today's own gate, Forget lands
    /// while the summary is on its way to the preview, before it shows:
    /// no yes was asked for, so no line says anything may have gone, no
    /// connection is made and nothing is sent.
    @Test(.timeLimit(.minutes(1)))
    func forgettingJustBeforeTodaysPreviewSaysNothingWent() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, engine, runner) = feed()
        let review = model.cloudReview
        let gate = Gate()
        model.summarizer = {
            let made = cloud.chatModel(local: LocalStubModel(), review: review, madeOnSend: true)
            return ReconSummarizers.choose(for: HeldModel(gate: gate, model: made))
        }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 12)
        await eventually { runner.summariesMayLeaveDevice == 1 }
        #expect(review.pending == nil)

        model.forgetTasks()
        #expect(model.forgotUnderway == nil)
        await gate.open()
        await runner.settleEverything()
        engine.advance(by: 60)
        model.refresh()
        #expect(review.pending == nil)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.tasks.isEmpty)
        #expect(runner.summary(for: id) == nil)
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

    /// The card's footer says how the summary was made, and VoiceOver
    /// hears it: worded in the cloud, not sent, or withdrawn.
    @Test func aCloudWordedCardSaysSo() throws {
        let pool = try ReconTestData.pool()
        let cloudy = ReconSummary(id: pool.id, topic: pool.topic, overview: pool.overview, points: pool.points,
                                  sources: pool.sources, gatheredAt: pool.gatheredAt, madeOnDevice: false)
        #expect(cloudy.note == ReconWords.wordedInCloud)
        let card = ReconCard(summary: cloudy, time: "9:40 AM", gathered: "Gathered today at 9:40 AM")
        #expect(ImageRenderer(content: card.frame(width: 393)).cgImage != nil)
        // A full stop between the two, so VoiceOver pauses.
        #expect(card.footerSpoken == "Gathered today at 9:40 AM. \(ReconWords.wordedInCloud)")
        for note in [ReconWords.declinedCloud, ReconWords.cloudWithdrawn, ReconWords.cloudUnreadable] {
            let local = ReconSummary(id: pool.id, topic: pool.topic, overview: pool.overview, points: pool.points,
                                     sources: pool.sources, gatheredAt: pool.gatheredAt, madeOnDevice: true, note: note)
            let heard = ReconCard(summary: local, time: "9:40 AM", gathered: "Gathered today at 9:40 AM").footerSpoken
            #expect(heard == "Gathered today at 9:40 AM. \(note)", "not heard: \(note)")
        }
        // On the device with nothing to say, only when it was gathered.
        #expect(ReconCard(summary: pool, time: "", gathered: "Gathered today at 9:40 AM").footerSpoken
                == "Gathered today at 9:40 AM")
    }

    /// A source's link says what it opens, in a sentence, not a bare host.
    @Test func aSourceLinkSaysWhatItOpens() {
        #expect(ReconWords.pageLinkHint("gazette.example.org") == "Opens gazette.example.org in your browser.")
        #expect(ReconWords.pageLinkHint(nil) == "Opens the page in your browser.")
        #expect(ReconWords.pageLinkHint("") == "Opens the page in your browser.")
        #expect(ReconWords.all.contains(ReconWords.pageLinkHint("gazette.example.org")))
    }

    /// The sources sheet sets the points beside each page's own text, so
    /// the note that they were worded in the cloud shows under them there.
    @Test func theSourcesSheetSaysThePointsWereWordedInTheCloud() throws {
        let pool = try ReconTestData.pool()
        let task = try #require(ReconTask(topic: pool.topic))
        let parsed = try #require(CloudReconSummarizer.parse("""
            POINT: The pool opens again on November 10, the city says. [2]
            POINT: Family swim is Saturday mornings. [2]
            """, task: task, id: pool.id, sources: pool.sources, gatheredAt: pool.gatheredAt))
        let sheet = ReconSourcesSheet(summary: parsed)
        #expect(sheet.pointsNote == ReconWords.wordedInCloud)
        #expect(ImageRenderer(content: sheet.frame(width: 393, height: 1200)).cgImage != nil)
        #expect(ReconSourcesSheet(summary: pool).pointsNote == nil)
    }

    // MARK: Only offered when it can start

    /// A chat offers to look into things only when Today's runner could
    /// start one: a scripted engine and pages on this device. Otherwise
    /// "research X" gets a reply, never an offer whose tap could only fail.
    @Test func aChatOffersOnlyWhenTodayCanStartIt() async throws {
        func today(tasks: (any TaskEngine)?, reading: any SourceProvider) -> FeedModel {
            HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: tasks,
                                    drivesTasks: false, reading: reading, place: .onDevice, memory: nil,
                                    model: LocalStubModel(), cloud: nil, now: { [morning] in morning })
        }
        func chat(to feed: FeedModel) -> ChatController {
            HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                                               conversation: nil, replyBeat: .zero), to: feed)
        }
        let scripted = today(tasks: nil, reading: ReconTestData.sources)
        #expect(scripted.canLookInto)
        #expect(chat(to: scripted).lookInto != nil)
        for feed in [today(tasks: OwnStepsEngine(), reading: ReconTestData.sources),
                     today(tasks: ReplayEngine(), reading: FarPages())] {
            #expect(!feed.canLookInto)
            let unable = chat(to: feed)
            #expect(unable.lookInto == nil)
            unable.submit("research quiet dishwashers")
            #expect(unable.reconOffer == nil)
            await unable.settled()
            #expect(unable.conversation.turns.last?.speaker == .agent)
            #expect(unable.conversation.turns.last?.text != ReconWords.couldNotStart)
        }
    }

    // MARK: The cloud setting changes while Today's preview waits

    /// Another window turned the cloud off, and this one reads the setting
    /// again. Today's preview is withdrawn then and there, so the person
    /// is never asked to approve what could no longer go out.
    @Test func aChangedCloudSettingWithdrawsTodaysPreview() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint))
        let cloud = CloudHelp(store: store, endpoint: endpoint, memory: notes, transport: { maker.make() })
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: ReconTestData.sources, place: .mayLeaveDevice,
                                            memory: notes, model: LocalStubModel(), cloud: cloud, now: { [morning] in morning })
        let runner = try #require(model.recon)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        await eventually { model.cloudReview.pending != nil }
        let preview = try #require(model.cloudReview.pending)
        try store.save(CloudHelpSettings(isOn: false))
        cloud.refresh()
        #expect(model.cloudReview.pending == nil)
        // A Send on the sheet that was there does nothing.
        model.cloudReview.answer(.send, for: preview.id)
        await runner.settle(id)
        runner.advance(by: 30)
        #expect(maker.wire.sent.isEmpty)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudWithdrawn)
    }

    // MARK: Forget everything while Today's preview waits

    /// With the real cloud summarizer and Today's own gate: Forget
    /// everything withdraws the preview at once, a Send tapped late on it
    /// sends nothing, and no summary comes back.
    @Test func forgettingWhileTodaysPreviewWaitsSendsNothing() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let (model, engine, runner) = feed()
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 12)
        await eventually { review.pending != nil }
        let preview = try #require(review.pending)
        #expect(runner.summariesMayLeaveDevice == 1)

        model.forgetTasks()
        // Gone with its sheet, not on a later turn.
        #expect(review.pending == nil)
        // No yes was given, so nothing may have gone: no line says it might.
        #expect(model.forgotUnderway == nil)
        review.answer(.send, for: preview.id)
        // The summary's work has returned, so a late Send had every chance.
        await runner.settleEverything()
        engine.advance(by: 60)
        model.refresh()
        #expect(maker.wire.sent.isEmpty)
        #expect(review.pending == nil)
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
        #expect(runner.summary(for: id) == nil)
        #expect(runner.summariesMayLeaveDevice == 0)
        #expect(!model.feed.groups.flatMap(\.items).contains { $0.id == id })
    }

    /// The other side: Send was tapped and the request is on its way when
    /// everything is forgotten. That may have gone, so Today says it may,
    /// and never that it was sent.
    @Test func forgettingAfterTheYesSaysTheSourcesMayHaveGone() async throws {
        let wire = HeldWire(reply: "POINT: The pool reopens on November 10. [2]")
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { URLSessionCloudTransport(load: wire.load) })
        let (model, engine, runner) = feed()
        let review = model.cloudReview
        model.summarizer = { ReconSummarizers.choose(for: cloud.chatModel(local: LocalStubModel(), review: review)) }
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 12)
        let preview = await review.shown()
        review.answer(.send, for: preview.id)
        await eventually { wire.sentCount == 1 }
        #expect(wire.sentCount == 1)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
        #expect(ReconWords.forgotWhileInCloud.contains("may"))
        #expect(!ReconWords.forgotWhileInCloud.localizedCaseInsensitiveContains("sent"))
        await wire.gate.open()
        await runner.settleEverything()
        #expect(runner.tasks.isEmpty)
    }

    // MARK: Taps heard

    /// A second tap on Look into it starts nothing, and VoiceOver hears why.
    @Test func aSecondTapOnLookIntoItIsHeard() throws {
        let (model, engine, runner) = feed()
        var heard: [String] = []
        model.announce = { heard.append($0.text) }
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        model.perform(card) { _ in }
        #expect(!heard.contains(ReconWords.alreadyOn))
        model.perform(card) { _ in }
        #expect(runner.tasks.count == 1)
        #expect(heard.filter { $0 == ReconWords.alreadyOn }.count == 1)
        // Once it's ready, the line says so.
        engine.advance(by: 60)
        model.perform(card) { _ in }
        #expect(runner.tasks.count == 1)
        #expect(heard.last == ReconWords.alreadyReady)
    }

    /// The answers to Look into it and Not now are read aloud like any
    /// reply, once.
    @Test func theAnswersToAnOfferAreHeard() {
        for (accept, line) in [(true, ReconWords.started), (false, ReconWords.offerDeclined)] {
            let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                                 names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
            controller.lookInto = { _, _ in .started }
            controller.submit("research quiet dishwashers")
            #expect(ChatView.replyLanded(in: controller, covered: false) == ReconWords.offer("quiet dishwashers"))
            if accept { controller.acceptReconOffer() } else { controller.declineReconOffer() }
            #expect(ChatView.replyLanded(in: controller, covered: false) == line)
            #expect(ChatView.replyLanded(in: controller, covered: false) == nil)
        }
        // A start that couldn't happen is heard too.
        let refused = ChatController.make(brand: brand, model: LocalStubModel(),
                                          names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        refused.lookInto = { _, _ in .couldNotStart }
        refused.submit("look into the bus strike")
        refused.acceptReconOffer()
        #expect(ChatView.arrival(for: refused, covered: false) == .reply(ReconWords.couldNotStart))
    }

    /// VoiceOver lands on the offer's answers only once it has finished
    /// reading the offer, so the question is never cut off. Another line
    /// finishing moves nothing. Each answer says what it does.
    @Test func theOffersButtonsAreFoundAndSayWhatTheyDo() throws {
        #expect(ReconOfferButtons.arrivalFocus == .yes)
        let offer = ReconWords.offer("the pool")
        func focus(_ finished: String?, _ question: String?, read: Bool? = true) -> ReconOfferButtons.Choice? {
            ReconOfferButtons.focusOnceRead(afterFinishing: finished, question: question, wasSuccessful: read)
        }
        #expect(focus(offer, offer) == .yes)
        #expect(focus(FirstConversation.thinking, offer) == nil)
        #expect(focus(nil, offer) == nil)
        #expect(focus(offer, nil) == nil)
        // Read with something before it, or with other spacing, it still
        // counts once the whole question is done. Part of it never does.
        #expect(focus("Pip. " + offer, offer) == .yes)
        #expect(focus(offer.replacingOccurrences(of: " ", with: "  ") + "\n", offer) == .yes)
        #expect(focus(String(offer.prefix(20)), offer) == nil)
        #expect(focus(offer, "  ") == nil)
        // Cut off before the end, as when the person swiped on, or with no
        // word on how it went: focus stays where the person left it.
        #expect(focus(offer, offer, read: false) == nil)
        #expect(focus(offer, offer, read: nil) == nil)
        // What the chat announces for an offer is the offer's own line, the
        // one the buttons wait for.
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        controller.lookInto = { _, _ in .started }
        controller.submit("look into the pool")
        let question = try #require(controller.reconOffer.flatMap { offer in
            controller.conversation.turns.first { $0.id == offer.turnID }?.text
        })
        #expect(question == controller.conversation.turns.last?.text)
        let announced = ChatView.replyLanded(in: controller, covered: false)
        #expect(announced == question)
        #expect(focus(announced, question) == .yes)
        #expect(ImageRenderer(content: ReconOfferButtons(question: offer, onYes: {}, onNo: {}).frame(width: 393)).cgImage != nil)
        #expect(ReconOfferButtons.hint(.no) == "Nothing starts.")
        #expect(ReconOfferButtons.hint(.yes) == ReconWords.offerYesHint)
        #expect(ReconWords.offerYesHint.contains("Today"))
        let buttons = ReconOfferButtons(onYes: {}, onNo: {}).frame(width: 393)
        #expect(ImageRenderer(content: buttons).cgImage != nil)
    }

    /// Each Remember this says which point it keeps, so buttons heard one
    /// at a time never sound the same.
    @Test func eachRememberButtonSaysWhichPoint() throws {
        let pool = try ReconTestData.pool()
        let labels = pool.points.map { ReconRememberSheet.buttonLabel($0, kept: false) }
        #expect(Set(labels).count == pool.points.count)
        for (point, label) in zip(pool.points, labels) {
            #expect(label == "\(ReconWords.rememberThis): \(point.text)")
        }
        let first = try #require(pool.points.first)
        #expect(ReconRememberSheet.buttonLabel(first, kept: true) == "\(ReconWords.remembered): \(first.text)")
    }

    // MARK: Chats and a withdrawn preview

    /// A chat preview taken away, by the cloud going off, a private word
    /// changing or the screen going, is handled as nothing sent: the turn
    /// comes back to the composer, and the line says so and points at it.
    /// No one chose, so its line never says the person did.
    @Test func aChatTreatsAWithdrawnPreviewAsNothingSent() {
        #expect(ChatController.nothingWasSent(CloudModelError.withdrawn))
        #expect(ChatController.failureLine(for: CloudModelError.withdrawn) == CloudWords.withdrawn)
        #expect(CloudWords.withdrawn != CloudWords.notSent)
        #expect(!CloudWords.withdrawn.hasPrefix("Okay"))
        #expect(!CloudWords.withdrawn.contains("chose"))
        #expect(ChatController.pointsAtTheDraft(ChatController.failureLine(for: CloudModelError.withdrawn)))
        #expect(ChatController.nothingWasSent(CloudModelError.withdrawn) == ChatController.nothingWasSent(CloudModelError.notSent))
    }

    // MARK: Remembering

    /// A point the cloud put into words, from `CloudReconSummarizer.parse`,
    /// kept through Today's Remember this: the note says it was worded in
    /// the cloud, and its label never names the publisher.
    @Test func aCloudWordedPointIsKeptAsARetelling() async throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { discard(memory) }
        let played = realRecon(at: morning)
        let runner = played.runner
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        // The cloud's own words name the publisher in full. They may: they
        // are marked as the cloud's. What the note adds must not.
        model.summarizer = { CloudWorded(reply: """
            POINT: City of Riverside Parks says the pool reopens on November 10. [1]
            POINT: Family swim is on Saturday mornings. [2]
            """) }
        #expect(model.lookInto(SampleSources.poolTopic))
        played.advance(30)
        let id = try #require(runner.tasks.first?.id)
        await runner.settle(id)
        let summary = try #require(runner.summary(for: id))
        #expect(!summary.madeOnDevice)
        let point = try #require(summary.points.first)
        let publisher = try #require(point.sourceIDs.first.flatMap(summary.source)?.publisher)
        #expect(model.remember(point, in: summary))
        let note = try #require(memory.notes().first)
        #expect(point.text.contains(publisher))
        // Word for word: the cloud's line, then that it was the cloud's, and
        // no credit to any publisher beside it.
        #expect(note.text == "\(point.text) (put into words in the cloud, from the sources it was given)")
        #expect(note.text.components(separatedBy: publisher).count == 2)
        #expect(note.source == .lookedUp(""))
        #expect(note.source.label == "From something I looked into")
        #expect(!note.source.label.contains(publisher))
    }

    /// Made up news never reaches the notes as if it were real. On every
    /// kind of example recon, from the one shared list: the card says
    /// Example and offers no Remember, the choice of points never opens,
    /// and no tap on any point saves anything. The real one, the control,
    /// offers it and keeps the point.
    @Test func aPointFromAnExampleIsNeverKept() throws {
        for played in exampleRecons(at: morning) + [realRecon(at: morning)] {
            let memory = ShowcaseScene.emptyMemory()
            defer { discard(memory) }
            let runner = played.runner
            let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                                  memory: memory, now: { [morning] in morning })
            #expect(model.lookInto(SampleSources.poolTopic), "\(played.name)")
            played.advance(30)
            model.refresh()
            let item = try #require(model.feed.groups.flatMap(\.items).first { $0.task != nil }, "\(played.name)")
            let task = try #require(item.task)
            let summary = try #require(model.summary(for: task), "\(played.name)")
            #expect(!summary.points.isEmpty)
            let card = ReconCard(summary: summary, time: "9:40 AM", gathered: "", isSample: model.isSample(item),
                                 canRemember: model.canRemember(summary))
            let real = played.name == "real"
            #expect(card.spoken.hasPrefix(FeedWords.exampleMarker) == !real, "\(played.name)")
            #expect(card.actions.contains(.remember) == real, "\(played.name)")
            model.choosingPoint = summary
            #expect((model.choosingPoint != nil) == real, "\(played.name)")
            model.choosingPoint = nil
            let kept = summary.points.map { model.remember($0, in: summary) }
            #expect(kept.allSatisfy { $0 == real }, "\(played.name)")
            #expect(memory.notes().count == (real ? summary.points.count : 0), "\(played.name)")
        }
    }

    /// The card alone: an example never offers Remember, even when told
    /// its points could be kept.
    @Test func anExampleCardNeverOffersRemember() throws {
        let pool = try ReconTestData.realPool()
        #expect(!ReconCard(summary: pool, time: "", gathered: "", isSample: true).actions.contains(.remember))
        #expect(!ReconCard(summary: pool, time: "", gathered: "", canRemember: false).actions.contains(.remember))
        #expect(ReconCard(summary: pool, time: "", gathered: "").actions.contains(.remember))
        // A summary of example pages says so itself, whatever the card is told.
        let example = try ReconTestData.pool()
        #expect(example.isSample)
        #expect(!ReconCard(summary: example, time: "", gathered: "").actions.contains(.remember))
    }

    /// A kept note deleted on the memory screen: opening the choice again
    /// shows its point as not kept, and it can be kept again.
    @Test func aDeletedNoteNoLongerShowsItsPointAsKept() throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { discard(memory) }
        let played = realRecon(at: morning)
        let runner = played.runner
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: runner, place: .onDevice,
                              memory: memory, now: { [morning] in morning })
        #expect(model.lookInto(SampleSources.libraryTopic))
        played.advance(30)
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        let point = try #require(summary.points.first)
        #expect(model.remember(point, in: summary))
        let kept = try #require(memory.notes().first)
        #expect(try memory.forget(kept.id))
        // Opening the choice looks again.
        model.choosingPoint = summary
        #expect(!model.isRemembered(point, in: summary))
        #expect(model.remember(point, in: summary))
        #expect(memory.notes().count == 1)
        // A note still there keeps its point kept.
        model.choosingPoint = nil
        model.choosingPoint = summary
        #expect(model.isRemembered(point, in: summary))
    }

    // MARK: Today with the cloud on, as the home screen makes it

    /// Today as the home screen makes it, with the cloud on, reading `pages`.
    func cloudToday(reading pages: any SourceProvider = ReconTestData.sources,
                    transport: @escaping @Sendable () -> any CloudTransport,
                    notes: MemoryStore) throws -> (FeedModel, ReconRunner, CloudHelp) {
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: transport)
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: pages, place: .mayLeaveDevice,
                                            memory: notes, model: LocalStubModel(), cloud: cloud,
                                            now: { [morning] in morning })
        return (model, try #require(model.recon), cloud)
    }

    /// Words no line after a yes may use: it was neither taken away
    /// unanswered nor turned down.
    func neverSaysNoOneSaidYes(_ line: String?, _ comment: Comment? = nil) {
        #expect(line != ReconWords.cloudWithdrawn, comment)
        #expect(line != ReconWords.declinedCloud, comment)
        for word in ["chose", "declined"] { #expect(line?.contains(word) != true, comment) }
    }

    /// Send was tapped on Today's preview, then the cloud was off by the
    /// time the request would go. The card says so with the yes path's
    /// line, never that nothing was asked or that the person chose.
    @Test func aYesThenTheCloudOffOnTodaySaysItWasOffByThen() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, cloud) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let preview = await model.cloudReview.shown()
        // In one turn of the main actor, before the request goes on.
        model.cloudReview.answer(.send, for: preview.id)
        _ = cloud.setOn(false)
        await runner.settle(id)
        runner.advance(by: 30)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.cloudOff)
        neverSaysNoOneSaidYes(summary.note)
        #expect(maker.wire.sent.isEmpty)
        #expect(maker.made == 0)
    }

    /// Send was tapped, then Stop before the request went. The card says
    /// it was stopped, keeps nothing, and nothing is sent after the Stop.
    @Test func aYesThenAStopOnTodaySendsNothingAndSaysStopped() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let preview = await model.cloudReview.shown()
        model.cloudReview.answer(.send, for: preview.id)
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        await runner.settleEverything()
        let card = try #require(runner.tasks.first { $0.id == id })
        #expect(card.state == .stopped)
        #expect(card.step == TaskWords.stopped)
        #expect(runner.summary(for: id) == nil)
        neverSaysNoOneSaidYes(card.step)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Stop comes first, and a Send lands on the preview after it, before
    /// the sheet has gone. Nothing is ever sent: a send never starts after
    /// Stop.
    @Test func aStopThenAYesOnTodaySendsNothing() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let preview = await model.cloudReview.shown()
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        model.cloudReview.answer(.send, for: preview.id)
        await runner.settleEverything()
        #expect(maker.wire.sent.isEmpty)
        #expect(maker.made == 0)
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.summary(for: id) == nil)
    }

    /// The other order: Send, the request leaves, and Stop comes while it
    /// is on its way. It may have arrived, so the card says only that it
    /// was stopped, keeps nothing, and makes no claim that nothing went.
    @Test func aStopWhileTodaysSendIsOnItsWayKeepsNothing() async throws {
        let wire = HeldWire(reply: "POINT: The pool reopens on November 10. [2]")
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { URLSessionCloudTransport(load: wire.load) }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let preview = await model.cloudReview.shown()
        model.cloudReview.answer(.send, for: preview.id)
        await eventually { wire.sentCount == 1 }
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        await wire.gate.open()
        await runner.settleEverything()
        #expect(wire.sentCount == 1)
        let card = try #require(runner.tasks.first { $0.id == id })
        #expect(card.state == .stopped)
        #expect(runner.summary(for: id) == nil)
        #expect(!card.step.contains("Nothing went"))
    }

    /// Pages that touch on hard things, with the cloud on: no preview ever
    /// shows, nothing is made or sent, and the card says why. The control,
    /// the same pages without those words, does reach a preview, so this
    /// passes for the reason it says and not because the cloud is broken.
    @Test func hardWordsInThePagesNeverReachThePreview() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        func page(_ text: String) -> ReconSource {
            ReconSource(id: "test:safety", title: "Riverside pool reopening", publisher: "Riverside Gazette",
                        url: URL(string: "https://gazette.example.org/safety")!, published: morning - 86_400,
                        text: text)
        }
        let calm = "The Riverside pool reopens on November 10. Family swim at the pool runs on Saturdays."
        let provider = CountingProvider(now: { [morning] in morning })
        provider.give([page("A sign by the Riverside pool lists a suicide prevention line. " + calm)])
        let (model, runner, _) = try cloudToday(reading: provider, transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        var sawPreview = false
        runner.advance(by: 12)
        let deadline = ContinuousClock.now + eventuallyLimit
        while runner.summary(for: id) == nil, ContinuousClock.now < deadline {
            if model.cloudReview.pending != nil { sawPreview = true }
            try await Task.sleep(for: .milliseconds(5))
            runner.advance(by: 1)
        }
        await runner.settleEverything()
        #expect(!sawPreview)
        #expect(model.cloudReview.pending == nil)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.madeOnDevice)
        #expect(summary.note == ReconWords.keptForCare)

        // The control: the same pages without those words reach a preview.
        let calmProvider = CountingProvider(now: { [morning] in morning })
        calmProvider.give([page(calm)])
        let (control, controlRunner, _) = try cloudToday(reading: calmProvider, transport: { maker.make() }, notes: notes)
        #expect(control.lookInto(SampleSources.poolTopic))
        let controlID = try #require(controlRunner.tasks.first?.id)
        controlRunner.advance(by: 12)
        _ = await control.cloudReview.shown()
        #expect(control.cloudReview.pending != nil)
        // A transport is made only for a send, so this one made none either.
        #expect(maker.made == 0)
        control.cloudReview.cancelPending()
        await controlRunner.settle(controlID)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A page's title and publisher are sent with its text, so each is
    /// held to the same checks. One page with the words in its title only,
    /// and one with them in its publisher only.
    func page(title: String = "Riverside pool reopening", publisher: String = "Riverside Gazette") -> ReconSource {
        ReconSource(id: "test:page", title: title, publisher: publisher,
                    url: URL(string: "https://gazette.example.org/pool")!, published: morning - 86_400,
                    text: "The Riverside pool reopens on November 10. Family swim at the pool runs on Saturdays.")
    }


    /// Words of crisis in a page's title, or in its publisher, with the
    /// cloud on: no preview ever shows, no connection is made, nothing is
    /// sent, and the card says why.
    @Test func hardWordsInATitleOrPublisherNeverReachThePreview() async throws {
        let hard = "Suicide prevention line"
        for heavy in [page(title: "\(hard) posted at the Riverside pool"), page(publisher: "\(hard) of Riverside")] {
            let maker = TransportMaker()
            let notes = ShowcaseScene.emptyMemory()
            defer { discard(notes) }
            let provider = CountingProvider(now: { [morning] in morning })
            provider.give([heavy])
            let (model, runner, _) = try cloudToday(reading: provider, transport: { maker.make() }, notes: notes)
            // Every preview Today's gate puts up, however briefly.
            let shown = PreviewLog()
            let watch = model.cloudReview.$pending.sink { if $0 != nil { shown.note() } }
            defer { watch.cancel() }
            #expect(model.lookInto(SampleSources.poolTopic))
            let id = try #require(runner.tasks.first?.id)
            runner.advance(by: 12)
            await runner.settleEverything()
            runner.advance(by: 30)
            #expect(shown.count == 0, "a preview showed for \(heavy.title), \(heavy.publisher)")
            #expect(model.cloudReview.pending == nil)
            #expect(maker.made == 0)
            #expect(maker.wire.sent.isEmpty)
            let summary = try #require(runner.summary(for: id))
            #expect(summary.madeOnDevice)
            #expect(summary.note == ReconWords.keptForCare)
        }
    }

    /// A private word in a page's title, or in its publisher, is masked in
    /// the preview and in the bytes that go, as it is in the page's text.
    @Test func aPrivateWordInATitleOrPublisherIsMasked() async throws {
        for named in [page(title: "Lemon cake at the Riverside pool snack bar"), page(publisher: "The Lemon Cake Gazette")] {
            let maker = TransportMaker()
            let notes = ShowcaseScene.emptyMemory()
            defer { discard(notes) }
            let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"])),
                                  endpoint: endpoint, memory: notes, transport: { maker.make() })
            let provider = CountingProvider(now: { [morning] in morning })
            provider.give([named])
            let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                                drivesTasks: false, reading: provider, place: .mayLeaveDevice,
                                                memory: notes, model: LocalStubModel(), cloud: cloud,
                                                now: { [morning] in morning })
            let runner = try #require(model.recon)
            #expect(model.lookInto(SampleSources.poolTopic))
            let id = try #require(runner.tasks.first?.id)
            runner.advance(by: 12)
            let preview = await model.cloudReview.shown()
            let body = preview.request.text
            #expect(!body.localizedCaseInsensitiveContains("lemon cake"), "shown for \(named.title), \(named.publisher)")
            #expect(body.contains("[private]"))
            // The rest of the field is there, so it was sent and masked, not left out.
            #expect(body.contains("at the Riverside pool snack bar") || body.contains("[private] Gazette"))
            model.cloudReview.answer(.send, for: preview.id)
            await runner.settle(id)
            #expect(maker.wire.sent.count == 1)
            #expect(maker.wire.sentText.allSatisfy { !$0.localizedCaseInsensitiveContains("lemon cake") })
            #expect(maker.wire.sentText.allSatisfy { $0.contains("[private]") })
        }
    }

    /// Today's preview can come up over the chat or the notes, so it says
    /// what it is for: a summary, for Today, and of what, as it is sent.
    /// The topic itself is masked, there and in the bytes that go.
    @Test func todaysPreviewSaysWhatItIsForAndMasksTheTopic() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        _ = try notes.remember("Swim lessons with Priya on Tuesdays.", source: .toldMe)
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto("Priya's swim lessons at the Riverside pool"))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let preview = await model.cloudReview.shown()
        let purpose = try #require(CloudPreviewSheet.todayPurpose(preview))
        #expect(purpose == ReconWords.previewForSummary("[name]'s swim lessons at the Riverside pool"))
        #expect(purpose.contains("Today"))
        #expect(!purpose.contains("Priya"))
        #expect(!preview.request.text.contains("Priya"))
        #expect(preview.request.text.contains("Please look into [name]'s swim lessons"))
        let sheet = CloudPreviewSheet(preview: preview, purpose: purpose, onSend: {}, onCancel: {})
        #expect(ImageRenderer(content: sheet.frame(width: 393, height: 900)).cgImage != nil)
        model.cloudReview.answer(.send, for: preview.id)
        await runner.settle(id)
        #expect(maker.wire.sent.count == 1)
        #expect(maker.wire.sentText.allSatisfy { !$0.contains("Priya") })
        // A chat's own preview gets no such line.
        #expect(ReconWords.previewForSummary(nil) == "This is for a summary on Today, not for a chat.")
    }

    /// A chat send in a summary's own words gets no line about Today's
    /// summary, even shown through Today's gate.
    @Test func aChatInASummarysWordsGetsNoSummaryLine() async throws {
        let reviewer = CloudReview()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let maker = TransportMaker()
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: { maker.make() })
        let model = cloud.chatModel(local: LocalStubModel(), review: reviewer, madeOnSend: true)
        let text = "Please look into the pool using only the sources below, and answer in plain words."
        let chat = Conversation(turns: [ChatTurn(id: UUID(), speaker: .person, text: text)], place: .mayLeaveDevice)
        let asking = Task { try? await chat.appendingReply(from: model) }
        let preview = await reviewer.shown()
        #expect(preview.request.text.contains("Please look into the pool"))
        #expect(CloudReconSummarizer.topic(asked: preview) == nil)
        #expect(CloudPreviewSheet.todayPurpose(preview) == nil)
        reviewer.answer(.cancel, for: preview.id)
        _ = await asking.value
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Today started one with the cloud on, and the cloud went off before
    /// its summary step. An on-device chat asking for it still hears that
    /// it may be put into words in the cloud: the setting is read again
    /// when the summary is put together, so it could be on again by then,
    /// and "may" stays true. Nothing goes while it is off.
    @Test func anOnDeviceChatHearsTheCautiousLineAfterTheCloudWentOff() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, cloud) = try cloudToday(transport: { maker.make() }, notes: notes)
        let card = try #require(model.feed.groups.flatMap(\.items).first { $0.id == "sample:pool" })
        model.perform(card) { _ in }
        let id = try #require(runner.tasks.first?.id)
        _ = cloud.setOn(false)
        let chat = HomeView.wired(ChatController.make(brand: brand, model: LocalStubModel(),
                                                      names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil,
                                                      replyBeat: .zero), to: model)
        chat.submit("look into the Riverside pool reopening")
        chat.acceptReconOffer()
        #expect(chat.conversation.turns.last?.text == ReconWords.alreadyOnWithCloud)
        #expect(ReconWords.alreadyOnWithCloud.contains("may"))
        runner.advance(by: 30)
        await runner.settle(id)
        #expect(runner.summary(for: id)?.note == ReconWords.cloudOff)
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: The production clock

    /// The clock the app gives the home screen when none is passed: the
    /// wall clock, so a recon says when it was really gathered.
    @Test func theAppsDefaultClockGathersAtTheWallTime() throws {
        let model = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: .isolated()), tasks: nil,
                                            drivesTasks: false, reading: ReconTestData.sources, place: .onDevice,
                                            memory: nil, model: LocalStubModel(), cloud: nil, now: HomeView.wallClock)
        let runner = try #require(model.recon)
        let before = Date()
        #expect(model.lookInto(SampleSources.poolTopic))
        model.tick(30)
        let after = Date()
        let summary = try #require(runner.tasks.first.flatMap { runner.summary(for: $0.id) })
        #expect(summary.gatheredAt >= before)
        #expect(summary.gatheredAt <= after)
    }

    // MARK: Memory refuses an example by itself

    /// The store's own refusal, with no feed in front of it: a looked up
    /// note without its summary, or with an example's, is never kept.
    @Test func theStoreAloneRefusesAnExamplesPoint() throws {
        let memory = ShowcaseScene.emptyMemory()
        defer { discard(memory) }
        let pool = try ReconTestData.pool()
        #expect(pool.isSample)
        for point in pool.points {
            #expect(pool.note(for: point) == nil)
            #expect(pool.memorySource(for: point) == nil)
            #expect(try memory.remember(point, from: pool) == .notKept)
            #expect(try memory.remember(point.text, source: .lookedUp("Riverside Gazette")) == .notKept)
        }
        #expect(try memory.remember("The pool reopens on November 10.", source: .lookedUp("")) == .notKept)
        #expect(memory.notes().isEmpty)
        // The control: the same point from real pages is kept.
        let real = try ReconTestData.realPool()
        guard case .saved = try memory.remember(try #require(real.points.first), from: real) else {
            Issue.record("a real point was not kept")
            return
        }
    }

    // MARK: Examples on screen

    /// An example's pages are made up, so their Open the page never shows,
    /// on any example, and a real page's does.
    @Test func anExamplesPagesNeverOpen() throws {
        let pool = try ReconTestData.pool()
        for source in pool.sources {
            #expect(source.link != nil)
            #expect(ReconSourcesSheet(summary: pool).link(for: source) == nil)
        }
        let real = try ReconTestData.realPool()
        #expect(real.sources.allSatisfy { ReconSourcesSheet(summary: real).link(for: $0) != nil })
        #expect(real.sources.allSatisfy { ReconSourcesSheet(summary: real, isSample: true).link(for: $0) == nil })
    }

    /// Every sample card on Today says it is an example, the swim lessons
    /// card above all, since it says something about the person. So it is
    /// when Today can't start one and it asks in the chat instead.
    @Test func everySampleCardSaysItIsAnExample() {
        for recon in [ReconRunner(engine: LocalFakeEngine(rule: .isolated(), origin: morning), provider: ReconTestData.sources),
                      ReconRunner(engine: OwnStepsEngine(), provider: ReconTestData.sources)] {
            let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: recon,
                                  place: .onDevice, now: { [morning] in morning })
            let items = model.feed.groups.flatMap(\.items).filter { $0.id.hasPrefix("sample:") }
            #expect(items.contains { $0.id == "sample:pool" })
            for item in items {
                #expect(model.isSample(item), "\(item.id)")
                let card = FeedCard(item: item, time: "", isSample: model.isSample(item)) {}
                #expect(card.spoken.hasPrefix(FeedWords.exampleMarker), "\(item.id)")
            }
        }
    }

    /// The card's Look into it names Today, not "here", so it stays true
    /// wherever it is heard.
    @Test func lookIntoItsHintNamesToday() {
        #expect(ReconWords.lookIntoHint.contains("Today"))
        #expect(!ReconWords.lookIntoHint.contains("here"))
    }

    /// A summary with no words in its overview shows no blank line under
    /// the title for VoiceOver to land on.
    @Test func aBlankOverviewShowsNoLine() throws {
        let pool = try ReconTestData.pool()
        #expect(ReconCard(summary: pool, time: "", gathered: "").shownOverview == pool.overview)
        let blank = ReconSummary(id: pool.id, topic: pool.topic, overview: "  ", points: pool.points,
                                 sources: pool.sources, gatheredAt: pool.gatheredAt, madeOnDevice: true)
        #expect(ReconCard(summary: blank, time: "", gathered: "").shownOverview == nil)
    }
}

/// Pages on this device that aren't examples.
struct RealPages: SourceProvider {
    var runsOnDevice: Bool { true }
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] { [] }
}

/// The sample pages, but read somewhere off this device, so no recon may
/// use them. Said outright, so a change to the protocol's default can't
/// let one through.
struct FarPages: SourceProvider {
    var runsOnDevice: Bool { false }
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] { try ReconTestData.sources.sources(for: task) }
}

/// Puts a given cloud reply into a summary, as `CloudReconSummarizer`
/// would once the person tapped Send. Sends nothing.
struct CloudWorded: ReconSummarizer {
    let reply: String
    var mayUseCloud: Bool { true }
    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        CloudReconSummarizer.parse(reply, task: task, id: id, sources: sources, gatheredAt: gatheredAt)
            ?? LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}

/// Comes back from a background dispatch queue, never the main thread,
/// then puts the summary together on this device.
struct BackgroundSummarizer: ReconSummarizer {
    let mark: ThreadMark
    var mayUseCloud: Bool { false }
    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { done.resume() }
        }
        mark.mark()
        return LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}

/// Whether each change was on the main thread, in order.
final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
    func note() {
        let main = Thread.isMainThread
        lock.lock(); seen.append(main); lock.unlock()
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

/// Counts what it is told of, from any thread.
final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    var count: Int { lock.withLock { seen } }
    func note() { lock.withLock { seen += 1 } }
}

/// Holds a model's reply until the gate opens, so a test can act while a
/// summary is on its way to the preview, before anything is shown.
struct HeldModel: ModelClient {
    let gate: Gate
    let model: any ModelClient
    var runsOnDevice: Bool { model.runsOnDevice }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        await gate.wait()
        return try await model.reply(to: transcript)
    }
}

/// Waits for the gate, then puts the summary together on this device. Says
/// it may leave the device when `leaves`, as a cloud one would, and, when
/// `saysYes`, that the person's yes is in before it waits, as a cloud one
/// does once Send is tapped.
struct HeldSummarizer: ReconSummarizer {
    let gate: Gate
    let mark: ThreadMark
    var leaves = false
    var saysYes = false

    var mayUseCloud: Bool { leaves }

    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        if saysYes { _ = CloudYes.heard?() }
        await gate.wait()
        mark.mark()
        return LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}
#endif
