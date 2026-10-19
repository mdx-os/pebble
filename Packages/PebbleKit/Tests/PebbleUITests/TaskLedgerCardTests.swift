#if canImport(SwiftUI)
import Foundation
@testable import PebbleCore
import PebbleModel
import SwiftUI
import SourceScan
import Testing
import TestScratch
@testable import PebbleUI

/// A task card shows how its ledger says the task finished: what shows it,
/// as chips, or that it couldn't be checked. A task gone quiet says so,
/// beside its Stop. Forget everything and Clear take the ledger too.
@MainActor
struct TaskLedgerCardTests {
    private func model(_ engine: LocalFakeEngine, ledger: TaskLedgerBook?) -> FeedModel {
        FeedModel(sources: [SampleFeedSource()], needsYou: NeedsYou(rule: engine.rule), tasks: engine, ledger: ledger,
                  place: .onDevice, now: { ShowcaseScene.morning })
    }

    private func card(_ model: FeedModel, _ task: AgentTask) -> TaskCard {
        TaskCard(task: task, time: "9:40", finish: model.finish(task), quietLine: model.quietLine(task))
    }

    /// A ledger that writes the engine's time, as the app's would.
    private func ledger(_ engine: LocalFakeEngine, store: InMemoryTaskLedgerStore = InMemoryTaskLedgerStore(),
                        artifacts: any TaskArtifactResolving = NoArtifacts()) -> TaskLedgerBook {
        TaskLedgerBook(store: store, artifacts: artifacts, clock: { [engine] in engine.currentDate })
    }

    @Test func backgroundCompletionsSurviveANewerMainThreadSnapshot() async throws {
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [])
        let book = ledger(engine)
        let model = model(engine, ledger: book)
        let ids = (0..<13).map { index in
            engine.start(TaskScript(title: "Short \(index)",
                                    steps: [.init("Reading", duration: 1, todo: "read")],
                                    doneLine: "Ready.", proofs: [.check("Read the note")]))
        }
        // Hold the main actor until both background snapshots have queued
        // their UI work, then overtake them with a main-thread mutation.
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine.advance(by: 2)
            delivered.signal()
        }
        func waitForDelivery() -> DispatchTimeoutResult { delivered.wait(timeout: .now() + 10) }
        #expect(waitForDelivery() == .success)
        engine.start(TaskScript(title: "Next", steps: [.init("Reading", duration: 60, todo: "read")],
                                doneLine: "Ready."))
        await model.settled()
        for id in ids {
            #expect(try #require(book.ledger(id)).end?.kind == .done(proofs: [.check("Read the note")]))
        }
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot, arguments: [0, 1, 2])
    func restoredRunningTaskCompletesAfterStoresRecover(ledgerRecovery: Int) async throws {
        let folder = try #require(Scratch.folder)
        let taskFile = folder.appendingPathComponent("tasks.json")
        let ledgerFile = folder.appendingPathComponent("ledger.json")
        let marker = folder.appendingPathComponent("tasks-forgotten")
        let ledgerMarker = folder.appendingPathComponent("ledger-forgotten")
        let script = TaskScript(title: "Read the note", steps: [.init("Reading", duration: 10, todo: "read")],
                                doneLine: "Ready.", proofs: [.check("Read the note")])
        let before = LocalFakeEngine(rule: .isolated(), scripts: [script])
        let id = before.start(script)
        TaskStore(fileURL: taskFile, forgetMarker: marker).keep(before)
        let disk = TaskLedgerFileStore(fileURL: ledgerFile, forgetMarker: ledgerMarker)
        let earlier = TaskLedgerBook(store: disk, clock: { before.currentDate })
        earlier.record(TaskSnapshot(sequence: 1, tasks: before.tasks + [
            AgentTask(id: "orphan", title: "Old work", step: "Reading", startedAt: before.currentDate),
        ]))
        let original = try #require(earlier.ledger(id)).entries
        let manager = FileManager.default
        for file in ledgerRecovery == 2 ? [taskFile] : [taskFile, ledgerFile] {
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }
        defer {
            for file in [taskFile, ledgerFile] {
                try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
        let store = TaskStore(fileURL: taskFile, forgetMarker: marker)
        let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [script])
        let book = TaskLedgerBook(store: disk, clock: { engine.currentDate })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine, ledger: book,
                              place: .onDevice, flow: flow)
        #expect(engine.tasks.isEmpty)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledgerFile.path)
        if ledgerRecovery != 0 {
            // A ledger read or watch must not resolve an unknown task store.
            book.watch()
            #expect(book.ledger(id)?.isEnded == false)
            #expect(book.takeStoppedAtLaunch().isEmpty)
        }
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: taskFile.path)
        _ = store.tasks
        await model.settled()
        await model.settled()
        #expect(engine.task(id)?.state == .running)
        #expect(book.ledger(id)?.isEnded == false)
        engine.advance(by: 11)
        await model.settled()
        let finished = try #require(book.ledger(id))
        #expect(finished.end?.kind == .done(proofs: script.proofs))
        #expect(Array(finished.entries.prefix(original.count)) == original)
        #expect(book.takeStoppedAtLaunch().map(\.taskID) == ["orphan"])
        #expect(book.ledger("orphan")?.end?.kind == .stopped(why: LedgerWords.stoppedWhenClosed))
        #expect(book.takeStoppedAtLaunch().isEmpty)
        #expect(disk.read()?.first { $0.taskID == id } == finished)
    }

    @Test(.scratchFiles, .fileModesHoldOrCI, .failsAsRoot)
    func anEmptyRecoveredTaskStoreResolvesOrphans() async throws {
        let folder = try #require(Scratch.folder)
        let file = folder.appendingPathComponent("tasks.json")
        let marker = folder.appendingPathComponent("tasks-forgotten")
        // Keep a real, readable empty file rather than a missing path.
        try JSONEncoder().encode(TaskStore.State()).write(to: file)
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: file.path))
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let disk = InMemoryTaskLedgerStore()
        let before = LocalFakeEngine(rule: .isolated())
        let id = before.start(SampleTasks.plan)
        ledger(before, store: disk).record(TaskSnapshot(sequence: 1, tasks: before.tasks))
        let engine = LocalFakeEngine(rule: .isolated())
        let book = ledger(engine, store: disk)
        let store = TaskStore(fileURL: file, forgetMarker: marker)
        let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
        let model = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine, ledger: book,
                              place: .onDevice, flow: flow)
        #expect(book.ledger(id)?.isEnded == false)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        model.refresh()
        await model.settled()
        #expect(engine.tasks.isEmpty)
        #expect(book.takeStoppedAtLaunch().map(\.taskID) == [id])
        #expect(book.ledger(id)?.end?.kind == .stopped(why: LedgerWords.stoppedWhenClosed))
    }

    @Test func aProvenCardShowsEachProofAndSaysWhatItIs() throws {
        let (engine, ledger) = ShowcaseScene.ledgerTasks(.taskProven, rule: .isolated())
        let model = model(engine, ledger: ledger)
        let task = try #require(engine.tasks.first)
        #expect(task.state == .done)
        #expect(model.finish(task) == .proven(SampleTasks.dentist.proofs))
        let card = card(model, task)
        #expect(card.spokenProofs == ["Source: Maple Dental hours", "Source: Harbour Smiles visits",
                                      "Made: Saturday dentists"])
        #expect(card.shownFinish?.line == nil)
        #expect(card.statusLabel == "Done")
        #expect(card.spoken.hasPrefix("Done."))
    }

    @Test func anUncheckedCardSaysSoInPlainWords() throws {
        let (engine, ledger) = ShowcaseScene.ledgerTasks(.taskUnchecked, rule: .isolated())
        let model = model(engine, ledger: ledger)
        let task = try #require(engine.tasks.first)
        #expect(task.state == .done)
        let card = card(model, task)
        // Keep the visible Text wired to the same status that VoiceOver reads.
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let source = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/TaskCard.swift"),
                                encoding: .utf8)
        #expect(SwiftSource(source).calls(named: ["Text"]).contains { $0.arguments == "statusLabel" })
        #expect(card.statusLabel == "Finished")
        #expect(card.spoken.hasPrefix("Finished."))
        #expect(!card.spoken.hasPrefix("Done."))
        #expect(card.shownFinish == .unchecked)
        #expect(card.shownFinish?.line == "Finished, but I couldn't check the result.")
        #expect(card.spokenProofs.isEmpty)
    }

    /// The pages stand, but a list the ledger can't find on this device is
    /// no proof, so its chip never shows.
    @Test func aChipShowsOnlyForAProofTheLedgerFound() throws {
        let engine = LocalFakeEngine(rule: .isolated())
        let id = engine.start(SampleTasks.dentist)
        let ledger = ledger(engine)
        let model = model(engine, ledger: ledger)
        engine.advance(by: 43)
        let question = try #require(engine.task(id)?.question)
        #expect(engine.resume(id, with: question.approve()) == .proceeding)
        engine.advance(by: 10)
        let task = try #require(engine.task(id))
        #expect(card(model, task).spokenProofs == ["Source: Maple Dental hours", "Source: Harbour Smiles visits"])
    }

    @Test func withoutALedgerADoneCardIsAsItWas() throws {
        let engine = ShowcaseScene.sampleTasks(.taskDone, rule: .isolated())
        let model = model(engine, ledger: nil)
        let task = try #require(engine.tasks.first { $0.state == .done })
        #expect(model.finish(task) == nil)
        #expect(card(model, task).shownFinish == nil)
    }

    @Test func aQuietCardSaysSoAndOffersStop() throws {
        let engine = LocalFakeEngine(rule: .isolated(), scripts: [])
        let id = engine.start(TaskScript(title: "Read the PTA notes",
                                         steps: [.init("Reading the third page", duration: 45 * 60, todo: "read them")],
                                         doneLine: "Done."))
        let model = model(engine, ledger: ledger(engine))
        engine.advance(by: QuietWatch.period)
        model.refresh()
        var task = try #require(engine.task(id))
        #expect(card(model, task).shownQuietLine == "Still on it: reading the third page.")
        #expect(card(model, task).actions.contains(.stop))
        engine.advance(by: 2 * QuietWatch.period)
        model.refresh()
        task = try #require(engine.task(id))
        #expect(card(model, task).shownQuietLine
            == "I haven't moved forward on this in a while. I'll keep trying, or you can stop me here.")
        #expect(card(model, task).actions.contains(.stop))
        // Something new, and the quiet line goes.
        engine.advance(by: 20 * 60)
        model.refresh()
        task = try #require(engine.task(id))
        #expect(card(model, task).shownQuietLine == nil)
    }

    @Test func forgetEverythingEmptiesTheLedger() throws {
        let (engine, ledger) = ShowcaseScene.ledgerTasks(.taskProven, rule: .isolated())
        let model = model(engine, ledger: ledger)
        engine.start(SampleTasks.plan)
        engine.advance(by: 5)
        #expect(ledger.ledgers.count == 2)
        model.forgetTasks()
        #expect(ledger.ledgers.isEmpty)
        #expect(model.ledgerShown.isEmpty)
    }

    @Test func forgetEverythingInAnotherWindowEmptiesItToo() throws {
        let store = TaskStore.inMemory()
        let flow = NeedsYouFlow(store: store, notifier: nil, agentName: { "Pip" })
        let (engine, ledger) = ShowcaseScene.ledgerTasks(.taskProven, rule: .isolated())
        let here = FeedModel(sources: [], needsYou: NeedsYou(rule: engine.rule), tasks: engine, ledger: ledger,
                             place: .onDevice, flow: flow, now: { ShowcaseScene.morning })
        let other = LocalFakeEngine(rule: .isolated())
        let there = FeedModel(sources: [], needsYou: NeedsYou(rule: other.rule), tasks: other, place: .onDevice,
                              flow: flow, now: { ShowcaseScene.morning })
        #expect(!ledger.ledgers.isEmpty)
        there.forgetTasks()
        #expect(ledger.ledgers.isEmpty)
        _ = here
    }

    @Test func clearingACardTakesItsLedger() throws {
        let (engine, ledger) = ShowcaseScene.ledgerTasks(.taskUnchecked, rule: .isolated())
        let model = model(engine, ledger: ledger)
        let task = try #require(engine.tasks.first)
        #expect(ledger.ledger(task.id) != nil)
        model.dismiss(task)
        #expect(ledger.ledger(task.id) == nil)
    }

    @Test func atLaunchATaskNoEngineHasSaysItStopped() throws {
        let store = InMemoryTaskLedgerStore()
        let before = LocalFakeEngine(rule: .isolated())
        let earlier = ledger(before, store: store)
        let gone = before.start(SampleTasks.plan)
        earlier.record(TaskSnapshot(sequence: 1, tasks: before.tasks))
        // The app opens again with a new engine that has nothing going.
        let engine = LocalFakeEngine(rule: .isolated())
        let book = ledger(engine, store: store)
        _ = model(engine, ledger: book)
        #expect(book.ledger(gone)?.entries.last?.kind == .stopped(why: "This stopped when the app closed."))
    }

    @Test(arguments: [ShowcaseScene.taskProven, .taskUnchecked])
    func theLedgerScenesRender(scene: ShowcaseScene) throws {
        let sizes = [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376), CGSize(width: 320, height: 1032)]
        for (index, size) in sizes.enumerated() {
            let (engine, ledger) = ShowcaseScene.ledgerTasks(scene, rule: .isolated())
            let view = NavigationStack {
                FeedView(model: model(engine, ledger: ledger), look: .startingPoint, onTalk: { _ in })
            }
            for text in [DynamicTypeSize.large, .accessibility5] {
                let renderer = ImageRenderer(content: view
                    .environment(\.colorScheme, index.isMultiple(of: 2) ? .light : .dark)
                    .environment(\.dynamicTypeSize, text)
                    .frame(width: size.width, height: size.height))
                #expect(renderer.cgImage != nil)
            }
        }
    }

    /// Chips wrap onto new rows rather than run off the card.
    @Test func chipsWrapToTheWidthTheyHave() {
        let chips = ChipFlow(spacing: 6) {
            ForEach(SampleTasks.dentist.proofs, id: \.self) { ProofChip(proof: $0) }
        }
        let narrow = ImageRenderer(content: chips.frame(width: 140).fixedSize(horizontal: false, vertical: true))
        let wide = ImageRenderer(content: chips.frame(width: 900).fixedSize(horizontal: false, vertical: true))
        let narrowHeight = narrow.cgImage.map { CGFloat($0.height) / narrow.scale } ?? 0
        let wideHeight = wide.cgImage.map { CGFloat($0.height) / wide.scale } ?? 0
        #expect(wideHeight > 0)
        #expect(narrowHeight > wideHeight * 2)
    }
}
#endif
