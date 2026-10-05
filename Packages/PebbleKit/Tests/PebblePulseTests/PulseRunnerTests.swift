import Foundation
import PebbleCore
@testable import PebblePulse
import Testing

struct XSearchTests {
    @Test func capNeverExceeds25() {
        #expect(XSearchAPI.maxPosts == 25)
        #expect(XSearchAPI.cappedPostCount(10_000) == 25)
        #expect(XSearchAPI.cappedPostCount(25) == 25)
        #expect(XSearchAPI.cappedPostCount(3) == 3)
        #expect(XSearchAPI.cappedPostCount(-4) == 0)
    }

    @Test func requestAsksFor25PostsAndDisablesMedia() throws {
        let data = try XSearchAPI.requestBody(
            XSearchQuery(handles: ["@OpenAI", "MetaNewsroom"], fromDay: "2026-10-04", toDay: "2026-10-05")
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? String)
        #expect(content.contains("at most 25 posts"))
        #expect(!content.contains("26"))
        let tools = try #require(json["tools"] as? [[String: Any]])
        let tool = try #require(tools.first)
        #expect(tool["type"] as? String == "x_search")
        #expect(tool["allowed_x_handles"] as? [String] == ["OpenAI", "MetaNewsroom"])
        #expect(tool["from_date"] as? String == "2026-10-04")
        #expect(tool["to_date"] as? String == "2026-10-05")
        #expect(tool["enable_image_understanding"] as? Bool == false)
        #expect(tool["enable_video_understanding"] as? Bool == false)
    }

    @Test func parseKeepsAtMost25PostURLs() throws {
        var citations: [String] = ["https://x.com/i/user/99", "https://example.com/not-a-post"]
        for index in 1...30 {
            citations.append("https://x.com/OpenAI/status/\(index)")
        }
        citations.append("https://x.com/OpenAI/status/1")
        let payload: [String: Any] = [
            "citations": citations,
            "output": [
                [
                    "type": "message",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "A new approval step. 4.8 out of 5. 2d ago.",
                            "annotations": [
                                ["type": "url_citation", "url": "https://x.com/MetaNewsroom/status/99"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let hit = try XSearchAPI.parse(data)
        #expect(hit.postURLs.count == 25)
        #expect(hit.postURLs.contains(URL(string: "https://x.com/OpenAI/status/1")!))
        #expect(!hit.postURLs.contains(URL(string: "https://x.com/OpenAI/status/26")!))
        #expect(!hit.postURLs.map(\.absoluteString).contains("https://x.com/i/user/99"))
        #expect(hit.summary.contains("approval step"))
    }

    @Test func samePostsIgnoreARewrittenSummary() {
        let previous = "https://x.com/OpenAI/status/1"
        let snapshot = XPostDiff.snapshot(urls: [URL(string: "https://x.com/OpenAI/status/1")!])
        #expect(XPostDiff.modelBody(previous: previous, snapshot: snapshot, summary: "Totally different wording.") == nil)
    }

    @Test func newPostIncludesACleanedSummary() {
        let snapshot = XPostDiff.snapshot(urls: [
            URL(string: "https://x.com/OpenAI/status/2")!,
            URL(string: "https://x.com/OpenAI/status/1")!,
        ])
        let body = XPostDiff.modelBody(
            previous: "https://x.com/OpenAI/status/1",
            snapshot: snapshot,
            summary: "Shipped a second check. 12K Ratings. 3d ago."
        )
        #expect(body?.contains("https://x.com/OpenAI/status/2") == true)
        #expect(body?.contains("https://x.com/OpenAI/status/1") != true)
        #expect(body?.contains("second check") == true)
        #expect(body?.contains("Ratings") != true)
        #expect(body?.contains("ago") != true)
    }
}

struct SourceCatalogTests {
    @Test func repoListHasTheWatchSources() throws {
        let root = try repoRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("pulse/sources.json"))
        let sources = try PulseSourceList.load(data)
        let ids = sources.map(\.id)
        #expect(ids == [
            "app-store-muse",
            "app-store-grok-bot",
            "releasebot-openai",
            "releasebot-xai",
            "chatgpt-whats-new",
            "grok-bot-docs",
            "meta-newsroom",
            "x-search",
        ])
        let muse = try #require(sources.first { $0.id == "app-store-muse" })
        let grok = try #require(sources.first { $0.id == "app-store-grok-bot" })
        #expect(muse.appID == "6760173601")
        #expect(muse.url.absoluteString == "https://apps.apple.com/us/app/muse-from-meta/id6760173601")
        #expect(grok.appID == "6794501026")
        #expect(grok.url.absoluteString == "https://apps.apple.com/us/app/grok-bot/id6794501026")
        #expect(sources.first { $0.id == "releasebot-openai" }?.url.absoluteString == "https://releasebot.io/updates/openai")
        #expect(sources.first { $0.id == "releasebot-xai" }?.url.absoluteString == "https://releasebot.io/updates/xai")
        let chatgpt = try #require(sources.first { $0.id == "chatgpt-whats-new" })
        #expect(chatgpt.url.absoluteString == "https://learn.chatgpt.com/docs/whats-new")
        #expect(chatgpt.fetchURL?.absoluteString == "https://learn.chatgpt.com/docs/whats-new.md")
        let docs = try #require(sources.first { $0.id == "grok-bot-docs" })
        #expect(docs.url.absoluteString == "https://docs.x.ai/grok-bot/get-started")
        #expect(docs.fetchURL?.absoluteString == "https://docs.x.ai/grok-bot/get-started.md")
        #expect(sources.first { $0.id == "meta-newsroom" }?.url.absoluteString == "https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/")
        #expect(sources.first { $0.id == "x-search" }?.handles == ["bot", "OpenAI", "MetaNewsroom"])
    }

    @Test func rejectsABadAppID() {
        let source = PulseSource(
            id: "app-store-muse",
            name: "App Store: Muse",
            kind: .appStore,
            url: URL(string: "https://apps.apple.com/us/app/id1")!,
            appID: "not-a-number"
        )
        #expect(throws: PulseSourceError.badAppID("app-store-muse")) {
            try PulseSourceList.validate([source])
        }
    }
}

struct PulseRunnerTests {
    @Test func ratingNoiseDoesNotReachModelInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = PulseSource(
            id: "notes",
            name: "Notes",
            kind: .webPage,
            url: URL(string: "https://example.com/notes")!
        )
        let pages = ScriptedPages(bodies: [
            "https://example.com/notes": "<p>Version 2 <time datetime=\"2026-10-01\">2d ago</time></p><p>12K Ratings</p><p>Fixed the morning brief.</p>",
        ])
        let first = try await PulseRunner(pages: pages, now: day(2026, 10, 5)).run(sources: [source], snapshots: directory)
        #expect(first.observations.map(\.outcome) == [.changed])
        #expect(first.ideaCards.isEmpty)
        #expect(first.modelInput.contains("Fixed the morning brief."))
        #expect(!first.modelInput.contains("Ratings"))
        #expect(!first.modelInput.contains("ago"))

        pages.bodies["https://example.com/notes"] = "<p>Version 2 <time datetime=\"2026-10-01\">3d ago</time></p><p>13K Ratings</p><p>Fixed the morning brief.</p>"
        let second = try await PulseRunner(pages: pages, now: day(2026, 10, 6)).run(sources: [source], snapshots: directory)
        #expect(second.observations.map(\.outcome) == [.unchanged])
        #expect(second.modelInput.isEmpty)
    }

    @Test func aRealEditReachesModelInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = PulseSource(
            id: "notes",
            name: "Notes",
            kind: .webPage,
            url: URL(string: "https://example.com/notes")!
        )
        let pages = ScriptedPages(bodies: [
            "https://example.com/notes": "<p>Fixed the morning brief.</p>",
        ])
        _ = try await PulseRunner(pages: pages, now: day(2026, 10, 5)).run(sources: [source], snapshots: directory)
        pages.bodies["https://example.com/notes"] = "<p>You can hand a task to a second pass.</p>"
        let digest = try await PulseRunner(pages: pages, now: day(2026, 10, 6)).run(sources: [source], snapshots: directory)
        #expect(digest.observations.map(\.outcome) == [.changed])
        #expect(digest.modelInput.contains("source: notes"))
        #expect(digest.modelInput.contains("+You can hand a task to a second pass."))
        #expect(digest.ideaCards.isEmpty)
    }

    @Test func missingKeySkipsXSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = PulseSource(
            id: "x-search",
            name: "X Search",
            kind: .xSearch,
            url: URL(string: "https://docs.x.ai/developers/tools/x-search")!,
            handles: ["OpenAI"]
        )
        let search = SpySearch()
        let digest = try await PulseRunner(pages: ScriptedPages(bodies: [:]), search: search, apiKey: nil, now: day(2026, 10, 5))
            .run(sources: [source], snapshots: directory)
        #expect(digest.observations.map(\.outcome) == [.skipped])
        #expect(digest.modelInput.isEmpty)
        #expect(search.calls == 0)
    }

    @Test func xSearchUsesThePreviousDayWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = PulseSource(
            id: "x-search",
            name: "X Search",
            kind: .xSearch,
            url: URL(string: "https://docs.x.ai/developers/tools/x-search")!,
            handles: ["OpenAI"]
        )
        let search = SpySearch()
        search.hit = XSearchHit(
            postURLs: [URL(string: "https://x.com/OpenAI/status/7")!],
            summary: "Shipped a second check."
        )
        let digest = try await PulseRunner(pages: ScriptedPages(bodies: [:]), search: search, apiKey: "present", now: day(2026, 10, 5))
            .run(sources: [source], snapshots: directory)
        #expect(search.queries == [XSearchQuery(handles: ["OpenAI"], fromDay: "2026-10-04", toDay: "2026-10-05")])
        #expect(digest.observations.map(\.outcome) == [.changed])
        #expect(digest.modelInput.contains("https://x.com/OpenAI/status/7"))
        let stored = try String(contentsOf: directory.appendingPathComponent("x-search.txt"), encoding: .utf8)
        #expect(stored == "https://x.com/OpenAI/status/7")
    }

    @Test func aFailedFetchKeepsThePreviousSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = PulseSource(
            id: "notes",
            name: "Notes",
            kind: .webPage,
            url: URL(string: "https://example.com/notes")!
        )
        let pages = ScriptedPages(bodies: [
            "https://example.com/notes": "<p>Fixed the morning brief.</p>",
        ])
        _ = try await PulseRunner(pages: pages, now: day(2026, 10, 5)).run(sources: [source], snapshots: directory)
        pages.failures.insert("https://example.com/notes")
        let digest = try await PulseRunner(pages: pages, now: day(2026, 10, 6)).run(sources: [source], snapshots: directory)
        #expect(digest.observations.map(\.outcome) == [.failed])
        #expect(digest.modelInput.isEmpty)
        let stored = try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(stored.contains("Fixed the morning brief."))
    }
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func repoRoot() throws -> URL {
    var url = URL(filePath: #filePath)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("pulse/sources.json").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    throw PulseSourceError.undecodable
}

private final class ScriptedPages: PageFetching, @unchecked Sendable {
    var bodies: [String: String]
    var failures: Set<String> = []

    init(bodies: [String: String]) {
        self.bodies = bodies
    }

    func fetch(_ url: URL) async throws -> FetchedPage {
        if failures.contains(url.absoluteString) {
            throw PulseFailure.badStatus(url: url.absoluteString, status: 503)
        }
        guard let body = bodies[url.absoluteString] else {
            throw PulseFailure.badStatus(url: url.absoluteString, status: 404)
        }
        return FetchedPage(statusCode: 200, body: Data(body.utf8), mimeType: "text/html")
    }
}

private final class SpySearch: XSearching, @unchecked Sendable {
    var calls = 0
    var queries: [XSearchQuery] = []
    var hit = XSearchHit(postURLs: [], summary: "")

    func search(_ query: XSearchQuery) async throws -> XSearchHit {
        calls += 1
        queries.append(query)
        return hit
    }
}
