#if canImport(SwiftUI)
import Combine
import Foundation
import PebbleBackground
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import TestScratch
import Testing
@testable import PebbleUI

/// Background work as Today and the memory screen show it: the cards it
/// leaves, the catch up when the app opens, the switch, and Forget everything.
@MainActor
@Suite(.scratchFiles)
struct BackgroundFeedTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }

    static let note = ProposedAction(kind: .send,
                                     recipient: Recipient(id: "c:1", displayName: "Sam", handle: "sam@example.com"),
                                     details: "See you at 4")

    /// Needs you with one question open, so a summary has something to
    /// say: a quiet morning leaves no card.
    static func oneWaiting() -> NeedsYou {
        let asks = NeedsYou(rule: .isolated())
        asks.ask(note, at: at(6, 50))
        return asks
    }

    private func scratchStore(faults: BackgroundStoreFaults? = nil) -> BackgroundStore {
        BackgroundStore(fileURL: Scratch.url("background-ui"), faults: faults)
    }

    private func runner(on: Bool, needsYou: NeedsYou? = BackgroundFeedTests.oneWaiting(),
                        store: BackgroundStore? = nil) -> BackgroundRunner {
        let runner = BackgroundRunner(store: store ?? scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                      needsYou: needsYou, watchingSince: .distantPast, calendar: Self.calendar)
        if on { runner.turnOn(now: Self.at(6)) }
        return runner
    }

    /// Today's model, in front unless a test says otherwise, as the scene
    /// tells it once it is active.
    private func model(_ runner: BackgroundRunner, needsYou: NeedsYou = NeedsYou(rule: .isolated()),
                       inFront: Bool = true, now: @escaping () -> Date) -> FeedModel {
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: needsYou, place: .onDevice, background: runner,
                              calendar: Self.calendar, now: now)
        model.inFront = inFront
        return model
    }

    private func scratchMemory() -> MemoryStore {
        MemoryStore(fileURL: Scratch.url("memory-ui"))
    }

    /// The system may never wake the app. Opening it makes the summary
    /// that was due, and it shows in Today at once.
    @Test func openingTheAppCatchesUpOnASummaryThatWasDue() throws {
        let runner = runner(on: true)
        var now = Self.at(6, 30)
        let model = model(runner) { now }
        model.refresh()
        #expect(model.feed.isEmpty, "not due yet")

        now = Self.at(8, 15)
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        #expect(card.title == BackgroundWords.summaryTitle)
        #expect(card.kind == .ready)
        #expect(!model.isSample(card))
    }

    /// Away from the screen, Today's refresh leaves background work to the
    /// platform's own run, which knows if the device is locked. A fresh
    /// model counts as away until the scene says it is active, since a
    /// scene may be built during a launch in the background.
    @Test func todayRunsNothingUntilTheSceneIsActive() async {
        let runner = runner(on: true)
        let fresh = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: .isolated()), place: .onDevice,
                              background: runner, calendar: Self.calendar, now: { Self.at(8) })
        #expect(!fresh.inFront)
        fresh.refresh()
        // The loop that keeps Today fresh refreshes at once, and runs nothing either.
        let loop = Task { await fresh.keepFresh(sleep: { _ in throw CancellationError() }) }
        await loop.value
        #expect(runner.results.isEmpty)
        #expect(runner.queue.first?.held == nil, "nothing claimed as held for a run it never tried")

        fresh.inFront = true
        fresh.refresh()
        #expect(runner.results.count == 1)
    }

    /// While nothing has been made, Today's empty words are still the
    /// ones it always says, and they stay true: nothing here claims work
    /// done in the background until a card shows it.
    @Test func theEmptyWordsStayTrueUntilACardIsMade() {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(6) }
        #expect(model.feed.isEmpty)
        #expect(FeedWords.empty == "It's just us for now. Write to me below, and I'll answer in the chat.")
        runner.runDue(now: Self.at(7), conditions: .foreground)
        model.refresh()
        #expect(!model.feed.isEmpty, "a real card, so the empty words are no longer shown")
    }

    /// A summary with something in it opens to read, in the usual reader.
    @Test func aSummaryWithSomethingInItOpensToRead() throws {
        let asks = Self.oneWaiting()
        let runner = runner(on: true, needsYou: asks)
        let model = model(runner, needsYou: asks) { Self.at(7, 5) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        #expect(card.kind == .ready)
        model.perform(card) { _ in }
        #expect(model.reading?.id == card.id)
        #expect(model.feed.needsYou.count == 1, "the question still waits for its answer")
    }

    /// A save cut short leaves a staged copy beside the file. Forget
    /// everything has to erase it too.
    private func leaveAStagedCopy(_ store: BackgroundStore) throws {
        try Data(contentsOf: store.fileURL).write(to: store.stagingURL)
        #expect(FileManager.default.fileExists(atPath: store.stagingURL.path))
    }

    private func expectNoSummaryFiles(_ store: BackgroundStore, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!store.hasStoredFile, sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: store.stagingURL.path), sourceLocation: sourceLocation)
    }

    /// Forget everything turns background work off and its cards go.
    @Test func forgetEverythingClearsTheCardsAndTurnsItOff() throws {
        let runner = runner(on: true)
        let model = model(runner) { Self.at(9) }
        model.refresh()
        let card = try #require(model.feed.groups.first?.items.first)
        model.perform(card) { _ in }
        try leaveAStagedCopy(runner.store)

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner,
                                 now: { Self.at(9) }, onForgetEverything: { model.forgetEverything() })
        #expect(memory.backgroundOn)
        memory.forgetEverything()
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(model.feed.isEmpty)
        #expect(model.reading == nil)
        #expect(!memory.backgroundOn)
        #expect(memory.backgroundNext == nil)
        // Today refreshing later never makes another.
        model.refresh()
        #expect(model.feed.isEmpty)
    }

    /// With no notes at all, morning summaries can still be removed: Forget
    /// everything shows while background work has a file or cards, and
    /// goes once they are gone.
    @Test func forgetEverythingShowsForSummariesWithoutNotes() throws {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.hasStoredFile)
        #expect(!memory.hasSomethingToForget, "nothing here yet")

        memory.setBackground(true)
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        memory.setBackground(false)
        memory.refresh()
        #expect(!runner.results.isEmpty, "turning off keeps the cards")
        #expect(!memory.hasStoredFile)
        #expect(memory.hasSomethingToForget)
        try leaveAStagedCopy(runner.store)

        memory.forgetEverything()
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(!memory.hasSomethingToForget)
        #expect(memory.status == MemoryWords.forgotten)
    }

    /// Forget everything goes in one order, each step whatever the one
    /// before did: background work first, so its questions are withdrawn
    /// and nothing runs while the rest goes, then the tasks, the notes and
    /// the private words.
    @Test func forgetEverythingGoesInOrder() throws {
        let notes = scratchMemory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let log = StepLog(notes: notes)
        let asks = Self.oneWaiting()
        let runner = runner(on: true, needsYou: asks)
        let proposed = runner.propose(Self.note, conditions: .foreground, at: Self.at(9), act: {})
        let asked = try #require(proposed)
        let watch = runner.observe {
            log.step(asks.rule.wasWithdrawn(asked) ? "background" : "background, question still open")
        }
        defer { runner.stopObserving(watch) }
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { log.step("private words"); return .privateWords },
                                 background: runner, now: { Self.at(9) },
                                 onForgetEverything: { log.step("tasks"); return .none })
        memory.forgetEverything()
        log.step("done")
        #expect(log.steps == ["background", "tasks", "notes", "private words", "done"])
    }

    /// With nothing of background work to forget, its summaries are not
    /// said to go, and nothing erased means no "forgotten" tap: the line
    /// and the tap agree.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func theForgottenTapNeedsSomethingErased() throws {
        let folder = Scratch.url("memory-ro").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let runner = runner(on: false)
        let memory = MemoryModel(store: notes, place: .onDevice, alsoForget: { throw CocoaError(.fileWriteNoPermission) },
                                 background: runner, now: { Self.at(9) })
        #expect(!memory.hasBackgroundToForget)
        memory.forgetEverything()
        #expect(memory.status == MemoryWords.couldNotForget)
        #expect(memory.forgottenCount == 0)

        // With cards to forget, they go, the line says so, and it taps.
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        memory.refresh()
        memory.forgetEverything()
        #expect(memory.status == MemoryModel.forgotLine(notesGone: false, rest: .some(nil), tasksGone: false,
                                                        summaries: .erased))
        #expect(memory.status?.contains(MemoryWords.summariesGone) == true)
        #expect(memory.forgottenCount == 1)
    }

    /// If the summaries' file can't be erased, the line says so rather
    /// than read as done, and Forget everything stays to try again.
    @Test func aSummaryFileThatCantBeErasedIsSaid() throws {
        let faults = BackgroundStoreFaults()
        let toggle = InMemoryBackgroundSwitch()
        let asks = Self.oneWaiting()
        let runner = BackgroundRunner(store: scratchStore(faults: faults), toggle: toggle, needsYou: asks,
                                      watchingSince: .distantPast, calendar: Self.calendar)
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        #expect(toggle.nextDue != nil)
        let proposed = runner.propose(Self.note, conditions: .foreground, at: Self.at(9), act: {})
        let asked = try #require(proposed)
        #expect(runner.store.hasStoredFile)
        faults.eraseFails = true

        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(memory.hasSomethingToForget)
        memory.forgetEverything()
        // Work while you're away is off and its cards are gone either way.
        #expect(!runner.isOn, "off even so")
        #expect(runner.results.isEmpty)
        #expect(runner.queue.isEmpty)
        #expect(toggle.nextDue == nil)
        #expect(asks.rule.wasWithdrawn(asked), "a yes on a sheet still open does nothing")
        #expect(!asks.items(now: Self.at(9)).contains { $0.request == asked })
        #expect(memory.status == MemoryWords.couldNotForgetSummaries(tasks: false, words: false))
        #expect(memory.status == "I forgot your notes and turned off work while you're away, but I couldn't erase "
                + "your morning summaries just now. Please try Forget everything again in a moment.",
                "no tasks and no hidden words went, so it names neither")
        #expect(memory.hasSomethingToForget, "still there, so it can be tried again")

        faults.eraseFails = false
        memory.forgetEverything()
        #expect(memory.status == MemoryWords.forgotten)
        #expect(!memory.hasSomethingToForget)
        expectNoSummaryFiles(runner.store)
    }

    /// The summaries go first, and when their file can't be erased every
    /// later step still runs: the note, the tasks and the private words all
    /// go, and the line says only the summaries stayed.
    @Test func aSummaryFileThatCantBeErasedStopsNothingElse() throws {
        let faults = BackgroundStoreFaults()
        let runner = runner(on: true, store: scratchStore(faults: faults))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        #expect(runner.store.hasStoredFile)
        faults.eraseFails = true

        let notes = scratchMemory()
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        let engine = LocalFakeEngine(rule: .isolated())
        engine.start(SampleTasks.plan)
        #expect(!engine.tasks.isEmpty)
        let feed = FeedModel(sources: [EmptyFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine,
                             place: .onDevice, background: runner, calendar: Self.calendar, now: { Self.at(9) })
        var wordsForgotten = 0
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { wordsForgotten += 1; return .privateWords },
                                 background: runner, now: { Self.at(9) },
                                 onForgetEverything: { feed.forgetEverything() })
        memory.forgetEverything()

        #expect(runner.store.hasStoredFile, "the summaries' file stayed")
        #expect(notes.notes().isEmpty, "the note went")
        #expect(!notes.hasStoredFile)
        #expect(engine.tasks.isEmpty, "the tasks went")
        #expect(wordsForgotten == 1, "the private words step ran")
        #expect(memory.status == "I forgot your notes, tasks and any words you asked me to hide, and turned off work "
                + "while you're away, but I couldn't erase your morning summaries just now. Please try Forget "
                + "everything again in a moment.", "names everything that went")
        #expect(!runner.isOn)
    }

    /// With the private words too, each step runs whatever the others did:
    /// the notes can't be erased here, but the summaries and the words go,
    /// and the line says exactly that.
    @Test(.fileModesHoldOrCI, .failsAsRoot)
    func forgetEverythingSaysWhatWentWithTheWordsAndSummaries() throws {
        let folder = Scratch.url("memory-ro").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try notes.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let runner = runner(on: true)
        runner.runDue(now: Self.at(7, days: 1), conditions: .foreground)
        #expect(!runner.results.isEmpty)
        try leaveAStagedCopy(runner.store)
        var wordsForgotten = false
        let memory = MemoryModel(store: notes, place: .onDevice,
                                 alsoForget: { wordsForgotten = true; return .privateWords },
                                 background: runner, now: { Self.at(9) })
        memory.forgetEverything()
        #expect(memory.status == "Your private words are gone, but I couldn't erase your notes just now. "
                + MemoryWords.summariesGone + " Please try Forget everything again in a moment.")
        #expect(wordsForgotten)
        #expect(!runner.isOn)
        #expect(runner.results.isEmpty)
        expectNoSummaryFiles(runner.store)
        #expect(notes.notes().count == 1)
    }

    /// Off until the person turns it on. On, it says when the next is due,
    /// and VoiceOver hears it, since that line appears away from the switch.
    @Test func theSwitchIsOffUntilTurnedOnAndSaysWhenTheNextIsDue() {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        var heard: [String] = []
        memory.announce = { heard.append($0) }
        #expect(!memory.backgroundOn)
        #expect(memory.backgroundNext == nil)

        memory.setBackground(true)
        #expect(runner.isOn)
        #expect(memory.backgroundOn)
        #expect(runner.queue.first?.due == Self.at(7, days: 1))
        let next = BackgroundWords.nextDue(Self.at(7, days: 1), now: Self.at(9))
        #expect(memory.backgroundNext == next)
        #expect(heard == [next])

        memory.setBackground(false)
        #expect(!runner.isOn)
        #expect(runner.queue.isEmpty)
        #expect(memory.backgroundNext == nil)
        #expect(heard == [next], "nothing more to say when it turns off")
    }

    /// The app wires no task engine yet, so the line under the switch, read
    /// as the person turns it on, doesn't promise what finished. With an
    /// engine, it does. The app's wiring comes from `BackgroundWiring.app`,
    /// the same factory this reads.
    @Test func theSwitchPromisesWhatFinishedOnlyWithTasksToCount() throws {
        let store = scratchStore()
        defer { try? store.forget() }
        let asks = NeedsYou(rule: .isolated())
        let wiring = BackgroundWiring.app(needsYou: asks, store: { store }, toggle: { InMemoryBackgroundSwitch() })
        #expect(wiring.tasks == nil, "the app wires no engine yet")
        let wired = try #require(wiring.service.runner)
        #expect(wired.tasks == nil, "the runner counts the same tasks as Today")
        #expect(wired.needsYou === asks)
        let asTheAppHasIt = MemoryModel(store: scratchMemory(), place: .onDevice, background: wired)
        #expect(!asTheAppHasIt.backgroundDetail.contains("finished"))
        #expect(asTheAppHasIt.backgroundDetail
            == BackgroundWords.settingDetail(whileClosed: BackgroundRow.runsWhileClosed, countsTasks: false))

        let rule = AskFirst.isolated()
        let withTasks = BackgroundRunner(store: scratchStore(), toggle: InMemoryBackgroundSwitch(),
                                         needsYou: NeedsYou(rule: rule), tasks: LocalFakeEngine(rule: rule))
        let counting = MemoryModel(store: scratchMemory(), place: .onDevice, background: withTasks)
        #expect(counting.backgroundDetail.contains("what finished overnight"))
    }

    /// The memory screen follows the runner: turned on in another window,
    /// or a card made in Today, it shows here without waiting to come back.
    @Test(.timeLimit(.minutes(1))) func theMemoryScreenFollowsTheRunner() async {
        let runner = runner(on: false)
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice, background: runner, now: { Self.at(9) })
        #expect(!memory.backgroundOn)
        #expect(!memory.hasSomethingToForget)

        // Another window turns it on and Today makes a card. The screen
        // hears of it on a later turn of the main actor; this waits for
        // that, however long the machine takes.
        runner.turnOn(now: Self.at(6))
        runner.runDue(now: Self.at(7), conditions: .foreground)
        var watch: AnyCancellable?
        await withCheckedContinuation { (heard: CheckedContinuation<Void, Never>) in
            watch = memory.$hasBackgroundToForget.first { $0 }.sink { _ in heard.resume() }
        }
        watch?.cancel()
        #expect(memory.backgroundOn)
        #expect(memory.backgroundNext != nil)
        #expect(memory.hasSomethingToForget)
    }

    /// VoiceOver reads a summary or missed card as one thought, and the
    /// body is in it, not only the title: the detail behind the card is
    /// for reading, the body is what the card says.
    @Test func theCardsSpokenTextIncludesItsBody() {
        let summary = BackgroundResult(madeAt: Self.at(7), content: .morningSummary(MorningSummary(
            waiting: 1, finished: nil, couldNotFinish: nil, since: Self.at(19, days: -1), late: .locked)))
        let missed = BackgroundResult(madeAt: Self.at(7), content: .missed(kind: .morningSummary,
                                                                           due: Self.at(7, days: -1), held: .lowPower))
        let several = BackgroundResult(madeAt: Self.at(7), content: .missed(
            kind: .morningSummary, due: Self.at(7, days: -3), held: nil, through: Self.at(7, days: -1)))
        for result in [summary, missed, several] {
            let item = result.item(calendar: Self.calendar)
            #expect(!item.body.isEmpty)
            for isSample in [false, true] {
                let spoken = FeedCard(item: item, time: "7:00 AM", isSample: isSample, perform: {}).spoken
                #expect(spoken.contains(item.title))
                #expect(spoken.contains(item.body), "the body is read too: \(spoken)")
            }
        }
    }

    /// The notes and the private words are the only words of the person's
    /// kept on disk, each with the strictest protection, and the summary
    /// copies neither. The chat is kept nowhere: nothing that holds it
    /// writes a file, encodes it, or puts it in `UserDefaults` or scene
    /// storage. The one `UserDefaults` it touches keeps the agent's name.
    @Test func theChatIsNeverKeptOnDisk() throws {
        let sources = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Sources")
        let chat = ["PebbleModel/Conversation.swift", "PebbleModel/ModelClient.swift", "PebbleUI/ChatView.swift",
                    "PebbleUI/Composer.swift"]
        let keeping = ["write(to", "FileManager", "createFile", "FileHandle", "AppStorage", "SceneStorage",
                       "JSONEncoder", "PropertyListEncoder", "NSKeyedArchiver", "UserDefaults.", "UserDefaults(",
                       "BackgroundStore", "MemoryStore", "CloudHelpFileStore"]
        for name in chat {
            let code = String(SwiftSource(try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8))
                .code)
            for word in keeping { #expect(!code.contains(word), "\(word) in \(name)") }
        }
        #expect(String(SwiftSource(try String(contentsOf: sources.appendingPathComponent("PebbleUI/ChatView.swift"),
                                              encoding: .utf8)).code).contains("UserDefaultsAgentNameStore()"),
                "the name, and only the name")
    }

    /// Nor does the chat reach the disk another way. Every source in the
    /// app's packages that can hold chat text, found by what it names, not
    /// from a list, writes nothing to the system log, which keeps it on
    /// disk, and the one session that sends a chat to the cloud keeps no
    /// cache. Only the competitor watch, which never sees a chat, prints.
    @Test func theChatNeverReachesTheLogOrACache() throws {
        let sources = SwiftSource.repositoryRoot(from: #filePath).appendingPathComponent("Packages/PebbleKit/Sources")
        let chatWords = ["ChatTurn", "Conversation", "ModelClient", "CloudRequest", "ChatController", "messages"]
        let logging = try NSRegularExpression(pattern: #"\b(Logger|os_log|os_signpost|NSLog|print|debugPrint|dump|OSLog)\b"#)
        var chatFiles: [String] = []
        for file in try SwiftSource.files(under: sources)
        where !file.name.hasPrefix("PebblePulse/") && !file.name.hasPrefix("pulse/") {
            let code = String(SwiftSource(file.text).code)
            let range = NSRange(code.startIndex..., in: code)
            // No logging anywhere a chat could pass through, which is every
            // file but the competitor watch's.
            #expect(logging.firstMatch(in: code, range: range) == nil, "logging in \(file.name)")
            guard chatWords.contains(where: code.contains) else { continue }
            chatFiles.append(file.name)
            #expect(!code.contains("URLSession.shared"), "a shared session, with its cache, in \(file.name)")
            #expect(!code.contains("URLCache"), "a response cache in \(file.name)")
            #expect(!code.contains("URLSessionConfiguration.default"), "a default session in \(file.name)")
        }
        for name in ["PebbleModel/ModelClient.swift", "PebbleModel/CloudModel.swift", "PebbleUI/ChatView.swift"] {
            #expect(chatFiles.contains(name), "the sweep finds \(name)")
        }
        // The cloud session: ephemeral, with no cache at all.
        let cloud = String(SwiftSource(try String(contentsOf: sources.appendingPathComponent("PebbleModel/CloudModel.swift"),
                                                  encoding: .utf8)).code)
        #expect(cloud.components(separatedBy: "URLSession(").count == 2, "one session is made, in makeSession")
        let session = URLSessionCloudTransport.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(cloud.contains("URLSessionConfiguration.ephemeral"))
    }

    /// Forget everything names work while away only where there is a switch for it.
    @Test func forgetEverythingNamesBackgroundWorkOnlyWhenThereIsSome() {
        #expect(MemoryWords.forgetEverythingDetail(background: true).contains("work while you're away"))
        #expect(!MemoryWords.forgetEverythingDetail(background: false).contains("away"))
    }

    /// No runner, no switch: the memory screen is as it was.
    @Test func withoutARunnerThereIsNoSwitch() {
        let memory = MemoryModel(store: scratchMemory(), place: .onDevice)
        #expect(memory.background == nil)
        memory.setBackground(true)
        #expect(!memory.backgroundOn)
    }

    /// The showcase's runner is an example, and says so on every card.
    @Test func theShowcaseSummaryIsAnExample() {
        let morning = ShowcaseScene.morning
        let asks = ShowcaseScene.sampleQuestion(at: morning)
        let runner = ShowcaseScene.sampleBackground(on: true, needsYou: asks, played: true, at: morning)
        #expect(runner.isSample)
        // Only the summary: with no tasks, as in the app, a missed day leaves no card.
        #expect(runner.results.count == 1)
        let model = FeedModel(sources: [EmptyFeedSource()], needsYou: asks, place: .onDevice, background: runner,
                              now: { morning })
        #expect(model.isSample)
        for group in model.feed.groups {
            for item in group.items { #expect(model.isSample(item)) }
        }
    }
}

/// The steps of Forget everything as they happen, from any thread. The
/// notes have no hook of their own, so their erase is logged when the next
/// step finds their file gone.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private let notes: MemoryStore
    private var notesThere: Bool
    private var list: [String] = []

    init(notes: MemoryStore) {
        self.notes = notes
        notesThere = notes.hasStoredFile
    }

    func step(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if notesThere, !notes.hasStoredFile {
            notesThere = false
            list.append("notes")
        }
        list.append(name)
    }

    var steps: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
#endif
