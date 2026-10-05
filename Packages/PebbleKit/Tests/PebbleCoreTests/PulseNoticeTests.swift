import Foundation
import PebbleCore
import Testing

struct PulseNoticeTests {
    @Test func aQuietRunRemovesAStaleNotice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = try PulseNotice.write(changedDigest(), to: directory)
        #expect(previous != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notify.md").path))

        let written = try PulseNotice.write(quietDigest(), to: directory)
        #expect(written == nil)
        #expect(PulseNotice.markdown(for: quietDigest()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("notify.md").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.json").path))
    }

    @Test func aRealChangeWritesAStableNotice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let digest = changedDigest()
        let noticeURL = try #require(PulseNotice.write(digest, to: directory))
        let markdownOnce = try Data(contentsOf: noticeURL)
        let summaryOnce = try Data(contentsOf: directory.appendingPathComponent("summary.json"))
        let again = try #require(PulseNotice.write(digest, to: directory))
        #expect(again == noticeURL)
        #expect(try Data(contentsOf: noticeURL) == markdownOnce)
        #expect(try Data(contentsOf: directory.appendingPathComponent("summary.json")) == summaryOnce)

        let markdown = try String(contentsOf: noticeURL, encoding: .utf8)
        #expect(markdown == PulseNotice.markdown(for: digest))
        #expect(markdown == """
        # Competitor watch

        2026-10-05T00:00:00Z

        1 source changed. 1 idea card.

        ## Idea cards

        ### You can hand a task to a second pass

        Source: Notes
        https://example.com/notes

        You can hand a task to a second pass.

        The source does not say what problem this answers.

        Pattern: You can hand a task to a second pass.
        Effort: small
        Privacy: 1. Local models: 2. Open weights: 3.

        ## Changed sources

        - Notes (notes): https://example.com/notes
          First snapshot.

        Full digest: pulse/digest.json

        """)

        let summaryData = summaryOnce
        let summary = try PulseNoticeSummary.decode(summaryData)
        #expect(summary.changedSourceCount == 1)
        #expect(summary.ideaCardCount == 1)
        #expect(summary.changedSources == [
            PulseNoticeSummary.ChangedSource(
                id: "notes",
                name: "Notes",
                url: "https://example.com/notes",
                detail: "First snapshot."
            ),
        ])
        #expect(summary.ideaCards.map(\.id) == ["second-pass"])
        #expect(summary.ideaCards.map(\.effort) == ["small"])
        #expect(summary.ideaCards.map(\.sourceURL) == ["https://example.com/notes"])
        let text = try #require(String(data: summaryData, encoding: .utf8))
        #expect(text.contains("\"generatedAt\" : \"2026-10-05T00:00:00Z\""))
        #expect(text.hasSuffix("\n"))
        #expect(!text.contains("\\/"))
    }

    @Test func privacyZeroSaysToAdaptOrLeaveIt() {
        let card = sampleCard(privacy: 0)
        let digest = PulseDigest(
            generatedAt: utc(2026, 10, 5),
            observations: [],
            modelInput: "",
            ideaCards: [card]
        )
        let markdown = PulseNotice.markdown(for: digest)
        #expect(markdown.contains("Privacy: 0. Adapt this idea or leave it. Local models: 2. Open weights: 3."))
        #expect(markdown.contains("0 sources changed. 1 idea card."))
    }

    @Test func modelInputWithoutACardIsClipped() {
        let body = String(repeating: "a", count: 2_050)
        let digest = PulseDigest(
            generatedAt: utc(2026, 10, 5),
            observations: [
                SourceObservation(id: "notes", name: "Notes", url: "https://example.com/notes", outcome: .changed),
            ],
            modelInput: body,
            ideaCards: []
        )
        let markdown = PulseNotice.markdown(for: digest)
        #expect(markdown.contains("1 source changed. No idea cards."))
        #expect(markdown.contains("## What changed"))
        #expect(markdown.contains(String(repeating: "a", count: 2_000)))
        #expect(markdown.contains("The rest is in the full digest."))
        #expect(!markdown.contains(String(repeating: "a", count: 2_001)))
    }
}

private func quietDigest() -> PulseDigest {
    PulseDigest(
        generatedAt: utc(2026, 10, 5),
        observations: [
            SourceObservation(id: "notes", name: "Notes", url: "https://example.com/notes", outcome: .unchanged),
            SourceObservation(id: "x-search", name: "X Search", url: "https://docs.x.ai/developers/tools/x-search", outcome: .skipped, detail: "No XAI_API_KEY set."),
        ],
        modelInput: "",
        ideaCards: []
    )
}

private func changedDigest() -> PulseDigest {
    PulseDigest(
        generatedAt: utc(2026, 10, 5),
        observations: [
            SourceObservation(
                id: "notes",
                name: "Notes",
                url: "https://example.com/notes",
                outcome: .changed,
                detail: "First snapshot."
            ),
            SourceObservation(id: "quiet", name: "Quiet", url: "https://example.com/quiet", outcome: .unchanged),
        ],
        modelInput: "source: notes\n\nYou can hand a task to a second pass.",
        ideaCards: [sampleCard(privacy: 1)]
    )
}

private func sampleCard(privacy: Int) -> IdeaCard {
    IdeaCard(
        id: "second-pass",
        title: "You can hand a task to a second pass",
        summary: "You can hand a task to a second pass.",
        sourceName: "Notes",
        sourceURL: URL(string: "https://example.com/notes")!,
        complaint: "The source does not say what problem this answers.",
        pattern: "You can hand a task to a second pass.",
        effort: .small,
        fit: IdeaFit(privacy: privacy, localFirst: 2, openWeights: 3)
    )
}

private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
