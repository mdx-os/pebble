#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import Testing
@testable import PebbleUI

/// Today as the app makes it with the device's own engine: a recon plays
/// beside the digest on a scripted engine of its own. Each card's Stop,
/// Dismiss and Forget everything reach only what they should, and a
/// recon's topic is never written to the device engine's file.
@MainActor
struct ReconBesideDeviceTasksTests {
    let folder: URL
    let notes: MemoryStore
    let rule = AskFirst.isolated()
    let store: TaskStore
    let engine: DeviceTaskEngine
    let feed: FeedModel
    let morning = ShowcaseScene.morning

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recon-beside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notes = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        try notes.remember("Dentist on Thursday at 3", at: Date() - 3_600, source: .toldMe)
        store = DigestTodayTests.openStore(in: folder)
        engine = OnDeviceTasks.engine(model: LocalStubModel(), notes: notes, store: store, rule: rule, pace: nil)
        let flow = HomeView.flow(store: store, notifier: nil, brand: Brand(name: "Nova"),
                                 names: InMemoryAgentNameStore(stored: "Pip"))
        feed = HomeView.reconFeedModel(sources: [], needsYou: NeedsYou(rule: rule), tasks: engine, drivesTasks: false,
                                       reading: ReconTestData.sources, place: .onDevice, memory: notes,
                                       model: LocalStubModel(), cloud: nil, flow: flow,
                                       now: { [morning] in morning })
    }

    /// Starts the digest from its offer and runs it to its question.
    func startDigest() throws -> AgentTask {
        feed.start(DigestTask.request)
        for _ in 0..<3 { engine.runPending() }
        feed.refresh()
        return try #require(feed.feed.needsYou.compactMap(\.task).first)
    }

    /// Looks into the pool and plays it to its summary, a second at a time.
    func lookIntoThePool() throws -> String {
        #expect(feed.lookInto(SampleSources.poolTopic))
        let runner = try #require(feed.recon)
        let id = try #require(runner.tasks.first { runner.isRecon($0.id) }?.id)
        for _ in 0..<30 { feed.tick(1) }
        feed.refresh()
        #expect(runner.summary(for: id) != nil)
        return id
    }

    /// Every byte under the folder the notes and tasks are kept in.
    func everythingOnDisk() throws -> String {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.compactMap { try? Data(contentsOf: $0) }.map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
    }

    @Test func bothEnginesShareToday() throws {
        #expect(feed.canLookInto)
        #expect(feed.ticks == false)
        #expect(feed.offers == [DigestTask.request])
        let digest = try startDigest()
        let recon = try lookIntoThePool()
        #expect(digest.id != recon)
        let ids = Set((feed.feed.needsYou + feed.feed.working + feed.feed.groups.flatMap(\.items)).map(\.id))
        #expect(ids.contains(digest.id))
        #expect(ids.contains(recon))
        // The recon read example pages; the digest is real work.
        #expect(feed.recon?.isSample(recon) == true)
        #expect(feed.recon?.isSample(digest.id) == false)
        #expect(feed.canApprove(digest))
        #expect(feed.summary(for: try #require(feed.recon?.tasks.first { $0.id == recon })) != nil)
    }

    @Test func eachCardsStopAndDismissReachOnlyItsOwnEngine() throws {
        let digest = try startDigest()
        let recon = try lookIntoThePool()
        let runner = try #require(feed.recon)
        // Dismissing the recon leaves the digest waiting.
        feed.dismiss(try #require(runner.tasks.first { $0.id == recon }))
        #expect(!runner.tasks.contains { $0.id == recon })
        #expect(engine.tasks.first { $0.id == digest.id }?.state == .waitingOnYou)
        // A second recon, still going, outlives the digest's Stop.
        #expect(feed.lookInto(SampleSources.libraryTopic))
        let going = try #require(runner.tasks.first { runner.isRecon($0.id) }?.id)
        feed.stop(digest)
        for _ in 0..<3 { engine.runPending() }
        feed.refresh()
        #expect(engine.tasks.first { $0.id == digest.id }?.state == .stopped)
        #expect(runner.tasks.first { $0.id == going }?.isActive == true)
        // And the recon's Stop leaves the digest's card as it was.
        let stoppedDigest = engine.tasks.first { $0.id == digest.id }
        feed.stop(try #require(runner.tasks.first { $0.id == going }))
        #expect(runner.tasks.first { $0.id == going }?.state == .stopped)
        #expect(engine.tasks.first { $0.id == digest.id } == stoppedDigest)
        // Neither engine knows the other's id.
        #expect(!engine.dismiss(going))
        #expect(!engine.stop(going))
    }

    @Test func aReconsTopicIsNeverWrittenToTheDevicesFile() throws {
        _ = try startDigest()
        _ = try lookIntoThePool()
        #expect(feed.lookInto(SampleSources.libraryTopic))
        feed.tick(2)
        feed.refresh()
        // With a recon done and one going, the device's file holds its own
        // task and nothing of either recon.
        #expect(engine.hasStoredFile)
        let disk = try everythingOnDisk()
        #expect(disk.contains(DigestTask.title))
        for words in ["Riverside pool", "Sunday hours", ReconWords.title(SampleSources.poolTopic)] {
            #expect(!disk.localizedCaseInsensitiveContains(words))
        }
    }

    @Test func forgetEverythingTakesBoth() throws {
        _ = try startDigest()
        _ = try lookIntoThePool()
        #expect(feed.lookInto(SampleSources.libraryTopic))
        let cleared = feed.forgetEverything()
        #expect(cleared.forgotten == 3)
        #expect(cleared.erased)
        #expect(engine.tasks.isEmpty)
        #expect(feed.recon?.tasks.isEmpty == true)
        #expect(feed.feed.working.isEmpty)
        #expect(feed.feed.needsYou.isEmpty)
        #expect(feed.tasksForgotten)
        // Both can start again after.
        #expect(feed.offers == [DigestTask.request])
        #expect(feed.lookInto(SampleSources.poolTopic))
    }
}
#endif
