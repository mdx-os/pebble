import Foundation
import PebbleCore
@testable import PebblePulse
import Testing

struct HTMLTextTests {
    @Test func timeTagKeepsTheAbsoluteDay() {
        let html = """
        <html><body>
        <script>ignore 2d ago and 99K Ratings</script>
        <p>Version 9.1 <time datetime="2026-10-01T13:47:35.000Z">4d ago</time></p>
        <p>4.8 out of 5 &middot; 12K Ratings</p>
        <p>Shipped a quieter morning.</p>
        </body></html>
        """
        let text = SnapshotText.normalize(HTMLText.extract(html))
        #expect(text.contains("2026-10-01"))
        #expect(text.contains("Version 9.1"))
        #expect(text.contains("quieter morning"))
        #expect(!text.contains("ago"))
        #expect(!text.contains("Ratings"))
        #expect(!text.contains("ignore"))
    }

    @Test func newsArticleBeatsPageChrome() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@type":"NewsArticle","headline":"A new helper","datePublished":"2026-09-08T19:00:51+00:00","dateModified":"2026-09-30T20:53:21+00:00","articleBody":"It asks before it sends."}
        </script>
        </head><body>Language picker 2d ago 4.9 out of 5</body></html>
        """
        let text = SnapshotText.normalize(NewsArticleText.extract(from: html) ?? "")
        #expect(text.contains("headline: A new helper"))
        #expect(text.contains("published: 2026-09-08"))
        #expect(text.contains("It asks before it sends."))
        #expect(!text.contains("dateModified"))
        #expect(!text.contains("Language picker"))
        #expect(!text.contains("ago"))
    }
}

struct AppStoreSnapshotTests {
    @Test func rendersHistoryWithoutRatings() {
        let html = """
        <div>4.9 out of 5 156K Ratings <time datetime="2026-10-01">4d ago</time></div>
        {"page":"versionHistory","pageData":{"shelves":[{"items":[
          {"$kind":"TitledParagraph","text":"Muse now works with more of your favorite apps.","style":"detail","primarySubtitle":"9.1","secondarySubtitle":"Thu Oct 01 2026 06:49:33 GMT+0000 (Coordinated Universal Time)"},
          {"$kind":"TitledParagraph","text":"Same note.","style":"overview","primarySubtitle":"Version 9.1","secondarySubtitle":"Thu Oct 01 2026 06:49:33 GMT+0000"},
          {"$kind":"TitledParagraph","text":"Overall app improvements.","style":"detail","primarySubtitle":"9.0","secondarySubtitle":"Sat Sep 26 2026 18:41:05 GMT+0000"}
        ]}]}}
        """
        let lookup = """
        {"resultCount":1,"results":[{
          "trackName":"Muse from Meta","sellerName":"Meta Platforms, Inc.",
          "version":"9.1","averageUserRating":4.86101,"userRatingCount":153986,
          "screenshotUrls":["https://example.com/screen.jpg"]
        }]}
        """.data(using: .utf8)!
        let text = AppStoreSnapshot.text(pageHTML: html, lookupJSON: lookup, sourceName: "App Store: Muse")
        #expect(text.contains("name: Muse from Meta"))
        #expect(text.contains("seller: Meta Platforms, Inc."))
        #expect(text.contains("version: 9.1"))
        #expect(text.contains("released: 2026-10-01"))
        #expect(text.contains("version: 9.0"))
        #expect(text.contains("released: 2026-09-26"))
        #expect(text.contains("https://example.com/screen.jpg"))
        #expect(!text.contains("4.861"))
        #expect(!text.contains("153986"))
        #expect(!text.contains("Ratings"))
        #expect(!text.contains("ago"))
        #expect(!text.contains("06:49"))
        #expect(text.components(separatedBy: "version: 9.1").count == 2)
    }
}
