import Foundation
import PebbleCore
import PebblePulse
import Testing

/// Hits the real source pages. Two fetches of each page must normalize to the
/// same text, and a second pulse run of that text must produce an empty model input.
struct LivePageTests {
    @Test func livePagesAreStableAndOnlyChangesReachTheDigest() async throws {
        let list = try PulseSourceList.load(from: repoRoot().appendingPathComponent("pulse/sources.json"))
        let fetcher = URLSessionPageFetcher()
        var captured: [String: FetchedPage] = [:]

        for source in list.sources where source.kind != .xSearch {
            let url = try #require(source.fetchLocation)
            let first = try await fetcher.fetch(url)
            #expect(first.status == 200, "\(source.id) returned HTTP \(first.status)")
            let second = try await fetcher.fetch(url)
            let left = try PageNormalizer.normalize(kind: source.kind, body: first.body, contentType: first.contentType)
            let right = try PageNormalizer.normalize(kind: source.kind, body: second.body, contentType: second.contentType)
            #expect(left == right, "\(source.id) was not stable across two fetches")
            #expect(left.contains(marker(for: source.id)), "\(source.id) missed \(marker(for: source.id))")
            if source.kind == .appStore {
                #expect(!left.contains(" ago"), "\(source.id) kept a relative date")
                #expect(left.contains("screenshots:"))
            }
            if source.kind == .releaseFeed {
                #expect(!left.contains("First seen by Releasebot"))
            }
            captured[url.absoluteString] = first
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = PulseRunner(
            fetcher: ReplayFetcher(pages: captured),
            search: StubSearch(result: .skipped("X search skipped: XAI_API_KEY is not set.")),
            store: SnapshotStore(directory: directory),
            snapshotPrefix: "pulse/snapshots",
            now: Date(timeIntervalSince1970: 1_759_600_800)
        )
        let firstRun = await runner.run(sources: list.sources)
        let pageSources = list.sources.filter { $0.kind != .xSearch }
        #expect(firstRun.entries.filter { $0.status == .new }.count == pageSources.count)
        #expect(firstRun.entries.contains { $0.status == .skipped })
        #expect(firstRun.modelInput.contains("version:"))
        #expect(!firstRun.modelInput.contains("XAI_API_KEY"))

        let secondRun = await runner.run(sources: list.sources)
        #expect(secondRun.entries.filter(\.isChange).isEmpty)
        #expect(secondRun.modelInput.isEmpty)
        #expect(secondRun.entries.contains { $0.sourceID == "x-search-agents" && $0.status == .skipped })
        let skippedFile = directory.appendingPathComponent("x-search-agents.txt")
        #expect(!FileManager.default.fileExists(atPath: skippedFile.path))
    }

    private func marker(for id: String) -> String {
        switch id {
        case "app-store-muse", "app-store-grok-bot":
            "version: "
        case "releasebot-openai", "releasebot-xai":
            "count: "
        case "chatgpt-whats-new":
            "What's new"
        case "grok-bot-docs":
            "Get started"
        case "meta-newsroom-muse":
            "Sentinel"
        default:
            id
        }
    }
}

private actor ReplayFetcher: PageFetching {
    let pages: [String: FetchedPage]

    init(pages: [String: FetchedPage]) {
        self.pages = pages
    }

    func fetch(_ url: URL) async throws -> FetchedPage {
        guard let page = pages[url.absoluteString] else {
            throw PulseError(message: "No captured page for \(url.absoluteString).")
        }
        return page
    }
}
