import PebbleCore
import Testing

struct IdeaDraftTests {
    @Test func emptyInputDraftsNothing() {
        #expect(IdeaDraft.cards(from: "").isEmpty)
        #expect(IdeaDraft.cards(from: "   \n").isEmpty)
    }

    @Test func draftsTheAddedSentenceAndLeavesTheComplaintHonest() {
        let input = """
        source: notes
        name: Notes
        url: https://example.com/notes

        --- previous
        +++ current
        @@ -1 +1 @@
        -Fixed the morning brief.
        +You can hand a task to a second pass.
        """
        let cards = IdeaDraft.cards(from: input)
        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.summary == "You can hand a task to a second pass.")
        #expect(card.title == "You can hand a task to a second pass")
        #expect(card.complaint == "The source does not say what problem this answers.")
        #expect(card.pattern == "You can hand a task to a second pass")
        #expect(card.effort == .small)
        #expect(card.fit == IdeaFit(privacy: 2, localFirst: 2, openWeights: 2))
        #expect(card.sourceName == "Notes")
        #expect(card.sourceURL.absoluteString == "https://example.com/notes")
    }

    @Test func usesAStatedProblemAsTheComplaint() {
        let input = """
        source: notes
        name: Notes
        url: https://example.com/notes

        The morning brief crashes when it is empty.
        """
        let card = IdeaDraft.cards(from: input)[0]
        #expect(card.complaint == "The morning brief crashes when it is empty.")
    }

    @Test func patternDropsProductNames() {
        let input = """
        source: app-store-muse
        name: App Store: Muse
        url: https://apps.apple.com/us/app/muse-from-meta/id6760173601

        Muse now keeps a second check before a message goes out.
        """
        let card = IdeaDraft.cards(from: input)[0]
        #expect(card.summary.contains("Muse"))
        #expect(!card.pattern.lowercased().contains("muse"))
        #expect(card.pattern.contains("second check"))
    }

    @Test func personalDataLeavingTheDeviceBlocksOnPrivacy() {
        let input = """
        source: notes
        name: Notes
        url: https://example.com/notes

        Link your email and calendar, then upload your messages.
        """
        let card = IdeaDraft.cards(from: input)[0]
        #expect(card.fit.blocksOnPrivacy)
        #expect(card.fit.privacy == 0)
    }

    @Test func cloudStorageLowersLocalFirstAndOpenWeightsCanRise() {
        let input = """
        source: docs
        name: Docs
        url: https://example.com/docs

        The helper requires cloud data storage and runs an open-weight model.
        """
        let fit = IdeaDraft.cards(from: input)[0].fit
        #expect(fit.localFirst == 0)
        #expect(fit.openWeights == 3)
        #expect(fit.blocksOnPrivacy)
    }

    @Test func skipsAVersionOnlyDiff() {
        let input = """
        source: app
        name: App
        url: https://example.com/app

        --- previous
        +++ current
        @@ -1 +1 @@
        -version: 9.1
        +version: 9.2
        """
        #expect(IdeaDraft.cards(from: input).isEmpty)
    }

    @Test func twoSectionsBecomeTwoCardsInOrder() {
        let input = """
        source: one
        name: One
        url: https://example.com/one

        A quieter morning brief.

        source: two
        name: Two
        url: https://example.com/two

        A second check before sending.
        """
        let cards = IdeaDraft.cards(from: input)
        #expect(cards.map(\.sourceName) == ["One", "Two"])
    }

    @Test func sameTextDraftsTheSameID() {
        let input = """
        source: notes
        name: Notes
        url: https://example.com/notes

        A second check before sending.
        """
        let first = IdeaDraft.cards(from: input)
        let second = IdeaDraft.cards(from: input)
        #expect(first.map(\.id) == second.map(\.id))
    }
}
