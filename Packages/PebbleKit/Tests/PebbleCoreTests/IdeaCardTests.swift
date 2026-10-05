import Foundation
import PebbleCore
import Testing

struct IdeaCardTests {
    @Test func roundTripsThroughJSON() throws {
        let card = IdeaCard(
            id: "second-check",
            title: "A second check before something is sent",
            summary: "Ask a separate pass to confirm a message before it goes out.",
            sourceName: "Example",
            sourceURL: URL(string: "https://example.com/notes")!,
            complaint: "People worry a message went out before they were ready.",
            pattern: "A separate check, with a short trail of what was planned and what happened.",
            effort: .medium,
            fit: IdeaFit(privacy: 0, localFirst: 3, openWeights: 2)
        )
        let digest = PulseDigest(
            generatedAt: Date(timeIntervalSince1970: 1_759_689_600),
            observations: [],
            modelInput: "",
            ideaCards: [card]
        )
        let decoded = try PulseDigest.decode(digest.json())
        #expect(decoded.ideaCards == [card])
        #expect(decoded.ideaCards[0].fit.blocksOnPrivacy)
    }

    @Test func privacyAboveZeroDoesNotBlock() {
        let fit = IdeaFit(privacy: 1, localFirst: 0, openWeights: 0)
        #expect(!fit.blocksOnPrivacy)
    }
}
