import Foundation
import PebbleCore
import PebblePulse
import Testing

struct PageNormalizerTests {
    @Test func appStoreFixtureKeepsHistoryAndDropsVolatileNoise() throws {
        let html = try fixture("muse-app-store.html")
        let text = try PageNormalizer.normalize(kind: .appStore, body: html, contentType: "text/html")
        #expect(text.contains("name: Muse from Meta"))
        #expect(text.contains("version: 9.1"))
        #expect(text.contains("released: 2026-10-01"))
        #expect(text.contains("notes: Muse now works with more of your favorite apps"))
        #expect(text.contains("version: 4.2"))
        #expect(text.contains("released: 2026-09-05"))
        #expect(text.contains("PurpleSource211/v4/3a/54/3a/3a543a28-f9d9-1e02-e70e-55125b7f5338/Screen01.jpg"))
        #expect(text.components(separatedBy: "Screen01.jpg").count - 1 == 1)
        #expect(!text.contains("146947"))
        #expect(!text.contains("ago"))
        #expect(!text.contains("Sep 5"))
    }

    @Test func releaseFeedFixtureKeepsReleasesAndDropsChrome() throws {
        let html = try fixture("releasebot-openai.html")
        let text = try PageNormalizer.normalize(kind: .releaseFeed, body: html, contentType: "text/html")
        #expect(text.contains("count: 2"))
        #expect(text.contains("## October 2, 2026"))
        #expect(text.contains("product: ChatGPT"))
        #expect(text.contains("Finances"))
        #expect(text.contains("## 0.160.0"))
        #expect(!text.contains("First seen by Releasebot"))
        #expect(!text.contains("Date parsed from source"))
    }

    @Test func appStoreKeepsNumberedScreenshotsAndDropsPlaceholders() throws {
        let html = """
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Sample","description":"A sample app."}</script>
        <!-- HTML_TAG_START -->Bug fixes.<!-- HTML_TAG_END -->
        <span>Version 1.0</span> <time datetime="2026-10-01"></time>
        <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/94/10/09/94100916-25ed-f250-51f3-8937a4e1f49e/Placeholder.mill/64x64bb.jpg">
        <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/11/22/33/11111111-2222-3333-4444-555555555555/00_team-of-agents.png/230x499bb.jpg">
        <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/11/22/33/11111111-2222-3333-4444-555555555555/01_work.png/600x1300bb.jpg">
        """
        let text = try PageNormalizer.normalize(kind: .appStore, body: html, contentType: "text/html")
        #expect(text.contains("00_team-of-agents.png"))
        #expect(text.contains("01_work.png"))
        #expect(!text.contains("Placeholder"))
    }

    @Test func markdownPageDropsAnchorNoise() throws {
        let raw = """
        # What's new

        <a id="devday-roundup-title" />


        ### Meet your dot

        Give your dot ongoing responsibility.
        """
        let text = try PageNormalizer.normalize(kind: .firstParty, body: raw, contentType: "text/markdown")
        #expect(text.contains("# What's new"))
        #expect(text.contains("### Meet your dot"))
        #expect(!text.contains("<a id="))
        #expect(!text.contains("\n\n\n"))
    }
}

struct PulseRunnerTests {
    @Test func secondRunOfTheSamePageIsNotModelInput() async throws {
        let html = try fixture("muse-app-store.html")
        let source = museSource()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(directory: directory)
        let fetcher = StubFetcher(pages: [source.url!.absoluteString: page(source.url!, html: html)])
        let search = StubSearch(result: .skipped("X search skipped: XAI_API_KEY is not set."))
        let runner = PulseRunner(
            fetcher: fetcher,
            search: search,
            store: store,
            snapshotPrefix: "pulse/snapshots",
            now: try #require(ISO8601DateFormatter().date(from: "2026-10-04T18:00:00Z"))
        )

        let first = await runner.run(sources: [source, weeklySource(), xSearchSource()])
        #expect(first.entries.map(\.status) == [.new, .skipped])
        #expect(first.modelInput.contains("version: 9.1"))
        #expect(!first.modelInput.contains("146947"))
        let written = try store.read("app-store-muse")
        #expect(written?.contains("version: 9.1") == true)
        let weeklyCalls = await fetcher.requested
        #expect(weeklyCalls == [source.url!])

        let second = await runner.run(sources: [source])
        #expect(second.entries.map(\.status) == [.unchanged])
        #expect(second.modelInput.isEmpty)
        #expect(second.markdown().contains("## Unchanged"))
        #expect(!second.markdown().contains("favorite apps"))
        #expect(try store.read("app-store-muse") == written)

        await fetcher.setBody(html.replacingOccurrences(of: "Version 9.1", with: "Version 9.2"), for: source.url!)
        let third = await runner.run(sources: [source])
        #expect(third.entries.map(\.status) == [.changed])
        #expect(third.modelInput.contains("-version: 9.1"))
        #expect(third.modelInput.contains("+version: 9.2"))
        #expect(!third.modelInput.contains("PERSONAL PRODUCTIVITY"))
    }

    @Test func failedFetchDoesNotReplaceTheSnapshot() async throws {
        let source = museSource()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(directory: directory)
        try store.write("app-store-muse", text: "previous snapshot\n")
        let fetcher = StubFetcher(pages: [
            source.url!.absoluteString: FetchedPage(url: source.url!, status: 503, contentType: "text/html", body: "down"),
        ])
        let runner = PulseRunner(
            fetcher: fetcher,
            search: StubSearch(result: .skipped("no")),
            store: store,
            snapshotPrefix: "pulse/snapshots",
            now: Date(timeIntervalSince1970: 0)
        )
        let digest = await runner.run(sources: [source])
        #expect(digest.entries.first?.status == .failed)
        #expect(digest.modelInput.isEmpty)
        #expect(try store.read("app-store-muse") == "previous snapshot\n")
    }

    private func museSource() -> PulseSource {
        PulseSource(
            id: "app-store-muse",
            title: "Muse on the App Store",
            kind: .appStore,
            cadence: .daily,
            url: URL(string: "https://apps.apple.com/us/app/muse-from-meta/id6760173601")
        )
    }

    private func weeklySource() -> PulseSource {
        PulseSource(
            id: "press-weekly",
            title: "Weekly press",
            kind: .firstParty,
            cadence: .weekly,
            url: URL(string: "https://example.com/press")
        )
    }

    private func xSearchSource() -> PulseSource {
        PulseSource(
            id: "x-search-agents",
            title: "X posts on personal agents",
            kind: .xSearch,
            cadence: .daily,
            handles: ["bot"],
            query: "personal agents",
            postCap: 10
        )
    }

    private func page(_ url: URL, html: String) -> FetchedPage {
        FetchedPage(url: url, status: 200, contentType: "text/html", body: html)
    }
}

struct XSearchTests {
    @Test func missingKeyDoesNotSendARequest() async throws {
        let transport = RecordingTransport(response: HTTPResponse(status: 200, body: Data()))
        let client = XSearchClient(apiKey: "   ", transport: transport)
        let result = await client.search(xSource(cap: 10), now: Date())
        guard case .skipped(let reason) = result else {
            Issue.record("Expected a skip, got \(result)")
            return
        }
        #expect(reason.contains("XAI_API_KEY"))
        #expect(await transport.requests.isEmpty)
    }

    @Test func requestCarriesTheCapHandlesAndDateWindow() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-04T18:00:00Z"))
        let built = try XSearchRequest.make(source: xSource(cap: 10), now: now)
        let json = try #require(JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        #expect(json["model"] as? String == "grok-4.7")
        let input = try #require(json["input"] as? [[String: Any]])
        let prompt = try #require(input.first?["content"] as? String)
        #expect(prompt.contains("Fetch at most 10 posts."))
        #expect(prompt.contains("bot, OpenAI, MetaNewsroom"))
        let tools = try #require(json["tools"] as? [[String: Any]])
        let tool = try #require(tools.first)
        #expect(tool["type"] as? String == "x_search")
        #expect(tool["allowed_x_handles"] as? [String] == ["bot", "OpenAI", "MetaNewsroom"])
        #expect(tool["from_date"] as? String == "2026-10-03")
        #expect(tool["to_date"] as? String == "2026-10-04")
        #expect(tool["enable_image_understanding"] as? Bool == false)
        #expect(tool["enable_video_understanding"] as? Bool == false)
        #expect(built.cap == 10)
    }

    @Test func configCannotRaiseTheCap() {
        #expect(throws: PulseError.self) {
            try xSource(cap: 26).validate()
        }
    }

    @Test func overCapResponseIsDiscarded() throws {
        let body = """
        {"output":[{"content":[{"type":"output_text","text":"secret post body"}]}],
        "usage":{"server_side_tool_usage_details":{"x_posts_fetched":11,"x_users_fetched":0}}}
        """
        let result = XSearchResponse.interpret(data: Data(body.utf8), cap: 10)
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(message.contains("over the cap of 10"))
        #expect(!message.contains("secret post body"))
    }

    @Test func missingPostCountIsDiscarded() {
        let body = Data(#"{"output":[{"content":[{"text":"hello"}]}]}"#.utf8)
        let result = XSearchResponse.interpret(data: body, cap: 10)
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(message.contains("x_posts_fetched"))
        #expect(!message.contains("hello"))
    }

    @Test func withinCapResponseBecomesSnapshotText() throws {
        let body = """
        {"output":[{"content":[{"type":"output_text","text":"A launch landed.","annotations":[{"url":"https://x.com/bot/status/1"}]}]}],
        "usage":{"server_side_tool_usage_details":{"x_posts_fetched":1,"x_users_fetched":0}},
        "citations":["https://x.com/bot/status/1"]}
        """
        let result = XSearchResponse.interpret(data: Data(body.utf8), cap: 10)
        guard case .text(let text) = result else {
            Issue.record("Expected text, got \(result)")
            return
        }
        #expect(text.contains("posts fetched: 1"))
        #expect(text.contains("cap: 10"))
        #expect(text.contains("A launch landed."))
        #expect(text.contains("https://x.com/bot/status/1"))
        #expect(text.components(separatedBy: "https://x.com/bot/status/1").count - 1 == 1)
    }

    @Test func errorsDoNotEchoTheKey() async {
        let key = "unit-test-key-9f3a"
        let client = XSearchClient(apiKey: key, transport: ThrowingTransport(key: key))
        let result = await client.search(xSource(cap: 10), now: Date())
        guard case .failed(let message) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(message.contains("[redacted]"))
        #expect(!message.contains(key))
    }

    private func xSource(cap: Int) -> PulseSource {
        PulseSource(
            id: "x-search-agents",
            title: "X posts on personal agents",
            kind: .xSearch,
            cadence: .daily,
            handles: ["@bot", "OpenAI", "MetaNewsroom"],
            query: "launches, reviews, complaints, and developer chatter about personal agents",
            postCap: cap
        )
    }
}

struct PulseCommandTests {
    @Test func parseDefaultsAndHelp() throws {
        let parsed = try PulseInvocation.parse([])
        #expect(parsed.sources == "pulse/sources.json")
        #expect(parsed.snapshots == "pulse/snapshots")
        #expect(parsed.digest == "build/pulse/digest.md")
        #expect(!parsed.help)
        #expect(try PulseInvocation.parse(["--help"]).help)
    }

    @Test func unknownArgumentFails() {
        #expect(throws: PulseError.self) {
            try PulseInvocation.parse(["--push"])
        }
    }
}

struct SourceListTests {
    @Test func checkedInListMatchesTheDailySources() throws {
        let root = repoRoot()
        let url = root.appendingPathComponent("pulse/sources.json")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("Bearer "))
        #expect(!raw.contains("xai-"))
        let list = try PulseSourceList.load(from: url)
        let ids = list.sources.map(\.id)
        #expect(ids == [
            "app-store-muse",
            "app-store-grok-bot",
            "releasebot-openai",
            "releasebot-xai",
            "chatgpt-whats-new",
            "grok-bot-docs",
            "meta-newsroom-muse",
            "x-search-agents",
        ])
        #expect(list.sources[0].url?.absoluteString == "https://apps.apple.com/us/app/muse-from-meta/id6760173601")
        #expect(list.sources[1].url?.absoluteString == "https://apps.apple.com/us/app/grok-bot/id6794501026")
        #expect(list.sources[2].url?.absoluteString == "https://releasebot.io/updates/openai")
        #expect(list.sources[3].url?.absoluteString == "https://releasebot.io/updates/xai")
        #expect(list.sources[4].url?.absoluteString == "https://learn.chatgpt.com/docs/whats-new")
        #expect(list.sources[4].fetchURL?.absoluteString == "https://learn.chatgpt.com/docs/whats-new.md")
        #expect(list.sources[5].url?.absoluteString == "https://docs.x.ai/grok-bot/get-started")
        #expect(list.sources[6].url?.absoluteString == "https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/")
        let search = list.sources[7]
        #expect(search.handles == ["bot", "OpenAI", "MetaNewsroom"])
        #expect(search.postCap == 10)
        #expect(search.cadence == .daily)
    }
}

private func fixture(_ name: String, file: String = #filePath) throws -> String {
    let url = URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

func repoRoot(file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file).deletingLastPathComponent()
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("pulse/sources.json").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    preconditionFailure("Could not find pulse/sources.json")
}

actor StubFetcher: PageFetching {
    var pages: [String: FetchedPage]
    var requested: [URL] = []

    init(pages: [String: FetchedPage]) {
        self.pages = pages
    }

    func fetch(_ url: URL) async throws -> FetchedPage {
        requested.append(url)
        guard let page = pages[url.absoluteString] else {
            throw PulseError(message: "No stub page for \(url.absoluteString).")
        }
        return page
    }

    func setBody(_ body: String, for url: URL) {
        guard var page = pages[url.absoluteString] else { return }
        page.body = body
        pages[url.absoluteString] = page
    }
}

actor StubSearch: XSearching {
    var result: XSearchResult

    init(result: XSearchResult) {
        self.result = result
    }

    func search(_ source: PulseSource, now: Date) async -> XSearchResult {
        result
    }
}

actor RecordingTransport: HTTPSending {
    var requests: [HTTPRequest] = []
    var response: HTTPResponse

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

struct ThrowingTransport: HTTPSending {
    var key: String

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw PulseError(message: "transport saw \(key)")
    }
}
