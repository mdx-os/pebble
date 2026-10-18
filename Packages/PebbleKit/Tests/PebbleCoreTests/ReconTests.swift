import Foundation
@testable import PebbleCore
import ReconTestSupport
import Testing

struct ReconTests {
    static let readOn = SampleSources.day(2026, 10, 17)
    /// The sample pages, read on `readOn`.
    static let sources = SampleSources(now: { readOn })

    static func summary(_ topic: String) throws -> ReconSummary {
        let task = try #require(ReconTask(topic: topic))
        let sources = try Self.sources.sources(for: task)
        return LocalReconSummarizer().summary(task, id: "task:1", sources: sources, gatheredAt: readOn)
    }

    // MARK: Phrasing

    @Test(arguments: [
        ("look into the Riverside pool reopening for me", "the Riverside pool reopening"),
        ("Look into the Riverside pool reopening.", "the Riverside pool reopening"),
        ("Can you look into heat pumps for our house?", "heat pumps for our house"),
        ("could you please research the school's new start times", "the school's new start times"),
        ("Research quiet dishwashers", "quiet dishwashers"),
        ("Please find out about the library's new Sunday hours", "the library's new Sunday hours"),
        ("find out more about the bus strike for me please", "the bus strike"),
        ("Hey Pip, look into flu shots near us", "flu shots near us"),
        ("help me read up on composting", "composting"),
        ("I\u{2019}d like you to dig into the hydro bill", "the hydro bill"),
        // "would you mind" comes off whole, ahead of the shorter "would you".
        ("Would you mind looking into the bus strike?", "the bus strike"),
        ("would you mind researching quiet dishwashers for me", "quiet dishwashers"),
        ("Would you mind, please look into flu shots near us", "flu shots near us"),
    ])
    func asksToLookIntoSomething(said: String, topic: String) {
        #expect(ReconIntent.topic(in: said) == topic)
    }

    @Test(arguments: [
        "Research shows coffee is fine",
        "research says sleep matters",
        "I looked into it yesterday",
        "I need to research this later",
        "Find me a dentist open Saturdays",
        "What did you find out?",
        "Let's look at the plan for tomorrow",
        "Please look into it",
        "look into this for me",
        "Can you look into",
        "Plan my morning",
        "So sorry, I'm late",
        "Remind me about the pool",
        // Without "would you mind" before it, "looking into" is a statement.
        "Looking into the pool was fun",
        "Researching quiet dishwashers took all day",
        "",
    ])
    func ordinarySentencesAreNotRequests(said: String) {
        #expect(ReconIntent.topic(in: said) == nil)
    }

    // MARK: Care comes first

    @Test(arguments: [
        "look into how to kill myself",
        "Can you research ways to end my life",
        "find out about overdose amounts for me",
        "research suicide methods",
    ])
    func wordsOfCrisisNeverBecomeATask(said: String) {
        #expect(CareCheck.needsCare(said))
        #expect(ReconIntent.topic(in: said) == nil)
        #expect(ReconTask(topic: said) == nil)
        let runner = ReconRunner(engine: LocalFakeEngine(rule: .isolated()), provider: Self.sources)
        #expect(runner.lookInto(said) == nil)
        #expect(runner.tasks.isEmpty)
    }

    // MARK: Every point has a source

    @Test(arguments: [SampleSources.poolTopic, SampleSources.libraryTopic])
    func everyPointNamesARealSource(topic: String) throws {
        let summary = try Self.summary(topic)
        let ids = Set(summary.sources.map(\.id))
        #expect((3...ReconSummary.maxPoints).contains(summary.points.count))
        for point in summary.points {
            #expect(!point.sourceIDs.isEmpty, "no source for: \(point.text)")
            #expect(Set(point.sourceIDs).isSubset(of: ids))
            // The words are the source's own: the first source really says it.
            let first = try #require(summary.source(point.sourceIDs[0]))
            #expect(first.text.contains(point.text), "\(first.publisher) doesn't say: \(point.text)")
        }
        #expect(summary.overviewSourceIDs.isEmpty)
        #expect(summary.madeOnDevice)
    }

    /// A second source is listed beside a point only when it repeats the
    /// point's dates, prices and numbers too.
    @Test func aSourceIsListedOnlyBesideWhatItSays() throws {
        let summary = try Self.summary(SampleSources.poolTopic)
        let swim = try #require(summary.points.first { $0.text.contains("Family swim") })
        #expect(swim.sourceIDs == ["sample:parks-pool"])
        let library = try Self.summary(SampleSources.libraryTopic)
        let sundays = try #require(library.points.first { $0.text.contains("noon to 5") })
        #expect(Set(sundays.sourceIDs) == ["sample:library-hours", "sample:gazette-library"])
    }

    @Test func aPointWithoutARealSourceIsDropped() {
        let source = Self.sources.documents[0]
        let summary = ReconSummary(
            id: "t", topic: "the pool", overview: "Some words.",
            points: [
                ReconPoint(id: "a", text: "Backed by a real source.", sourceIDs: [source.id]),
                ReconPoint(id: "b", text: "Backed by nothing.", sourceIDs: []),
                ReconPoint(id: "c", text: "Backed by a made up source.", sourceIDs: ["nowhere"]),
                ReconPoint(id: "d", text: "  ", sourceIDs: [source.id]),
                ReconPoint(id: "e", text: "Half backed.", sourceIDs: ["nowhere", source.id],
                           disagreement: ReconDisagreement(text: "One side only.", sourceIDs: [source.id, "nowhere"])),
            ],
            sources: [source], gatheredAt: Self.readOn, madeOnDevice: true)
        #expect(summary.points.map(\.id) == ["a", "e"])
        #expect(summary.points[1].sourceIDs == [source.id])
        // A disagreement needs two real sides.
        #expect(summary.points[1].disagreement == nil)
    }

    @Test func anOverviewNamingNoRealSourceIsReplaced() {
        let source = Self.sources.documents[0]
        let summary = ReconSummary(id: "t", topic: "the pool", overview: "The pool is shut forever.",
                                   overviewSourceIDs: ["nowhere"],
                                   points: [ReconPoint(id: "a", text: "Real.", sourceIDs: [source.id])],
                                   sources: [source], gatheredAt: Self.readOn, madeOnDevice: true)
        #expect(summary.overview.hasPrefix("I read 1 source on the pool."))
        #expect(summary.overviewSourceIDs.isEmpty)
    }

    /// The card shows no source numbers beside an overview, so one worded
    /// in the cloud is never used, even when it names real sources. The
    /// plain one, which only says what was read, stands in.
    @Test func anOverviewWordedInTheCloudIsAlwaysThePlainOne() {
        let source = Self.sources.documents[0]
        let summary = ReconSummary(id: "t", topic: "the pool", overview: "The pool reopens on November 3.",
                                   overviewSourceIDs: [source.id],
                                   points: [ReconPoint(id: "a", text: "Retold.", sourceIDs: [source.id])],
                                   sources: [source], gatheredAt: Self.readOn, madeOnDevice: false)
        #expect(summary.overview == ReconWords.overview(topic: "the pool", sources: 1, backedTwice: 0,
                                                        disagreements: 0, old: 0))
        #expect(summary.overviewSourceIDs.isEmpty)
        #expect(!summary.plainText.contains("November 3"))
    }

    @Test func noPointsAtAllWhenNothingWasFound() throws {
        let task = try #require(ReconTask(topic: "volcanoes on Mars"))
        let sources = try Self.sources.sources(for: task)
        #expect(sources.isEmpty)
        let summary = LocalReconSummarizer().summary(task, id: "t", sources: sources, gatheredAt: Self.readOn)
        #expect(summary.points.isEmpty)
        #expect(summary.overview == ReconWords.nothingFound("volcanoes on Mars"))
    }

    // MARK: Disagreement and dates

    @Test func disagreementIsSaidPlainly() throws {
        let summary = try Self.summary(SampleSources.poolTopic)
        #expect(summary.disagreements.count == 1)
        let point = try #require(summary.points.first { $0.disagreement != nil })
        let disagreement = try #require(point.disagreement)
        #expect(Set(disagreement.sourceIDs) == ["sample:parks-pool", "sample:gazette-pool"])
        #expect(disagreement.text.hasPrefix("Sources don't agree on this."))
        #expect(disagreement.text.contains("City of Riverside Parks says November 10, and theirs is the newer page."))
        #expect(disagreement.text.contains("Riverside Gazette says November 3."))
        // The point leads with the newer page, and cites only the page that
        // says it. The other side lives in the disagreement, never as backing.
        #expect(point.text.contains("November 10"))
        #expect(point.sourceIDs == ["sample:parks-pool"])
        #expect(Set(point.sourceIDs) != Set(disagreement.sourceIDs))
        #expect(!point.sourceIDs.contains("sample:gazette-pool"))
        for id in point.sourceIDs {
            #expect(try #require(summary.source(id)).text.contains(point.text))
        }
        #expect(summary.overview.contains("They don't agree on one thing, so I marked it."))
    }

    /// A disputed point cites only sources that say its very words. Points
    /// with no dispute are held to their own rule, a second source repeating
    /// the dates, prices and numbers, in `aSourceIsListedOnlyBesideWhatItSays`.
    @Test(arguments: [SampleSources.poolTopic, SampleSources.libraryTopic])
    func everySourceBesideAPointSaysIt(topic: String) throws {
        let summary = try Self.summary(topic)
        for point in summary.points where point.disagreement != nil {
            for id in point.sourceIDs {
                #expect(try #require(summary.source(id)).text.contains(point.text), "\(id) doesn't say: \(point.text)")
            }
        }
    }

    @Test func aRememberedDisputedPointCarriesTheDisagreement() throws {
        let summary = try Self.summary(SampleSources.poolTopic)
        let point = try #require(summary.points.first { $0.disagreement != nil })
        let note = summary.note(for: point)
        let disagreement = try #require(point.disagreement)
        #expect(note.hasPrefix(point.text))
        #expect(note.contains(disagreement.text))
        // Who says the point's words, in brackets, names only the page that does.
        let cited = try #require(note.split(separator: "(").dropFirst().first?.split(separator: ")").first)
        #expect(cited.contains("City of Riverside Parks"))
        #expect(!cited.contains("Riverside Gazette"))
        #expect(note.count <= MemoryStore.maxLength)
        // An undisputed point is kept as it was.
        let plain = try #require(summary.points.first { $0.disagreement == nil })
        #expect(!summary.note(for: plain).contains("don't agree"))
    }

    @Test func sourcesThatAgreeShowNoDisagreement() throws {
        let summary = try Self.summary(SampleSources.libraryTopic)
        #expect(summary.disagreements.isEmpty)
        #expect(!summary.overview.contains("agree"))
    }

    @Test func oldSourcesAreNamed() throws {
        let summary = try Self.summary(SampleSources.poolTopic)
        #expect(summary.oldSources.map(\.id) == ["sample:council-pool"])
        #expect(summary.overview.contains("One of them is more than a year old."))
        #expect(summary.gatheredAt == Self.readOn)
    }

    @Test func theGatheredLineSaysWhen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = Self.readOn
        #expect(ReconWords.gathered(now - 60, now: now, calendar: calendar).hasPrefix("Gathered today at "))
        #expect(ReconWords.gathered(now - 86_400, now: now, calendar: calendar).hasPrefix("Gathered yesterday at "))
        #expect(ReconWords.gathered(now - 5 * 86_400, now: now, calendar: calendar).hasPrefix("Gathered on "))
    }

    @Test func dateAndPriceValuesAreRead() {
        let values = ReconText.values(in: "Opens November 3, 2026 for 6 dollars, or $4.50 at 9.")
        #expect(values.map(\.text) == ["November 3, 2026", "6 dollars", "$4.50", "9"])
        #expect(ReconText.differ(ReconText.values(in: "on November 3"), ReconText.values(in: "on November 10")))
        #expect(!ReconText.differ(ReconText.values(in: "on November 3"), ReconText.values(in: "November 3 and 10 dollars")))
        #expect(!ReconText.differ(ReconText.values(in: "at 9"), ReconText.values(in: "at 10")))
    }

    // MARK: On the task engine

    @Test func aReconPlaysItsStepsOnTheEngine() throws {
        let start = Self.readOn
        let engine = LocalFakeEngine(rule: .isolated(), origin: start)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(runner.isRecon(id))
        func shown() throws -> AgentTask { try #require(runner.tasks.first { $0.id == id }) }
        #expect(try shown().title == "Look into the Riverside pool reopening")
        #expect(try shown().step == "Planning a few questions")
        #expect(try shown().state == .running)
        engine.advance(by: 3)
        #expect(try shown().step == "Reading 4 sources")
        engine.advance(by: 6)
        #expect(try shown().step == "Checking the dates")
        engine.advance(by: 3)
        #expect(try shown().step == "Putting it together")
        #expect(runner.summary(for: id) == nil)
        engine.advance(by: 3)
        #expect(try shown().state == .done)
        #expect(try shown().step == ReconWords.doneLine)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.id == id)
        // Read when the person asked, by the engine's own clock.
        #expect(summary.gatheredAt == start)
        #expect(try shown().result == summary.plainText)
        // Sample sources make the card an example.
        #expect(runner.isSample(id))
    }

    @Test func theCardStaysLiveUntilTheSummaryIsIn() async throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        engine.advance(by: 60)
        #expect(engine.tasks.first?.state == .done)
        let waiting = try #require(runner.tasks.first { $0.id == id })
        #expect(waiting.state == .running)
        #expect(waiting.step == ReconWords.puttingTogether)
        #expect(waiting.progress == .indeterminate)
        #expect(runner.summary(for: id) == nil)
        await gate.open()
        await runner.settle(id)
        #expect(runner.tasks.first { $0.id == id }?.state == .done)
        #expect(runner.summary(for: id) != nil)
    }

    @Test func stoppingAReconKeepsNoSummary() async throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        engine.advance(by: 4)
        #expect(runner.stop(id))
        await gate.open()
        await runner.settle(id)
        engine.advance(by: 60)
        #expect(runner.tasks.first { $0.id == id }?.state == .stopped)
        #expect(runner.summary(for: id) == nil)
    }

    @Test func aReconCantChangeCourseButOtherTasksCan() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let recon = try #require(runner.lookInto(SampleSources.libraryTopic))
        let plan = runner.start(TaskRequest(title: SampleTasks.planTitle))
        #expect(!runner.redirect(recon, with: "Look at the museum instead"))
        #expect(runner.redirect(plan, with: "Leave Friday free"))
        #expect(!runner.isRecon(plan))
    }

    @Test func nothingFoundStillEndsWithASourcedCard() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto("volcanoes on Mars"))
        #expect(runner.tasks.first?.step == ReconWords.planning)
        engine.advance(by: 3)
        #expect(runner.tasks.first?.step == ReconWords.looking)
        engine.advance(by: 10)
        let summary = try #require(runner.summary(for: id))
        #expect(summary.points.isEmpty)
        #expect(runner.tasks.first?.step == ReconWords.nothingFoundLine)
    }

    // MARK: The engine contract, through the runner

    @Test func stoppingWhileTheSummaryWaitsSaysStoppedNeverDone() async throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let id = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        engine.advance(by: 60)
        #expect(engine.tasks.first?.state == .done)
        // Still going as far as the person can see, so it can't be dismissed yet.
        #expect(!runner.dismiss(id))
        #expect(runner.stop(id))
        await gate.open()
        await runner.settle(id)
        let task = try #require(runner.tasks.first { $0.id == id })
        #expect(task.state == .stopped)
        #expect(task.step == TaskWords.stopped)
        #expect(task.result == nil)
        #expect(runner.summary(for: id) == nil)
        // Ended now, so it can go.
        #expect(runner.dismiss(id))
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(id))
    }

    @Test func dismissingAReconTakesItsSummaryToo() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        #expect(!runner.dismiss(id))
        engine.advance(by: 60)
        #expect(runner.summary(for: id) != nil)
        #expect(runner.dismiss(id))
        #expect(runner.summary(for: id) == nil)
        #expect(!runner.isRecon(id))
        #expect(runner.tasks.isEmpty)
    }

    @Test func forgettingEverythingForgetsEveryReconAndCountsWhatWasUnderway() async throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let gate = Gate()
        let done = try #require(runner.lookInto(SampleSources.libraryTopic))
        let waiting = try #require(runner.lookInto(SampleSources.poolTopic, with: GatedSummarizer(gate: gate)))
        let dentist = runner.start(TaskRequest(title: SampleTasks.dentistTitle))
        engine.advance(by: 45)
        // The dentist task waits on a yes. Saying yes makes its step one that
        // may be under way.
        let question = try #require(runner.tasks.first { $0.id == dentist }?.question)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(runner.resume(dentist, with: yes) == .proceeding)
        #expect(runner.summary(for: done) != nil)

        let cleared = runner.clear()
        #expect(cleared == ClearedTasks(forgotten: 3, underway: 1))
        #expect(runner.tasks.isEmpty)
        #expect(!runner.isRecon(done))
        #expect(!runner.isRecon(waiting))
        #expect(runner.summary(for: done) == nil)
        // A summary that comes after forgetting is dropped, not brought back.
        await gate.open()
        await runner.settle(waiting)
        #expect(runner.tasks.isEmpty)
        #expect(runner.summary(for: waiting) == nil)
        // Every question went to `AskFirst` with no lock held, the runner's included.
        #expect(engine.ruleCallsHoldingLock == 0)
        #expect(engine.ruleCalls > 0)
    }

    @Test func aStopThroughTheRunnerNeverCallsAYesUndone() throws {
        let rule = AskFirst.isolated()
        let engine = LocalFakeEngine(rule: rule, origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let id = runner.start(TaskRequest(title: SampleTasks.dentistTitle))
        engine.advance(by: 45)
        let question = try #require(runner.tasks.first?.question)
        guard case .approved(let yes) = rule.sayYes(to: question) else { Issue.record("yes refused"); return }
        #expect(runner.resume(id, with: yes) == .proceeding)
        #expect(runner.stop(id))
        let wrapUp = try #require(runner.tasks.first?.wrapUp)
        #expect(wrapUp.underway == "hold a Saturday visit")
        #expect(!wrapUp.notDone.contains("hold a Saturday visit"))
    }

    @Test func snapshotsAreNumberedInOrder() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let numbers = SnapshotNumbers()
        let watch = runner.observe { numbers.add($0.sequence, count: $0.tasks.count) }
        let id = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.advance(by: 60)
        #expect(runner.dismiss(id))
        let seen = numbers.list
        #expect(seen.count > 2)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(numbers.lastCount == 0)
        watch.cancel()
    }

    @Test func endedReconsAreLetGoWithTheEnginesCap() throws {
        let engine = LocalFakeEngine(rule: .isolated(), origin: Self.readOn)
        let runner = ReconRunner(engine: engine, provider: Self.sources)
        let first = try #require(runner.lookInto(SampleSources.poolTopic))
        engine.advance(by: 60)
        for _ in 0..<LocalFakeEngine.endedLimit {
            runner.lookInto(SampleSources.libraryTopic)
            engine.advance(by: 60)
        }
        #expect(!runner.tasks.contains { $0.id == first })
        #expect(!runner.isRecon(first))
    }

    // MARK: Nothing leaves the device

    @Test func aProviderOffTheDeviceIsNeverAsked() {
        let provider = RecordingProvider()
        let runner = ReconRunner(engine: LocalFakeEngine(rule: .isolated()), provider: provider)
        #expect(runner.lookInto(SampleSources.poolTopic) == nil)
        #expect(provider.asked == 0)
        #expect(runner.tasks.isEmpty)
    }

    @Test func theSampleSourcesStayOnTheDevice() {
        #expect(Self.sources.runsOnDevice)
        for source in Self.sources.documents {
            // Domains kept for examples, so nothing real is ever named.
            #expect(source.url.host?.hasSuffix("example.org") == true)
        }
    }

    // MARK: Memory

    @Test func aPointBecomesANoteWithWhereItCameFrom() throws {
        let summary = try Self.summary(SampleSources.libraryTopic)
        let point = try #require(summary.points.first)
        let note = summary.note(for: point)
        #expect(note.hasPrefix(point.text))
        #expect(note.contains("Riverside Public Library"))
        #expect(note.count <= MemoryStore.maxLength)
    }

    @Test func aLookedUpNoteKeepsItsSourceOnDisk() throws {
        let data = try JSONEncoder().encode(MemorySource.lookedUp("Riverside Gazette"))
        #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"lookedUp\""))
        #expect(try JSONDecoder().decode(MemorySource.self, from: data) == .lookedUp("Riverside Gazette"))
        #expect(MemorySource.lookedUp("Riverside Gazette").label == "From Riverside Gazette")
        #expect(MemorySource.lookedUp(" ").label == "From something I looked into")
    }

    /// Dashes are checked over `ReconWords.all` by `CopyDashTests`.
    @Test func reconWordsAreCalm() {
        for line in ReconWords.all {
            #expect(!line.contains("!"), "exclamation in: \(line)")
        }
    }

    /// The newest line is in the list the dash and tone checks read.
    @Test func everyCloudNoteIsInTheCheckedList() {
        for line in [ReconWords.cloudWithdrawn, ReconWords.declinedCloud, ReconWords.cloudUnreadable,
                     ReconWords.cloudUnavailable, ReconWords.wordedInCloud, ReconWords.forgotWhileInCloud,
                     ReconWords.alreadyOn] {
            #expect(ReconWords.all.contains(line), "not checked: \(line)")
        }
    }

    // MARK: A disputed point too long to keep whole

    /// The person can't shorten a note they didn't write, so when the whole
    /// disagreement would make it too long, it names only the sides. It is
    /// still never kept as if it were settled.
    @Test func aLongDisputeIsCutToItsSidesSoThePointCanBeKept() throws {
        let pages = Self.sources.documents.filter { ["sample:gazette-pool", "sample:parks-pool"].contains($0.id) }
        let long = "Sources don't agree on this. " + String(repeating: "Each page tells it a little differently. ", count: 14)
        let point = ReconPoint(id: "a", text: "Riverside Pool reopens on November 10.", sourceIDs: ["sample:parks-pool"],
                               disagreement: ReconDisagreement(text: long, sourceIDs: pages.map(\.id)))
        let summary = ReconSummary(id: "t", topic: SampleSources.poolTopic, overview: "", points: [point],
                                   sources: pages, gatheredAt: Self.readOn, madeOnDevice: true)
        let kept = try #require(summary.points.first)
        let note = summary.note(for: kept)
        #expect(note.count <= MemoryStore.maxLength)
        #expect(!note.contains("a little differently"))
        #expect(note.hasPrefix(kept.text))
        #expect(note.hasSuffix(ReconWords.disputedBy(["Riverside Gazette", "City of Riverside Parks"])))
        #expect(note.contains("Riverside Gazette and City of Riverside Parks don't agree on this."))
        // It saves.
        let memory = MemoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("recon-memory-\(UUID().uuidString).json"))
        defer { try? memory.forgetEverything() }
        guard case .saved = try memory.remember(note, source: summary.memorySource(for: kept)) else {
            Issue.record("not saved: \(note)")
            return
        }
        // A short dispute is kept whole.
        let pool = try Self.summary(SampleSources.poolTopic)
        let disputed = try #require(pool.points.first { $0.disagreement != nil })
        #expect(pool.note(for: disputed).hasSuffix(try #require(disputed.disagreement?.text)))
    }
}

struct GatedSummarizer: ReconSummarizer {
    let gate: Gate
    /// Raised when the work is cancelled while it waits.
    var onCancel: Flag?

    func summarize(_ task: ReconTask, id: String, sources: [ReconSource], gatheredAt: Date) async -> ReconSummary {
        let flag = onCancel
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            if let flag { Task { await flag.raise() } }
        }
        return LocalReconSummarizer().summary(task, id: id, sources: sources, gatheredAt: gatheredAt)
    }
}

/// Each snapshot's number, in the order they came, and how many tasks the last one held.
final class SnapshotNumbers: @unchecked Sendable {
    private let lock = NSLock()
    private var numbers: [Int] = []
    private var count = 0
    func add(_ number: Int, count: Int) { lock.lock(); numbers.append(number); self.count = count; lock.unlock() }
    var list: [Int] { lock.lock(); defer { lock.unlock() }; return numbers }
    var lastCount: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A provider that would leave the device. Counts every time it is asked.
final class RecordingProvider: SourceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var asked: Int { lock.lock(); defer { lock.unlock() }; return count }

    func sources(for task: ReconTask) throws -> [ReconSource] {
        lock.lock(); count += 1; lock.unlock()
        return ReconTests.sources.documents
    }
}
