#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import ReconTestSupport
import SourceScan
import Testing
@testable import PebbleUI

/// Today's cloud previews for summaries: each run's is its own, Stop takes
/// one away at once and a stale Send sends nothing, a Send stays marked,
/// a swipe down is a no, and the README says what Remember does.
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ReconPreviewTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let morning = ShowcaseScene.morning

    /// Today as the home screen makes it, with the cloud on.
    func cloudToday(transport: @escaping @Sendable () -> any CloudTransport,
                    notes: MemoryStore) throws -> (FeedModel, ReconRunner, CloudHelp) {
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: endpoint,
                              memory: notes, transport: transport)
        let model = HomeView.reconFeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()),
                                            tasks: nil, drivesTasks: false, reading: ReconTestData.sources,
                                            place: .mayLeaveDevice, memory: notes, model: LocalStubModel(),
                                            cloud: cloud, now: { [morning] in morning })
        return (model, try #require(model.recon), cloud)
    }

    func preview(run: String?) -> CloudPreview {
        let request = CloudRequest(url: CloudModel.url(for: endpoint), headers: CloudHeaders.fixed, body: Data("{}".utf8))
        return CloudPreview(request: request, hidden: [:], forSummary: run != nil, run: run)
    }

    // MARK: Each run's preview is its own

    /// Two summaries ask at once. The second waits behind the first rather
    /// than taking its place, and a Send can only answer the one on screen.
    @Test func twoRunsWaitOneBehindTheOther() async throws {
        let review = CloudReview()
        let first = preview(run: "task:1")
        let second = preview(run: "task:2")
        let firstAnswer = Task { await review.review(first) }
        #expect(await review.shown() == first)
        let secondAnswer = Task { await review.review(second) }
        await eventually { review.waiting.count == 2 }
        #expect(review.waiting == [first, second], "the second never withdraws the first")
        #expect(review.pending == first)
        // A Send for the one not on screen sends nothing, and changes nothing.
        review.answer(.send, for: second.id)
        review.answer(.cancel, for: second.id)
        #expect(review.waiting == [first, second])
        review.answer(.cancel, for: first.id)
        #expect(await firstAnswer.value == .cancel)
        #expect(review.pending == second)
        review.answer(.send, for: second.id)
        #expect(await secondAnswer.value == .send)
        #expect(review.pending == nil)
    }

    /// The same run asking again, as after a retry, takes its own older
    /// preview's place. A chat's previews, with no run, do too.
    @Test func onlyTheSameAskerReplacesAPreview() async throws {
        let review = CloudReview()
        let old = preview(run: "task:1")
        let other = preview(run: "task:2")
        let again = preview(run: "task:1")
        let oldAnswer = Task { await review.review(old) }
        #expect(await review.shown() == old)
        let otherAnswer = Task { await review.review(other) }
        await eventually { review.waiting.count == 2 }
        let againAnswer = Task { await review.review(again) }
        #expect(await oldAnswer.value == .withdrawn)
        await eventually { review.waiting.count == 2 }
        #expect(review.waiting == [other, again])
        review.cancelPending()
        #expect(await otherAnswer.value == .withdrawn)
        #expect(await againAnswer.value == .withdrawn)

        // A chat's previews have no run: a newer one takes the older one's
        // place too, and leaves a summary's waiting as it was.
        let summary = preview(run: "task:3")
        let chat = preview(run: nil)
        let newer = preview(run: nil)
        let summaryAnswer = Task { await review.review(summary) }
        #expect(await review.shown() == summary)
        let chatAnswer = Task { await review.review(chat) }
        await eventually { review.waiting.count == 2 }
        let newerAnswer = Task { await review.review(newer) }
        #expect(await chatAnswer.value == .withdrawn)
        await eventually { review.waiting.count == 2 }
        #expect(review.waiting == [summary, newer])
        review.cancelPending()
        #expect(await summaryAnswer.value == .withdrawn)
        #expect(await newerAnswer.value == .withdrawn)
    }

    /// Two recons on Today with the cloud on: both previews wait, neither
    /// withdraws the other, and each card gets the answer its own preview
    /// got. Only the one Sent goes.
    @Test func twoSummariesAtOnceEachGetTheirOwnAnswer() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        let review = model.cloudReview
        #expect(model.lookInto(SampleSources.poolTopic))
        #expect(model.lookInto(SampleSources.libraryTopic))
        let ids = runner.tasks.map(\.id)
        #expect(ids.count == 2)
        runner.advance(by: 12)
        await eventually { review.waiting.count == 2 }
        #expect(Set(review.waiting.compactMap(\.run)) == Set(ids))
        let first = try #require(review.pending)
        let firstRun = try #require(first.run)
        let secondRun = try #require(ids.first { $0 != firstRun })
        review.answer(.cancel, for: first.id)
        await eventually { review.pending?.run == secondRun }
        let second = try #require(review.pending)
        review.answer(.send, for: second.id)
        await runner.settleEverything()
        runner.advance(by: 30)
        #expect(runner.summary(for: firstRun)?.note == ReconWords.declinedCloud)
        // Sent, and the test wire's answer isn't a summary, so it says so.
        #expect(runner.summary(for: secondRun)?.note == ReconWords.cloudUnreadable)
        #expect(maker.wire.sent.count == 1)
        #expect(!runner.sentToCloud(firstRun))
        #expect(runner.sentToCloud(secondRun))
    }

    // MARK: Stop takes the preview away, and a stale Send sends nothing

    /// Stop withdraws the card's preview then and there, in the same turn of
    /// the main actor, so the sheet goes with it and a Send on it after
    /// Stop has nothing to answer.
    @Test func stopTakesThePreviewAwayAtOnce() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let shown = await model.cloudReview.shown()
        #expect(shown.run == id)
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        #expect(model.cloudReview.pending == nil, "gone before any later turn of the main actor")
        #expect(model.cloudReview.waiting.isEmpty)
        model.cloudReview.answer(.send, for: shown.id)
        await runner.settleEverything()
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(!runner.sentToCloud(id))
    }

    /// A summary's request is on the wire when the cloud is turned off. Its
    /// send is cancelled, as an open chat's is, and nothing more goes.
    @Test func turningOffEndsASummarysSendOnTheWire() async throws {
        let maker = TransportMaker(hangs: true)
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, cloud) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        runner.advance(by: 12)
        let shown = await model.cloudReview.shown()
        model.cloudReview.answer(.send, for: shown.id)
        #expect(await finishes { await maker.wire.started() }, "nothing reached the wire")
        cloud.turnOff()
        #expect(await finishes { await maker.wire.whenCancelled() }, "the summary's send was never cancelled")
        #expect(maker.wire.sent.count == 1)
        // Whatever happened above, nothing is left waiting on the wire.
        _ = runner.clear()
    }

    /// Forget everything ends a summary's send on the wire before anything
    /// is erased, as it does an open chat's, and says that what went may be
    /// in the cloud now.
    @Test func forgetEverythingEndsASummarysSendOnTheWire() async throws {
        let maker = TransportMaker(hangs: true)
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, cloud) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        runner.advance(by: 12)
        let shown = await model.cloudReview.shown()
        model.cloudReview.answer(.send, for: shown.id)
        #expect(await finishes { await maker.wire.started() }, "nothing reached the wire")
        let memory = HomeView.memoryModel(store: notes, place: .mayLeaveDevice, cloud: cloud, feed: model)
        memory.forgetEverything()
        #expect(await finishes { await maker.wire.whenCancelled() }, "the summary's send was never cancelled")
        #expect(memory.status?.contains(CloudWords.sentCantBeErased) == true)
        #expect(maker.wire.sent.count == 1)
    }

    /// Stopping one run leaves another run's preview waiting as it was.
    @Test func stopTakesAwayOnlyItsOwnPreview() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        let review = model.cloudReview
        #expect(model.lookInto(SampleSources.poolTopic))
        #expect(model.lookInto(SampleSources.libraryTopic))
        runner.advance(by: 12)
        await eventually { review.waiting.count == 2 }
        let stopped = try #require(review.pending?.run)
        model.stop(try #require(runner.tasks.first { $0.id == stopped }))
        #expect(review.waiting.count == 1)
        #expect(review.pending?.run != stopped)
        #expect(review.pending != nil)
        review.cancelPending()
        await runner.settleEverything()
        #expect(maker.wire.sent.isEmpty)
    }

    /// The last gate. A summary's work that was never cancelled, as when
    /// Stop raced it, reaches the point of sending after Stop: the yes is
    /// refused, so nothing goes and nothing is marked as sent.
    @Test func aYesHeardAfterStopIsRefused() async throws {
        let (model, engine, runner) = localToday()
        let gate = Gate()
        let heard = Heard()
        model.summarizer = { LateYesSummarizer(gate: gate, heard: heard) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 30)
        await eventually { runner.summariesMayLeaveDevice == 1 }
        #expect(runner.summariesMayLeaveDevice == 1)
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        await gate.open()
        await eventually { heard.answers.count == 1 }
        #expect(heard.answers == [false])
        #expect(!runner.sentToCloud(id))
        #expect(runner.summariesPastAYes == 0)
    }

    /// The control: with no Stop the same yes goes through, so the test
    /// above fails for the reason it says.
    @Test func aYesHeardWithNoStopGoesThrough() async throws {
        let (model, engine, runner) = localToday()
        let gate = Gate()
        let heard = Heard()
        model.summarizer = { LateYesSummarizer(gate: gate, heard: heard) }
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        engine.advance(by: 30)
        await gate.open()
        await eventually { heard.answers.count == 1 }
        #expect(heard.answers == [true])
        #expect(runner.sentToCloud(id))
    }

    // MARK: A Send stays marked as sent

    /// Send, the request leaves, then Stop. What was read may have gone,
    /// and that doesn't change: the card says so plainly, and Forget
    /// everything still says it can't be called back.
    @Test func stopAfterASendSaysWhatMayHaveGone() async throws {
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
        #expect(runner.sentToCloud(id))
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        await wire.gate.open()
        await runner.settleEverything()
        let card = try #require(runner.tasks.first { $0.id == id })
        #expect(card.state == .stopped)
        #expect(card.step == ReconWords.stoppedAfterSend)
        #expect(card.step.contains("may already have gone to the cloud"))
        #expect(runner.summary(for: id) == nil)
        // Still marked once it has stopped.
        #expect(runner.sentToCloud(id))
        #expect(runner.summariesPastAYes == 1)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
    }

    /// A summary Sent and landed, then tried again: the earlier round's
    /// words went, so the recon stays marked through the retry and its new
    /// preview, and Forget everything says they can't be called back.
    @Test func aRetryNeverUnmarksWhatWent() async throws {
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
        #expect(runner.sentToCloud(id))
        #expect(runner.summariesPastAYes == 1, "landed, and still marked")

        #expect(runner.retry(id))
        engine.finish(id)
        await eventually { review.pending != nil }
        #expect(runner.sentToCloud(id), "a retry never unmarks what went")
        #expect(runner.summariesPastAYes == 1)
        model.forgetTasks()
        #expect(model.forgotUnderway == ReconWords.forgotWhileInCloud)
        await runner.settleEverything()
        #expect(maker.wire.sent.count == 1)
    }

    /// A Stop with no Send says only that it stopped.
    @Test func stopBeforeAnySendSaysOnlyStopped() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        _ = await model.cloudReview.shown()
        model.stop(try #require(runner.tasks.first { $0.id == id }))
        await runner.settleEverything()
        runner.advance(by: 30)
        let card = try #require(runner.tasks.first { $0.id == id })
        #expect(card.state == .stopped)
        #expect(card.step == TaskWords.stopped)
        #expect(runner.summariesPastAYes == 0)
    }

    /// The stopped line says plainly that words may have left, and the
    /// words people see keep the house rules.
    @Test func theStoppedAfterSendLineIsPlain() {
        let line = ReconWords.stoppedAfterSend
        #expect(line.hasPrefix(TaskWords.stopped))
        #expect(line.contains("may already have gone to the cloud"))
        #expect(!line.contains("Nothing went"))
        #expect(ReconWords.all.contains(line))
        #expect(ReconWords.cloudStopped.contains("may already have gone to the cloud"))
    }

    // MARK: A swipe down is a no

    /// Swiping the sheet down is the person choosing not to send what it
    /// showed: Don't send, never "taken away before you answered".
    @Test func swipingThePreviewDownAnswersDontSend() async throws {
        let review = CloudReview()
        let shown = preview(run: "task:1")
        let answer = Task { await review.review(shown) }
        #expect(await review.shown() == shown)
        CloudPreviewPresenter.closed(review, presented: shown.id, blocked: false)
        #expect(await answer.value == .cancel)
        #expect(review.pending == nil)
    }

    /// Two wait. Send answers the first, and the second takes its place.
    /// The sheet that showed the first closing then says nothing about the
    /// second, which it never showed: that one still waits for its answer.
    @Test func closingTheSentPreviewsSheetLeavesTheNextWaiting() async throws {
        let review = CloudReview()
        let first = preview(run: "task:1")
        let second = preview(run: "task:2")
        let firstAnswer = Task { await review.review(first) }
        #expect(await review.shown() == first)
        let secondAnswer = Task { await review.review(second) }
        await eventually { review.waiting.count == 2 }
        review.answer(.send, for: first.id)
        #expect(await firstAnswer.value == .send)
        #expect(review.pending == second)
        CloudPreviewPresenter.closed(review, presented: first.id, blocked: false)
        #expect(review.pending == second)
        #expect(review.waiting == [second])
        // Its own sheet closing is a no for it.
        CloudPreviewPresenter.closed(review, presented: second.id, blocked: false)
        #expect(await secondAnswer.value == .cancel)
    }

    /// A preview held back by another sheet was never on screen, so closing
    /// that other sheet answers nothing for it.
    @Test func aPreviewHeldBackIsLeftWaiting() async throws {
        let review = CloudReview()
        let held = preview(run: nil)
        let answer = Task { await review.review(held) }
        #expect(await review.shown() == held)
        CloudPreviewPresenter.closed(review, presented: held.id, blocked: true)
        #expect(review.pending == held)
        review.answer(.send, for: held.id)
        #expect(await answer.value == .send)
    }

    /// On Today, a swipe down leaves the card's note saying the person
    /// chose not to send it.
    @Test func aSwipeOnTodaysPreviewIsSaidAsDontSend() async throws {
        let maker = TransportMaker()
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        let (model, runner, _) = try cloudToday(transport: { maker.make() }, notes: notes)
        #expect(model.lookInto(SampleSources.poolTopic))
        let id = try #require(runner.tasks.first?.id)
        runner.advance(by: 12)
        let shown = await model.cloudReview.shown()
        CloudPreviewPresenter.closed(model.cloudReview, presented: shown.id, blocked: false)
        await runner.settle(id)
        runner.advance(by: 30)
        #expect(runner.summary(for: id)?.note == ReconWords.declinedCloud)
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: The README says what Remember does

    /// The README's lines about remembering a point, each held to what the
    /// code does: no point from examples can be kept, and a point worded in
    /// the cloud is labelled with no publisher.
    @Test func theReadmesRememberLinesAreTrue() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let text = readme.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(!text.contains("or pick a point to remember."), "Remember isn't offered on every card")
        #expect(text.contains("no point from them can be remembered"))
        #expect(text.contains("A card that wasn't read from examples also offers to remember a point."))
        #expect(text.contains("\"\(MemorySource.lookedUp("").label)\""))

        // The only sources are examples, and their points can't be kept.
        #expect(ReconTestData.sources.isSample)
        let (model, engine, runner) = localToday()
        #expect(model.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        let id = try #require(runner.tasks.first?.id)
        let summary = try #require(runner.summary(for: id))
        #expect(!model.canRemember(summary))
        let notes = ShowcaseScene.emptyMemory()
        defer { discard(notes) }
        for point in summary.points {
            #expect(try notes.remember(point, from: summary) == .notKept)
        }
        // Once real pages are read, a point worded in the cloud names no
        // publisher.
        let task = try #require(ReconTask(topic: SampleSources.poolTopic))
        let real = summary.sources.map {
            ReconSource(id: $0.id, title: $0.title, publisher: $0.publisher, url: $0.url, published: $0.published,
                        text: $0.text)
        }
        let worded = try #require(CloudReconSummarizer.parse(
            "POINT: The pool reopens on November 10. [1]", task: task,
            id: "task:9", sources: real, gatheredAt: morning))
        let point = try #require(worded.points.first)
        #expect(worded.memorySource(for: point)?.label == MemorySource.lookedUp("").label)
        #expect(worded.note(for: point)?.contains(ReconWords.wordedInCloudMark) == true)
        // And one put together on the device names its first source.
        let made = LocalReconSummarizer().summary(task, id: "task:8", sources: real, gatheredAt: morning)
        let first = try #require(made.points.first)
        let publisher = try #require(first.sourceIDs.first.flatMap(made.source)?.publisher)
        #expect(made.memorySource(for: first)?.label == "From \(publisher)")
    }

    /// Today reading the example pages, on this device, with no cloud.
    func localToday() -> (FeedModel, LocalFakeEngine, ReconRunner) {
        let engine = LocalFakeEngine(rule: .isolated(), origin: morning)
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources)
        let model = FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: .isolated()), tasks: runner,
                              place: .onDevice, now: { [morning] in morning })
        return (model, engine, runner)
    }
}

/// What each yes was answered, from any thread.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    var answers: [Bool] { lock.withLock { seen } }
    func note(_ answer: Bool) { lock.withLock { seen.append(answer) } }
}

/// Waits for the gate, then says the person's yes is in, as a cloud
/// summarizer does just before its request goes, and notes the answer.
/// It never checks for cancellation, so it stands for work a Stop didn't
/// reach in time.
struct LateYesSummarizer: ReconSummarizer {
    let gate: Gate
    let heard: Heard
    var mayUseCloud: Bool { true }

    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        await gate.wait()
        heard.note(CloudYes.heard?() ?? false)
        return LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}
#endif
