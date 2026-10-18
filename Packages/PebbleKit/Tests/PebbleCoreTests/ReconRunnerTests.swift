import Foundation
@testable import PebbleCore
import ReconTestSupport
import Testing

/// The runner's promises about when a summary is begun, kept, let go and
/// begun again, on the scripted engine and on one that shows no steps. An
/// engine that picks its own steps never gets a recon at all. The whole
/// suite has a time limit, so an await that never ends fails, not hangs.
@Suite(.timeLimit(.minutes(1)))
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

    @Test func onAnEngineThatShowsNoStepsItBeginsWhenTheEngineIsDone() throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.libraryTopic))
        #expect(runner.held(id)?.begun == false)
        engine.finish(id)
        #expect(runner.held(id)?.hasSummary == true)
        #expect(runner.summary(for: id) != nil)
    }

    /// An engine that picks its own steps would take the topic as work of
    /// its own, so no recon is started there and the engine is never asked.
    @Test func anEngineThatPicksItsOwnStepsGetsNoRecon() {
        let engine = OwnStepsEngine()
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        #expect(runner.lookInto(SampleSources.poolTopic) == nil)
        #expect(engine.started.isEmpty)
        #expect(runner.tasks.isEmpty)
        // Its own work still passes through.
        let id = runner.start(TaskRequest(title: "Book the car service"))
        #expect(engine.started == ["Book the car service"])
        #expect(!runner.isRecon(id))
    }

    /// The runner says up front whether a start could happen, so a chat
    /// never offers what every tap would refuse.
    @Test func theRunnerSaysWhetherItCanStartOne() {
        #expect(ReconRunner(engine: ReplayEngine(), provider: Self.sources).canLookInto)
        #expect(ReconRunner(engine: LocalFakeEngine(rule: .isolated()), provider: Self.sources).canLookInto)
        // An engine that picks its own steps, or pages that leave the device: never.
        #expect(!ReconRunner(engine: OwnStepsEngine(), provider: Self.sources).canLookInto)
        #expect(!ReconRunner(engine: ReplayEngine(), provider: RecordingProvider()).canLookInto)
    }

    // MARK: Stop keeps nothing

    /// What a recon whose summary is still coming can be stopped with, and
    /// the summary that would come back for it.
    func waitingRecon(_ engine: ReplayEngine) throws -> (ReconRunner, String, ReconSummary) {
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: Gate())))
        let task = try #require(ReconTask(topic: SampleSources.poolTopic))
        let late = LocalReconSummarizer().summary(task, id: id, sources: try Self.sources.sources(for: task),
                                                  gatheredAt: Self.readOn)
        return (runner, id, late)
    }

    /// The engine has finished and the card waits only on its summary.
    /// Stop is tapped; the engine answers that it had nothing running, and
    /// before the runner has stopped the card itself, the summary lands. It
    /// is dropped: Stop wins. The round is read from the runner, so the
    /// summary would land if no stop were under way (see the control).
    @Test func stopWinsOverASummaryThatLandsBeforeTheRunnerHasStopped() throws {
        let engine = ReplayEngine()
        let (runner, id, late) = try waitingRecon(engine)
        engine.finish(id)
        let held = try #require(runner.held(id))
        #expect(held.working)
        engine.duringStop = { [runner] stopping in runner.finish(stopping, round: held.round, with: late) }
        #expect(runner.stop(id))
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.summary(for: id) == nil)
        #expect(runner.held(id)?.hasSummary == false)
        #expect(runner.held(id)?.sources == 0)
    }

    /// The engine was still playing the card when Stop was tapped. It
    /// stops it, and the summary lands after that, before `stop` returns.
    /// It is dropped too.
    @Test func stopWinsOverASummaryThatLandsAfterTheEngineStopped() throws {
        let engine = ReplayEngine()
        let (runner, id, late) = try waitingRecon(engine)
        engine.show(id, step: ReconWords.puttingTogether)
        let held = try #require(runner.held(id))
        #expect(held.working)
        engine.duringStop = { [runner] stopping in runner.finish(stopping, round: held.round, with: late) }
        #expect(runner.stop(id))
        #expect(engine.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.summary(for: id) == nil)
        #expect(runner.held(id)?.hasSummary == false)
    }

    /// The control: the very same call, with no stop under way, lands. So
    /// the tests above are dropped by Stop, not by a stale round.
    @Test func theSameSummaryLandsWhenNothingIsStopping() throws {
        let engine = ReplayEngine()
        let (runner, id, late) = try waitingRecon(engine)
        engine.finish(id)
        let held = try #require(runner.held(id))
        runner.finish(id, round: held.round, with: late)
        #expect(runner.held(id)?.hasSummary == true)
        #expect(runner.summary(for: id) == late)
        #expect(runner.tasks.first { $0.id == id }?.state == .done)
        // A round that isn't the live one is dropped. Read from this
        // runner, so it never leans on two runners starting alike.
        let (other, otherID, otherLate) = try waitingRecon(ReplayEngine())
        other.finish(otherID, round: try #require(other.held(otherID)).round + 1, with: otherLate)
        #expect(other.held(otherID)?.hasSummary == false)
    }

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

    /// The pages are read once, as the recon starts, and never again: what
    /// was read goes at Stop, and nothing reads more after it.
    @Test func stoppingBeforeAnyStepKeepsNoSourceText() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let provider = CountingProvider(now: { Self.readOn })
        let runner = ReconRunner(engine: engine, provider: provider)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(provider.asked == 1)
        // `sources` is the count of the very pages the run still holds, so
        // 0 means their text has been let go, not only that none are counted.
        #expect(runner.held(id)?.sources == 4)
        #expect(runner.stop(id))
        #expect(runner.held(id)?.sources == 0)
        engine.advance(by: 60)
        #expect(runner.held(id)?.begun == false)
        #expect(runner.held(id)?.sources == 0)
        #expect(provider.asked == 1)
    }

    // MARK: Forget everything while a recon starts

    /// Forget everything lands while the pages are being read, before the
    /// engine has the task. Nothing read is kept, and no card is left.
    @Test func forgettingEverythingWhileTheSourcesAreReadKeepsNothing() throws {
        let engine = ReplayEngine()
        let provider = CountingProvider(now: { Self.readOn })
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        provider.whileReading = { [runner] in _ = runner.clear() }
        #expect(runner.lookInto(SampleSources.poolTopic) == nil)
        #expect(provider.asked == 1)
        #expect(runner.tasks.isEmpty)
        #expect(engine.tasks.isEmpty)
        #expect(runner.summariesMayLeaveDevice == 0)
        // The control: the same start with nothing forgotten keeps its run.
        provider.whileReading = nil
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.held(id)?.sources == 4)
    }

    /// Forget everything lands as the engine tells its watchers about the
    /// new task, before the runner has noted it. The run is never kept.
    @Test func forgettingEverythingAsTheTaskStartsKeepsNothing() throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: CountingProvider(now: { Self.readOn }), now: { Self.readOn })
        let forgot = ForgetOnce()
        let watch = runner.observe { [runner] snapshot in
            if !snapshot.tasks.isEmpty, forgot.first() { _ = runner.clear() }
        }
        defer { watch.cancel() }
        let id = runner.lookInto(SampleSources.poolTopic)
        #expect(forgot.done)
        #expect(id == nil)
        #expect(runner.tasks.isEmpty)
        #expect(engine.tasks.isEmpty)
        // Nothing held for it under any id, and its topic is let go.
        #expect(runner.heldCount == (runs: 0, starting: 0))
    }

    // MARK: One recon per topic, decided in the runner

    /// Two asks for one topic at once, as a double tap or the feed and a
    /// chat together, in any case: one engine task between them. The
    /// second is told one is already on its way.
    @Test func twoAsksAtOnceStartOneRecon() throws {
        let engine = ReplayEngine()
        let provider = CountingProvider(now: { Self.readOn })
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        let second = Answers()
        // The second ask lands while the first is reading its pages, before
        // the engine has its task.
        provider.whileReading = { [runner] in
            provider.whileReading = nil
            second.add(runner.start(lookingInto: "The Riverside Pool Reopening?", with: Leaving()))
        }
        let first = runner.start(lookingInto: SampleSources.poolTopic, with: Leaving())
        let id = try #require(first.startedID)
        #expect(second.list == [.already(id: nil, mayUseCloud: true)])
        #expect(engine.tasks.count == 1)
        #expect(provider.asked == 1)
        // Once noted, an ask names it, whatever its case, and starts nothing.
        #expect(runner.start(lookingInto: "the riverside pool REOPENING") == .already(id: id, mayUseCloud: true))
        engine.finish(id)
        #expect(runner.start(lookingInto: SampleSources.poolTopic) == .already(id: id, mayUseCloud: true))
        #expect(runner.lookInto(SampleSources.poolTopic) == nil)
        #expect(engine.tasks.count == 1)
        #expect(runner.heldCount == (runs: 1, starting: 0))
        // Another topic still starts.
        #expect(runner.start(lookingInto: SampleSources.libraryTopic).startedID != nil)
        #expect(engine.tasks.count == 2)
    }

    /// The same, on many threads at once: exactly one engine task.
    @Test func manyAsksOnManyThreadsStartOneRecon() {
        for _ in 0..<20 {
            let engine = ReplayEngine()
            let runner = ReconRunner(engine: engine, provider: CountingProvider(now: { Self.readOn }), now: { Self.readOn })
            let answers = Answers()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                answers.add(runner.start(lookingInto: index.isMultiple(of: 2) ? SampleSources.poolTopic
                                                       : SampleSources.poolTopic.uppercased()))
            }
            #expect(engine.tasks.count == 1)
            #expect(answers.list.compactMap(\.startedID).count == 1)
            #expect(answers.list.filter { $0.startedID == nil }.allSatisfy {
                if case .already = $0 { return true }
                return false
            })
            #expect(runner.heldCount == (runs: 1, starting: 0))
        }
    }

    /// One that stopped, failed or was let go can be asked for again, and a
    /// topic claimed when everything was forgotten is let go with it.
    @Test func anEndedReconLetsItsTopicBeAskedAgain() throws {
        let engine = ReplayEngine()
        let provider = CountingProvider(now: { Self.readOn })
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        let stopped = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.stop(stopped))
        let again = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(again != stopped)
        engine.finish(again)
        #expect(runner.dismiss(again))
        #expect(runner.lookInto(SampleSources.poolTopic) != nil)
        // Forgotten while it was being started: the topic isn't held.
        _ = runner.clear()
        provider.whileReading = { [runner] in _ = runner.clear() }
        #expect(runner.lookInto(SampleSources.poolTopic) == nil)
        provider.whileReading = nil
        #expect(runner.heldCount == (runs: 0, starting: 0))
        #expect(runner.lookInto(SampleSources.poolTopic) != nil)
    }

    // MARK: Forget everything and a summary on its way

    /// A summary begun before Forget everything comes back after it, when
    /// the engine has given a newer card the same id. It never lands there:
    /// what it read was forgotten.
    @Test func aSummaryFromBeforeForgetEverythingNeverLandsOnANewerCard() async throws {
        let engine = ReplayEngine(reusesIDs: true)
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let (_, _, late) = try waitingRecon(ReplayEngine())
        let held = Gate()
        let old = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: held)))
        engine.finish(old)
        let begun = try #require(runner.held(old))
        #expect(begun.working)
        _ = runner.clear()
        let new = try #require(runner.lookInto(SampleSources.libraryTopic))
        #expect(new == old)
        engine.finish(new)
        #expect(runner.held(new)?.round == begun.round)
        #expect(runner.summary(for: new)?.topic == SampleSources.libraryTopic)
        // The old work itself finishes now, after the forget, through its
        // own path: its pool summary never lands on the library card.
        await held.open()
        await runner.settleEverything()
        #expect(runner.summary(for: new)?.topic == SampleSources.libraryTopic)
        #expect(runner.summary(for: new)?.sources.map(\.id) != late.sources.map(\.id))
        // The pool summary comes back late, past its work's own check, as
        // the forget lands: the same id and round, an older generation.
        runner.finish(new, round: begun.round, generation: begun.generation, with: late)
        #expect(runner.summary(for: new)?.topic == SampleSources.libraryTopic)
        // The control: the same call in the live generation lands.
        runner.finish(new, round: begun.round, generation: try #require(runner.held(new)).generation, with: late)
        #expect(runner.summary(for: new)?.topic == SampleSources.poolTopic)
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

    /// The engine plays the same script again, but the card says how many
    /// sources this try read.
    @Test func aRetryShowsHowManySourcesItReadThisTime() throws {
        let engine = ReplayEngine()
        let provider = ShrinkingProvider()
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.show(id, step: ReconWords.reading(4))
        #expect(runner.tasks.first { $0.id == id }?.step == ReconWords.reading(4))
        #expect(runner.stop(id))
        provider.limit = 2
        #expect(runner.retry(id))
        #expect(runner.held(id)?.sources == 2)
        engine.show(id, step: ReconWords.reading(4), kept: [ReconWords.keptQuestions, ReconWords.keptSources(4)])
        let shown = try #require(runner.tasks.first { $0.id == id })
        #expect(shown.step == ReconWords.reading(2))
        #expect(shown.wrapUp?.kept == [ReconWords.keptQuestions, ReconWords.keptSources(2)])
        engine.finish(id)
        #expect(runner.summary(for: id) != nil)
    }

    /// A retry that finds no sources at all never says "Reading 0 sources"
    /// or keeps "0 sources". It says it is looking, then that it found nothing.
    @Test func aRetryThatFindsNothingSaysItIsLooking() throws {
        let engine = ReplayEngine()
        let provider = ShrinkingProvider()
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.stop(id))
        provider.limit = 0
        #expect(runner.retry(id))
        #expect(runner.held(id)?.sources == 0)
        engine.show(id, step: ReconWords.reading(4), kept: [ReconWords.keptQuestions, ReconWords.keptSources(4)])
        let shown = try #require(runner.tasks.first { $0.id == id })
        #expect(shown.step == ReconWords.looking)
        #expect(shown.wrapUp?.kept == [ReconWords.keptQuestions])
        engine.finish(id)
        let done = try #require(runner.tasks.first { $0.id == id })
        #expect(done.step == ReconWords.nothingFoundLine)
        #expect(runner.summary(for: id)?.points.isEmpty == true)
    }

    /// The other way round: the first try found nothing, and the engine
    /// plays that script again, which ends on "I couldn't find anything".
    /// This try read pages and found points, so the card says it did.
    @Test func aRetryThatFindsPointsSaysHeresWhatIFound() throws {
        let engine = ReplayEngine()
        let provider = ShrinkingProvider()
        provider.limit = 0
        let runner = ReconRunner(engine: engine, provider: provider, now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.finish(id)
        #expect(runner.tasks.first { $0.id == id }?.step == ReconWords.nothingFoundLine)
        provider.limit = nil
        #expect(runner.retry(id))
        engine.show(id, step: ReconWords.nothingFoundLine)
        engine.finish(id)
        let done = try #require(runner.tasks.first { $0.id == id })
        #expect(try #require(runner.summary(for: id)).points.isEmpty == false)
        #expect(done.step == ReconWords.doneLine)
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

    @Test(.timeLimit(.minutes(1)))
    func theCapCancelsASummaryStillWaitingSoNoPreviewOutlivesItsCard() async throws {
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

    /// Made up news must never reach the notes as if it were real. Every
    /// kind of example recon, from the one shared list, finishes with
    /// points, and none may be kept. The real one, the control, may.
    @Test func noPointFromAnExampleMayBeKept() throws {
        for played in exampleRecons(at: Self.readOn) + [realRecon(at: Self.readOn)] {
            let runner = played.runner
            let id = try #require(runner.lookInto(SampleSources.poolTopic), "\(played.name)")
            played.advance(30)
            let summary = try #require(runner.summary(for: id), "\(played.name)")
            #expect(!summary.points.isEmpty, "\(played.name)")
            let real = played.name == "real"
            #expect(runner.isSample(id) == !real, "\(played.name)")
            #expect(runner.keepsPoints(id) == real, "\(played.name)")
            // The summary itself says so, so a caller that never asks
            // `keepsPoints` still can't make a note of it.
            #expect(summary.isSample == !real, "\(played.name)")
            let memory = ReconTests.scratchStore()
            defer { ReconTests.throwAway(memory) }
            for point in summary.points {
                #expect((summary.note(for: point) == nil) == !real, "\(played.name): \(point.text)")
                #expect((summary.memorySource(for: point) == nil) == !real, "\(played.name): \(point.text)")
                let kept = try memory.remember(point, from: summary)
                if real {
                    guard case .saved = kept else {
                        Issue.record("the real control kept nothing: \(point.text)")
                        continue
                    }
                } else {
                    #expect(kept == .notKept, "\(played.name): \(point.text)")
                }
            }
            #expect(memory.notes().count == (real ? summary.points.count : 0), "\(played.name)")
        }
        // A task that isn't a recon has no points to keep.
        let real = realRecon(at: Self.readOn).runner
        #expect(!real.keepsPoints(real.start(TaskRequest(title: "Book the car service"))))
    }

    /// The summary itself carries that it is an example, so no caller can
    /// make a note of its points, whether or not it asks `keepsPoints`.
    /// It is stamped from the provider at the start, even when the
    /// summarizer hands back pages that don't say so.
    @Test func anExampleSummaryIsStampedWhoeverPutItTogether() async throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: UnmarkedExamples(), now: { Self.readOn })
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: UnmarkingSummarizer()))
        engine.finish(id)
        await runner.settle(id)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.sources.allSatisfy { !$0.isSample })
        #expect(summary.isSample)
        let point = try #require(summary.points.first)
        #expect(summary.note(for: point) == nil)
        #expect(summary.memorySource(for: point) == nil)
        #expect(runner.isSample(id))
        #expect(!runner.keepsPoints(id))
    }

    /// An example summary rebuilt through the initializer, as a summarizer
    /// might, from the pages it was given: those pages say they are
    /// examples, so the rebuilt one is still one.
    @Test func aRebuiltExampleSummaryIsStillOne() throws {
        let stamped = try ReconTests.summary(SampleSources.poolTopic)
        #expect(stamped.isSample)
        let rebuilt = ReconSummary(id: stamped.id, topic: stamped.topic, overview: stamped.overview,
                                   points: stamped.points, sources: stamped.sources, gatheredAt: stamped.gatheredAt,
                                   madeOnDevice: stamped.madeOnDevice, note: stamped.note)
        #expect(rebuilt.isSample)
        let point = try #require(rebuilt.points.first)
        #expect(rebuilt.note(for: point) == nil)
        // Pages that don't say so are stamped by the runner instead, as
        // `anExampleSummaryIsStampedWhoeverPutItTogether` shows.
    }

    /// One lookup for "already on it", on the topic as a task tidies it,
    /// for the feed and every chat alike. Stopped ones don't count.
    @Test func theRunnerKnowsATopicItIsAlreadyOn() throws {
        let engine = ReplayEngine()
        let runner = ReconRunner(engine: engine, provider: Self.sources, now: { Self.readOn })
        let id = try #require(runner.lookInto("the Riverside pool reopening"))
        #expect(runner.activeRecon(for: "The Riverside  pool reopening?") == id)
        #expect(runner.activeRecon(for: "the library's new Sunday hours") == nil)
        #expect(runner.activeRecon(for: "") == nil)
        engine.finish(id)
        #expect(runner.activeRecon(for: SampleSources.poolTopic) == id)
        #expect(runner.dismiss(id))
        #expect(runner.activeRecon(for: SampleSources.poolTopic) == nil)
        let stopped = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.stop(stopped))
        #expect(runner.activeRecon(for: SampleSources.poolTopic) == nil)
        // A task of the engine's own with the same title is not a recon.
        runner.start(TaskRequest(title: ReconWords.title(SampleSources.poolTopic)))
        #expect(runner.activeRecon(for: SampleSources.poolTopic) == nil)
    }

    /// With no clock given, a runner on any engine but the scripted one
    /// reads the wall clock for when the pages were read.
    @Test func theDefaultClockIsTheWallClock() throws {
        // Long ago, so its scripted clock could never pass for now.
        let inner = LocalFakeEngine(rule: .isolated(), origin: Date(timeIntervalSinceReferenceDate: 0))
        let runner = ReconRunner(engine: PlainEngine(inner), provider: PagesNotExamples(now: { Self.readOn }))
        let before = Date()
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        inner.advance(by: 60)
        let summary = try #require(runner.summary(for: id))
        let after = Date()
        #expect(summary.gatheredAt >= before)
        #expect(summary.gatheredAt <= after)
    }

    /// The scripted engine as the home screen makes it, with card times
    /// from the wall clock: its steps play on its own clock alone. With
    /// the wall still, they play through; with only the wall moving,
    /// nothing moves on. The wall clock is read only for times on cards.
    @Test func stepsPlayOnTheEnginesClockAndCardsTellTheWallTime() throws {
        let wall = HandClock(Self.readOn)
        let still = LocalFakeEngine(rule: .isolated(), wallClock: { wall.now })
        let runner = ReconRunner(engine: still, provider: Self.sources, now: { wall.now })
        let id = try #require(runner.lookInto(SampleSources.libraryTopic))
        still.advance(by: 30)
        let done = try #require(runner.tasks.first { $0.id == id })
        #expect(done.state == .done)
        #expect(done.startedAt == Self.readOn)
        #expect(done.updatedAt == Self.readOn)
        #expect(runner.summary(for: id)?.gatheredAt == Self.readOn)

        let moving = LocalFakeEngine(rule: .isolated(), wallClock: { wall.now })
        let other = ReconRunner(engine: moving, provider: Self.sources, now: { wall.now })
        let waiting = try #require(other.lookInto(SampleSources.poolTopic))
        wall.now = Self.readOn + 3_600
        moving.refresh()
        let shown = try #require(other.tasks.first { $0.id == waiting })
        #expect(shown.state == .running)
        #expect(shown.step == ReconWords.planning)
        #expect(other.held(waiting)?.begun == false)
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
        // A note of its own never takes the cloud's line away: it follows it.
        let noted = ReconSummary(id: "t", topic: "the pool", overview: "Words.",
                                 points: [ReconPoint(id: "a", text: "Retold.", sourceIDs: [page.id])],
                                 sources: [page], gatheredAt: Self.readOn, madeOnDevice: false,
                                 note: "Two of the pages were short.")
        #expect(noted.note == "\(ReconWords.wordedInCloud) Two of the pages were short.")
        let same = ReconSummary(id: "t", topic: "the pool", overview: "Words.",
                                points: [ReconPoint(id: "a", text: "Retold.", sourceIDs: [page.id])],
                                sources: [page], gatheredAt: Self.readOn, madeOnDevice: false,
                                note: ReconWords.wordedInCloud)
        #expect(same.note == ReconWords.wordedInCloud)
    }

    /// The plain overview over the cloud's points says how many sources were
    /// read, never how many of its points cite more than one: those numbers
    /// are the cloud's. On the device it still counts them.
    @Test func aCloudOverviewDoesNotCountTheCloudsCitations() {
        let pages = Array(Self.sources.documents.prefix(2))
        let ids = pages.map(\.id)
        let points = [ReconPoint(id: "a", text: "Both say it.", sourceIDs: ids),
                      ReconPoint(id: "b", text: "Both say this too.", sourceIDs: ids)]
        let cloud = ReconSummary(id: "t", topic: "the pool", overview: "", points: points, sources: pages,
                                 gatheredAt: Self.readOn, madeOnDevice: false)
        #expect(cloud.overview == "I read 2 sources on the pool.")
        #expect(!cloud.overview.contains("more than one"))
        let device = ReconSummary(id: "t", topic: "the pool", overview: "", overviewSourceIDs: ["gone"], points: points,
                                  sources: pages, gatheredAt: Self.readOn, madeOnDevice: true)
        #expect(device.overview.contains("2 points come from more than one of them."))
    }

    /// Kept as a note, a point worded on this device names its source, as
    /// those are the page's own words. One worded in the cloud says it was,
    /// and names no publisher anywhere: which page the cloud said each line
    /// came from was never checked here.
    @Test func aRememberedPointSaysWhoWordedIt() throws {
        let page = notExample(Self.sources.documents[0])
        let point = ReconPoint(id: "a", text: "The pool reopens soon.", sourceIDs: [page.id])
        let local = ReconSummary(id: "t", topic: "the pool", overview: "", points: [point],
                                 sources: [page], gatheredAt: Self.readOn, madeOnDevice: true)
        #expect(local.memorySource(for: point) == .lookedUp("Riverside Gazette"))
        let localNote = try #require(local.note(for: point))
        #expect(localNote.contains("(Riverside Gazette, "))
        #expect(!localNote.contains("cloud"))
        let cloud = ReconSummary(id: "t", topic: "the pool", overview: "", points: [point],
                                 sources: [page], gatheredAt: Self.readOn, madeOnDevice: false)
        #expect(cloud.memorySource(for: point) == .lookedUp(""))
        #expect(cloud.memorySource(for: point)?.label == "From something I looked into")
        let cloudNote = try #require(cloud.note(for: point))
        #expect(cloudNote == "The pool reopens soon. (put into words in the cloud, from the sources it was given)")
        #expect(!cloudNote.contains("Riverside Gazette"))
    }

    /// A cloud-worded point whose disagreement is too long to keep whole
    /// is cut to a plain line that names no side either.
    @Test func aLongCloudDisputeNamesNoSide() throws {
        let pages = Self.sources.documents.prefix(2).map(notExample)
        let long = String(repeating: "Each page tells it a little differently. ", count: 14)
        let point = ReconPoint(id: "a", text: "The pool reopens in November.", sourceIDs: [pages[0].id],
                               disagreement: ReconDisagreement(text: long, sourceIDs: pages.map(\.id)))
        let cloud = ReconSummary(id: "t", topic: "the pool", overview: "", points: [point], sources: Array(pages),
                                 gatheredAt: Self.readOn, madeOnDevice: false)
        let kept = try #require(cloud.points.first)
        let note = try #require(cloud.note(for: kept))
        #expect(note.hasSuffix(ReconWords.disputedBy([])))
        #expect(!note.contains("Riverside Gazette"))
        #expect(!note.contains("City of Riverside Parks"))
        #expect(note.count <= MemoryStore.maxLength)
    }

    @Test func aPointOnlyOnOldPagesIsKnownAsOld() throws {
        let summary = try ReconTests.summary(SampleSources.poolTopic)
        let council = try #require(summary.points.first { $0.sourceIDs == ["sample:council-pool"] })
        #expect(summary.restsOnOldPages(council))
        #expect(!summary.points.filter { !$0.sourceIDs.contains("sample:council-pool") }.contains { summary.restsOnOldPages($0) })
    }
}

/// Reads the sample pages, on this device, but not as examples.
struct DeviceProvider: SourceProvider {
    var runsOnDevice: Bool { true }
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] {
        try ReconTests.sources.sources(for: task).map(notExample)
    }
}

/// Says it gives examples, but its pages don't say so themselves.
struct UnmarkedExamples: SourceProvider {
    var runsOnDevice: Bool { true }
    var isSample: Bool { true }
    func sources(for task: ReconTask) throws -> [ReconSource] {
        try ReconTests.sources.sources(for: task).map(notExample)
    }
}

/// Puts a summary together from pages it marks as real, as a careless
/// summarizer might.
struct UnmarkingSummarizer: ReconSummarizer {
    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        LocalReconSummarizer().summary(task, id: id, sources: sources.map(notExample), gatheredAt: gatheredAt)
    }
}

/// What each ask to look into something was told, from any thread.
final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ReconStart] = []
    var list: [ReconStart] { lock.lock(); defer { lock.unlock() }; return answers }
    func add(_ answer: ReconStart) { lock.lock(); answers.append(answer); lock.unlock() }
}

/// Puts the summary together here, but says it may leave the device, as
/// one through the cloud would.
struct Leaving: ReconSummarizer {
    var mayUseCloud: Bool { true }
    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}

/// True the first time it is asked, then false.
final class ForgetOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    var done: Bool { lock.lock(); defer { lock.unlock() }; return asked }
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if asked { return false }
        asked = true
        return true
    }
}

/// The sample pages, on this device, cut to `limit` once a test sets it,
/// as a page that went away between two reads would be.
final class ShrinkingProvider: SourceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cut: Int?
    var limit: Int? {
        get { lock.lock(); defer { lock.unlock() }; return cut }
        set { lock.lock(); cut = newValue; lock.unlock() }
    }
    var runsOnDevice: Bool { true }
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] {
        let all = try ReconTests.sources.sources(for: task).map(notExample)
        return limit.map { Array(all.prefix($0)) } ?? all
    }
}

/// On this device, and can't be read.
struct FailingProvider: SourceProvider {
    struct Unreadable: Error {}
    var runsOnDevice: Bool { true }
    var isSample: Bool { false }
    func sources(for task: ReconTask) throws -> [ReconSource] { throw Unreadable() }
}
