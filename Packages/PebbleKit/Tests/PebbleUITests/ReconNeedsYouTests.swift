#if canImport(SwiftUI)
import Foundation
import PebbleCore
import ReconTestSupport
import Testing
@testable import PebbleUI

/// Looking into something beside the Needs you flow: a recon is a task
/// like any other on Today, but it is never kept while the app is closed,
/// and one Forget everything takes recons, receipts and kept tasks together,
/// in every window.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReconNeedsYouTests {
    static let morning = ShowcaseScene.morning

    /// One window's Today: a runner over its own scripted engine, as the
    /// home screen makes it, with the flow around it.
    private func window(flow: NeedsYouFlow, rule: AskFirst = .isolated())
        -> (FeedModel, LocalFakeEngine, ReconRunner) {
        let engine = LocalFakeEngine(rule: rule, origin: Self.morning)
        let runner = ReconRunner(engine: engine, provider: ReconTestData.sources)
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: runner, place: .onDevice,
                              flow: flow, now: { Self.morning + engine.now })
        return (model, engine, runner)
    }

    private func flow(_ store: TaskStore) -> NeedsYouFlow {
        NeedsYouFlow(store: store, notifier: ShowcaseScene.StillNotifier(), agentName: { "Pip" })
    }

    private func receipts(_ model: FeedModel) -> [Receipt] {
        model.feed.groups.flatMap(\.items).compactMap(\.receipt)
    }

    /// PERMANENT GUARD. The engine's own tasks are kept while the app is
    /// closed through the runner, and a recon never is: what it read lives
    /// only in memory, and its topic is never written down.
    @Test func theRunnerKeepsTheEnginesTasksButNeverARecon() async throws {
        let store = TaskStore.inMemory()
        let (model, engine, runner) = window(flow: flow(store))
        engine.start(SampleTasks.dentist)
        let recon = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.advance(by: 10)
        await model.settled()
        let dentist = try #require(engine.tasks.first { $0.title == SampleTasks.dentistTitle }?.id)
        #expect(store.tasks.map(\.id) == [dentist])
        #expect(!store.tasks.contains { $0.id == recon })
        #expect(!runner.saved().contains { $0.id == recon })
        #expect(!store.tasks.contains { $0.title.localizedCaseInsensitiveContains("pool") })
    }

    /// PERMANENT GUARD. One Forget everything takes a receipt, a kept task
    /// and a recon together, and says what went.
    @Test func forgetEverythingTakesReceiptsKeptTasksAndReconsTogether() async throws {
        let store = TaskStore.inMemory()
        let (model, engine, runner) = window(flow: flow(store))
        engine.start(SampleTasks.dentist)
        engine.advance(by: 42)
        let task = try #require(FeedModel.pinnedTasks(in: model.feed).first)
        model.review(task)
        let request = try #require(model.reviewing)
        guard case .approved(let approval) = model.rule.sayYes(to: request) else { throw CancellationError() }
        model.approved(approval)
        engine.advance(by: 4)
        #expect(runner.lookInto(SampleSources.poolTopic) != nil)
        engine.advance(by: 2)
        await model.settled()
        #expect(receipts(model).count == 1)
        #expect(!store.receipts.isEmpty)

        let cleared = model.forgetEverything()
        await model.settled()
        #expect(cleared.forgotten == 2)
        #expect(runner.tasks.isEmpty)
        #expect(receipts(model).isEmpty)
        #expect(store.receipts.isEmpty)
        #expect(store.tasks.isEmpty)
        #expect(model.tasksForgotten)
        #expect(!model.hasSomethingToForget)
    }

    /// PERMANENT GUARD. Each window runs its own recons, so Forget
    /// everything in one window forgets the recons of every other, and
    /// that window says its tasks are gone too.
    @Test func forgetEverythingInOneWindowForgetsTheOthersRecons() async throws {
        let store = TaskStore.inMemory()
        let shared = flow(store)
        let (first, _, _) = window(flow: shared)
        let (second, engine, runner) = window(flow: shared)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        await second.settled()
        #expect(runner.summary(for: id) != nil)

        first.forgetTasks()
        await first.settled()
        await second.settled()
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
        #expect(runner.summary(for: id) == nil)
        #expect(second.feed.groups.isEmpty)
        #expect(second.tasksForgotten)
    }

    /// A summary past the person's yes to the cloud, forgotten from another
    /// window, still gets its honest line in the window it was in.
    @Test func aCloudSummaryForgottenFromAnotherWindowSaysItMayHaveGone() async throws {
        let shared = flow(TaskStore.inMemory())
        let (first, _, _) = window(flow: shared)
        let (second, engine, runner) = window(flow: shared)
        let gate = Gate()
        second.summarizer = { HeldSummarizer(gate: gate, mark: ThreadMark(), leaves: true, saysYes: true) }
        #expect(second.lookInto(SampleSources.poolTopic))
        engine.advance(by: 30)
        await eventually { runner.summariesPastAYes == 1 }
        #expect(runner.summariesPastAYes == 1)

        first.forgetTasks()
        await first.settled()
        await second.settled()
        #expect(first.forgotUnderway == nil, "nothing of the first window's went to the cloud")
        #expect(second.forgotUnderway == ReconWords.forgotWhileInCloud)
        #expect(runner.tasks.isEmpty)
        await gate.open()
        await runner.settleEverything()
        #expect(runner.tasks.isEmpty)
    }
}
#endif
