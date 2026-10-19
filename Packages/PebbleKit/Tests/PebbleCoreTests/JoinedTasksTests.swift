import Foundation
import Testing
@testable import PebbleCore

/// Two engines as one: each id reaches only the engine that gave it, even
/// when both count their ids the same way, and only `main`'s tasks are kept.
struct JoinedTasksTests {
    let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func joined() -> (JoinedTasks, LocalFakeEngine, LocalFakeEngine) {
        let main = LocalFakeEngine(rule: .isolated(), origin: origin)
        let scripted = LocalFakeEngine(rule: .isolated(), origin: origin)
        return (JoinedTasks(main: main, scripted: scripted), main, scripted)
    }

    static let script = TaskScript(title: "Look into the pool", steps: [.init("Reading", duration: 2, todo: "read")],
                                   doneLine: "Done")

    @Test func theSameIdFromEachEngineNeverReachesTheOther() throws {
        let (joined, main, scripted) = joined()
        let own = joined.start(TaskRequest(title: "Book the car service"))
        let beside = joined.start(Self.script)
        // Both engines counted their first task the same way.
        #expect(main.tasks.first?.id == scripted.tasks.first?.id)
        #expect(own != beside)
        #expect(Set(joined.tasks.map(\.id)) == [own, beside])

        // Stopping one leaves the other going.
        #expect(joined.stop(own))
        #expect(main.task(own)?.state == .stopped)
        #expect(scripted.tasks.first?.isActive == true)
        // Dismissing it never takes the scripted one, which shares its inner id.
        #expect(joined.dismiss(own))
        #expect(main.tasks.isEmpty)
        #expect(scripted.tasks.count == 1)
        // The scripted one's id, without its prefix, reaches neither.
        let inner = try #require(scripted.tasks.first?.id)
        #expect(!joined.stop(inner))
        #expect(scripted.tasks.first?.isActive == true)
        #expect(joined.stop(beside))
        #expect(scripted.tasks.first?.state == .stopped)
        #expect(joined.dismiss(beside))
        #expect(joined.tasks.isEmpty)
    }

    @Test func retryReachesOnlyTheEngineThatGaveTheId() throws {
        let (joined, main, scripted) = joined()
        let own = main.start(SampleTasks.lunch)
        let beside = joined.start(SampleTasks.lunch)
        for _ in 0..<120 where main.task(own)?.isStuck != true {
            main.advance(by: 1)
            joined.advance(by: 1)
        }
        #expect(main.task(own)?.isStuck == true)
        #expect(joined.tasks.first { $0.id == beside }?.isStuck == true)
        #expect(joined.retry(own))
        #expect(main.task(own)?.state == .running)
        #expect(scripted.tasks.first?.isStuck == true)
        #expect(joined.retry(beside))
        #expect(scripted.tasks.first?.state == .running)
    }

    /// Nothing is kept through it, so a task store never holds a scripted
    /// task: `main` keeps its own.
    @Test func nothingIsKeptThroughItAndBothAreForgotten() {
        let (joined, _, _) = joined()
        #expect(!((joined as Any) is any KeepsTasks))
        let runner = ReconRunner(engine: joined, provider: SampleSources())
        _ = joined.start(TaskRequest(title: "Book the car service"))
        _ = joined.start(Self.script)
        #expect(runner.saved().isEmpty)
        let cleared = joined.clear()
        #expect(cleared.forgotten == 2)
        #expect(joined.tasks.isEmpty)
    }

    @Test func observersHearEitherEngineInOrder() {
        let (joined, _, _) = joined()
        let heard = Heard()
        let watch = joined.observe { heard.add($0.sequence, $0.tasks.count) }
        defer { watch.cancel() }
        _ = joined.start(TaskRequest(title: "Book the car service"))
        _ = joined.start(Self.script)
        joined.advance(by: 1)
        let seen = heard.all
        #expect(seen.map(\.sequence) == seen.map(\.sequence).sorted())
        #expect(Set(seen.map(\.sequence)).count == seen.count)
        #expect(seen.last?.count == 2)
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(sequence: Int, count: Int)] = []
        func add(_ sequence: Int, _ count: Int) { lock.lock(); list.append((sequence, count)); lock.unlock() }
        var all: [(sequence: Int, count: Int)] { lock.lock(); defer { lock.unlock() }; return list }
    }
}
