import Foundation
import PebbleCore
import Testing

struct XSearchBudgetTests {
    @Test func rejectsACapAboveTheCeiling() {
        #expect(throws: PulseError.self) {
            try XSearchBudget(postCap: XSearchBudget.hardCeiling + 1)
        }
        #expect(throws: PulseError.self) {
            try XSearchBudget(postCap: 0)
        }
    }

    @Test func pricesTheCeilingInDollars() throws {
        let budget = try XSearchBudget(postCap: 10)
        #expect(budget.postCap == 10)
        #expect(XSearchBudget.estimatedCost(for: 10) == "0.050")
        #expect(XSearchBudget.estimatedCost(for: XSearchBudget.hardCeiling) == "0.125")
    }
}

struct PrincipleFitTests {
    @Test func privacyZeroMeansAdaptOrReject() throws {
        let fit = try PrincipleFit(privacy: 0, localFirst: 2, openWeights: 1)
        #expect(fit.rejectsPrivacy)
        #expect(fit.label(for: fit.privacy) == "0 (adapt or reject)")
        #expect(fit.label(for: 2) == "2 (fits)")
    }

    @Test func rejectsScoresOutsideZeroToTwo() {
        #expect(throws: PulseError.self) {
            try PrincipleFit(privacy: 3, localFirst: 1, openWeights: 1)
        }
    }

    @Test func decodingAlsoRejectsAnOutOfRangeScore() throws {
        let json = Data(#"{"privacy":9,"localFirst":1,"openWeights":1}"#.utf8)
        #expect(throws: PulseError.self) {
            try JSONDecoder().decode(PrincipleFit.self, from: json)
        }
    }
}

struct StealCardTests {
    @Test func rendersThePatternAndNotABrandToCopy() throws {
        let card = try sampleCard(privacy: 1)
        let text = card.markdown()
        #expect(text.contains("Pattern: Record a task once by doing it, then run it on a schedule the person can stop."))
        #expect(text.contains("Complaint: People repeat the same multi-step task and it still gets dropped."))
        #expect(text.contains("Effort: medium"))
        #expect(text.contains("Privacy: 1 (adapt)"))
        #expect(!text.contains("```"))
    }

    @Test func roundTripsThroughJSON() throws {
        let card = try sampleCard(privacy: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(card)
        let decoded = try JSONDecoder().decode(StealCard.self, from: data)
        #expect(decoded == card)
        #expect(decoded.fit.rejectsPrivacy)
        #expect(decoded.markdown().contains("Privacy: 0 (adapt or reject)"))
    }

    @Test func rejectsAnEmptyPattern() {
        #expect(throws: PulseError.self) {
            try sampleCard(privacy: 1, pattern: "  ")
        }
    }

    private func sampleCard(privacy: Int, pattern: String = "Record a task once by doing it, then run it on a schedule the person can stop.") throws -> StealCard {
        try StealCard(
            id: "show-then-schedule",
            what: "Show a task being done, then run that task on a schedule.",
            sourceID: "app-store-grok-bot",
            sourceTitle: "Grok Bot on the App Store",
            sourceURL: URL(string: "https://apps.apple.com/us/app/grok-bot/id6794501026"),
            complaint: "People repeat the same multi-step task and it still gets dropped.",
            pattern: pattern,
            effort: .medium,
            fit: try PrincipleFit(privacy: privacy, localFirst: 2, openWeights: 2)
        )
    }
}

struct LineDiffTests {
    @Test func identicalTextHasNoDiff() {
        #expect(LineDiff.unified(old: "same\n", new: "same\n", path: "pulse/snapshots/demo.txt") == nil)
    }

    @Test func middleChangeIsOneHunk() {
        let diff = LineDiff.unified(old: "a\nb\nc\n", new: "a\nx\nc\n", path: "pulse/snapshots/demo.txt")
        #expect(diff == """
        --- pulse/snapshots/demo.txt
        +++ pulse/snapshots/demo.txt
        @@ -1,3 +1,3 @@
         a
        -b
        +x
         c

        """)
    }

    @Test func newFileIsAllAdditions() {
        let diff = LineDiff.unified(old: "", new: "hello\n", path: "pulse/snapshots/demo.txt")
        #expect(diff == """
        --- /dev/null
        +++ pulse/snapshots/demo.txt
        @@ -0,0 +1,1 @@
        +hello

        """)
    }
}

struct PulseDigestTests {
    @Test func modelInputKeepsChangesAndDropsEverythingElse() throws {
        let digest = PulseDigest(
            generatedAt: try #require(ISO8601DateFormatter().date(from: "2026-10-04T18:00:00Z")),
            entries: [
                PulseDigest.Entry(
                    sourceID: "app-store-muse",
                    title: "Muse on the App Store",
                    url: URL(string: "https://apps.apple.com/us/app/muse-from-meta/id6760173601"),
                    status: .changed,
                    snapshotPath: "pulse/snapshots/app-store-muse.txt",
                    detail: "version: 9.2\n"
                ),
                PulseDigest.Entry(
                    sourceID: "releasebot-openai",
                    title: "OpenAI on Releasebot",
                    url: URL(string: "https://releasebot.io/updates/openai"),
                    status: .unchanged,
                    snapshotPath: "pulse/snapshots/releasebot-openai.txt",
                    detail: ""
                ),
                PulseDigest.Entry(
                    sourceID: "x-search-agents",
                    title: "X posts on personal agents",
                    url: nil,
                    status: .skipped,
                    snapshotPath: nil,
                    detail: "X search skipped: XAI_API_KEY is not set."
                ),
            ],
            cards: [try StealCardTests().sampleCardPublic()]
        )
        #expect(digest.modelInput.contains("version: 9.2"))
        #expect(!digest.modelInput.contains("XAI_API_KEY"))
        #expect(!digest.modelInput.contains("OpenAI on Releasebot"))
        let markdown = digest.markdown()
        #expect(markdown.contains("Generated: 2026-10-04T18:00:00Z"))
        #expect(markdown.contains("Changes worth reading: 1"))
        #expect(markdown.contains("Status: changed"))
        #expect(markdown.contains("## Unchanged"))
        #expect(markdown.contains("- OpenAI on Releasebot"))
        #expect(markdown.contains("Privacy: 0 (adapt or reject)"))
        #expect(!markdown.contains("```"))
    }
}

extension StealCardTests {
    fileprivate func sampleCardPublic() throws -> StealCard {
        try sampleCard(privacy: 0)
    }
}
