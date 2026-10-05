@testable import PebbleCore
import Testing

struct SnapshotTextTests {
    @Test func stripsRatingsRelativeDatesAndVolatileLines() {
        let raw = """
        Version 2.4 · 2d ago
        4.8 out of 5 · 12K Ratings
        Yesterday the notes said hello.
        Fixed the morning brief.
        1090 release notes
        curated from 330 sources by the team. Last updated: Oct 5, 2026
        Last updated: Oct 6, 2026
        Released 2026-10-01
        """
        let text = SnapshotText.normalize(raw)
        #expect(text.contains("Version 2.4"))
        #expect(text.contains("Fixed the morning brief."))
        #expect(text.contains("Released 2026-10-01"))
        #expect(!text.contains("ago"))
        #expect(!text.contains("Yesterday"))
        #expect(!text.contains("Ratings"))
        #expect(!text.contains("4.8"))
        #expect(!text.contains("release notes"))
        #expect(!text.contains("Last updated"))
        #expect(!text.contains("curated from"))
    }

    @Test func keepsAbsoluteDatesAndVersionNumbers() {
        let text = SnapshotText.normalize("version: 9.1\nreleased: 2026-10-01\nShipped calendar linking.")
        #expect(text == "version: 9.1\nreleased: 2026-10-01\nShipped calendar linking.")
    }

    @Test func ratingOnlyChangeDisappears() {
        let earlier = "Version 2.4 · 2d ago\n4.8 out of 5\n12K Ratings\nFixed the morning brief."
        let later = "Version 2.4 · 3d ago\n4.9 out of 5\n13K Ratings\nFixed the morning brief."
        #expect(SnapshotText.normalize(earlier) == SnapshotText.normalize(later))
        #expect(SnapshotDiff.changedBody(previous: earlier, current: later) == nil)
    }

    @Test func realChangeReachesTheDiff() {
        let earlier = "Version 2.4 · 2d ago\n12K Ratings\nFixed the morning brief."
        let later = "Version 2.4 · 3d ago\n13K Ratings\nYou can hand a task to a second pass."
        let body = SnapshotDiff.changedBody(previous: earlier, current: later)
        #expect(body?.contains("second pass") == true)
        #expect(body?.contains("Ratings") != true)
        #expect(body?.contains("ago") != true)
        #expect(body?.contains("+You can hand a task to a second pass.") == true)
        #expect(body?.contains("-Fixed the morning brief.") == true)
    }

    @Test func firstSnapshotIsTheWholeText() {
        let body = SnapshotDiff.changedBody(previous: nil, current: "Shipped calendar linking.")
        #expect(body == "Shipped calendar linking.")
    }

    @Test func emptyTextIsNotAChange() {
        #expect(SnapshotDiff.changedBody(previous: "Notes", current: "   \n") == nil)
    }

    @Test func normalizeIsIdempotent() {
        let once = SnapshotText.normalize("Version 2.4 · 2d ago\n4.8 out of 5\nHello.")
        #expect(SnapshotText.normalize(once) == once)
    }

    @Test func truncatesAtTheLimit() {
        let text = SnapshotText.normalize(String(repeating: "a", count: 50), limit: 10)
        #expect(text.hasPrefix(String(repeating: "a", count: 10)))
        #expect(text.hasSuffix("\n[truncated]"))
    }
}

struct LineDiffTests {
    @Test func showsAnInsertedLine() {
        let diff = LineDiff.unified(from: "one\ntwo", to: "one\ntwo\nthree")
        #expect(diff.contains("+three"))
        #expect(!diff.contains("-three"))
    }

    @Test func identicalTextHasNoDiff() {
        #expect(LineDiff.unified(from: "same", to: "same").isEmpty)
    }
}
