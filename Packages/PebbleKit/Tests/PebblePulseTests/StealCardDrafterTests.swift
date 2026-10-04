import Foundation
import PebbleCore
import PebblePulse
import Testing

struct HeuristicCardDrafterTests {
    private let brands = ["Muse", "Meta", "Grok", "OpenAI", "ChatGPT", "Codex", "xAI", "WhatsApp"]

    @Test func emptyInputMakesNoCards() async {
        let cards = await HeuristicCardDrafter().draft(modelInput: "   ")
        #expect(cards.isEmpty)
    }

    @Test func connectedAppsScorePrivacyZero() async throws {
        let cards = await HeuristicCardDrafter().draft(modelInput: """
        ### Muse on the App Store

        source: app-store-muse
        url: https://apps.apple.com/us/app/muse-from-meta/id6760173601

        notes: Muse now works with more of your favorite apps, so your personal agent can do more for you.
        """)
        let card = try #require(cards.first)
        #expect(card.sourceID == "app-store-muse")
        #expect(card.sourceTitle == "Muse on the App Store")
        #expect(card.fit.rejectsPrivacy)
        #expect(card.fit.privacy == 0)
        #expect(card.markdown().contains("Privacy: 0 (adapt or reject)"))
        #expect(card.effort == .large)
        assertNoBrand(in: card)
    }

    @Test func removedDiffLineIsNotTheCard() async throws {
        let cards = await HeuristicCardDrafter().draft(modelInput: """
        ### Example

        source: app-store-muse
        url: https://apps.apple.com/us/app/muse-from-meta/id6760173601

        --- pulse/snapshots/app-store-muse.txt
        +++ pulse/snapshots/app-store-muse.txt
        @@ -1,2 +1,2 @@
        -notes: Connect your financial accounts
        +notes: Bug fixes and improvements
        """)
        let card = try #require(cards.first)
        #expect(card.fit.privacy == 2)
        #expect(card.effort == .small)
        #expect(!card.what.lowercased().contains("financial"))
        #expect(!card.pattern.lowercased().contains("financial"))
    }

    @Test func moneyChangeIsAdaptOrReject() async throws {
        let cards = await HeuristicCardDrafter().draft(modelInput: """
        ### OpenAI on Releasebot

        source: releasebot-openai
        url: https://releasebot.io/updates/openai

        summary: Rolls out a way to connect financial accounts for spending insights.
        """)
        let card = try #require(cards.first)
        #expect(card.fit.rejectsPrivacy)
        #expect(card.id == "releasebot-openai-money")
        assertNoBrand(in: card)
    }

    @Test func liveSnapshotsDraftOneCardEach() async throws {
        let root = repoRoot()
        let directory = root.appendingPathComponent("pulse/snapshots")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 7)
        var input = ""
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let title = text.components(separatedBy: "\n").first { $0.hasPrefix("title: ") }?
                .dropFirst("title: ".count) ?? "Change"
            input += "### \(title)\n\n\(text)\n\n"
        }
        let cards = await HeuristicCardDrafter().draft(modelInput: input)
        #expect(cards.count == files.count)
        let muse = try #require(cards.first { $0.sourceID == "app-store-muse" })
        #expect(muse.fit.rejectsPrivacy)
        let openai = try #require(cards.first { $0.sourceID == "releasebot-openai" })
        #expect(openai.fit.rejectsPrivacy)
        #expect(openai.id == "releasebot-openai-money")
        let closed = try #require(cards.first { $0.sourceID == "releasebot-xai" })
        #expect(closed.fit.openWeights == 0)
        for card in cards {
            assertNoBrand(in: card)
            #expect(!card.pattern.contains("```"))
            #expect(!card.pattern.contains("{"))
        }
    }

    private func assertNoBrand(in card: StealCard) {
        let fields = [card.what, card.complaint, card.pattern]
        for field in fields {
            for brand in brands {
                #expect(!field.localizedCaseInsensitiveContains(brand), "\(brand) leaked into \(field)")
            }
        }
    }
}

struct CardDrafterPlugTests {
    @Test func missingKeyStillUsesTheLocalDrafter() async throws {
        let choice = CardDrafters.make(environment: [:])
        #expect(choice.name == "local")
        let cards = await choice.drafter.draft(modelInput: """
        ### Muse on the App Store

        source: app-store-muse

        notes: Muse now works with more of your favorite apps.
        """)
        #expect(cards.first?.fit.privacy == 0)
    }

    @Test func httpModeWithoutAURLStaysLocal() {
        let choice = CardDrafters.make(environment: ["PULSE_CARD_DRAFTER": "http"])
        #expect(choice.name == "local")
    }

    @Test func httpDrafterPostsOnlyTheModelInput() async throws {
        let transport = RecordingTransport(response: HTTPResponse(status: 200, body: Data(#"""
        {"cards":[{"id":"remote-1","what":"A remote reading of the change.","sourceID":"app-store-muse","sourceTitle":"Muse on the App Store","complaint":"People repeat the same task.","pattern":"Record the task once and run it when asked.","effort":"small","fit":{"privacy":1,"localFirst":2,"openWeights":2}}]}
        """#.utf8)))
        let drafter = HTTPCardDrafter(
            endpoint: URL(string: "https://example.com/cards")!,
            bearerToken: "unit-test-key-9f3a",
            transport: transport
        )
        let cards = await drafter.draft(modelInput: "### Example\n\nnotes: hello from the diff")
        let request = try #require(await transport.requests.first)
        let body = try #require(String(data: request.body, encoding: .utf8))
        #expect(body.contains("hello from the diff"))
        #expect(request.headers["Authorization"] == "Bearer unit-test-key-9f3a")
        #expect(cards.count == 1)
        #expect(cards.first?.pattern == "Record the task once and run it when asked.")
        let choice = CardDrafters.make(
            environment: [
                "PULSE_CARD_DRAFTER": "http",
                "PULSE_CARD_DRAFTER_URL": "https://example.com/cards",
                "PULSE_CARD_DRAFTER_KEY": "unit-test-key-9f3a",
            ],
            transport: transport
        )
        #expect(choice.name == "http")
    }

    @Test func drafterDoesNotSeeUnchangedText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SnapshotStore(directory: directory)
        let kept = PulseSource(
            id: "kept",
            title: "Kept source",
            kind: .firstParty,
            cadence: .daily,
            url: URL(string: "https://example.com/kept")
        )
        let fresh = PulseSource(
            id: "fresh",
            title: "Fresh source",
            kind: .firstParty,
            cadence: .daily,
            url: URL(string: "https://example.com/fresh")
        )
        let fetcher = StubFetcher(pages: [
            kept.url!.absoluteString: FetchedPage(
                url: kept.url!,
                status: 200,
                contentType: "text/markdown",
                body: "# Kept\n\nUNIQUE_UNCHANGED_TOKEN stays on this page.\n"
            ),
            fresh.url!.absoluteString: FetchedPage(
                url: fresh.url!,
                status: 200,
                contentType: "text/markdown",
                body: "# Fresh\n\nNothing to report yet in this first copy.\n"
            ),
        ])
        let runner = PulseRunner(
            fetcher: fetcher,
            search: StubSearch(result: .skipped("no")),
            store: store,
            snapshotPrefix: "pulse/snapshots",
            now: Date(timeIntervalSince1970: 0),
            drafter: SpyDrafter()
        )
        _ = await runner.run(sources: [kept, fresh])
        await fetcher.setBody(
            "# Fresh\n\nThe agent now asks before it sends a message to anyone.\n",
            for: fresh.url!
        )
        let spy = SpyDrafter()
        let second = PulseRunner(
            fetcher: fetcher,
            search: StubSearch(result: .skipped("no")),
            store: store,
            snapshotPrefix: "pulse/snapshots",
            now: Date(timeIntervalSince1970: 1),
            drafter: spy
        )
        _ = await second.run(sources: [kept, fresh])
        let seen = await spy.seen
        #expect(seen.contains("asks before it sends"))
        #expect(!seen.contains("UNIQUE_UNCHANGED_TOKEN"))
    }
}

private actor SpyDrafter: CardDrafting {
    let name = "spy"
    var seen = ""

    func draft(modelInput: String) async -> [StealCard] {
        seen = modelInput
        return []
    }
}
