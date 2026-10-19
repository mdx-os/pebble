// into: Packages/PebbleKit/Sources/PebbleCore
// expect: ok
// A plain type this file makes may take a url:, a method's url: reads
// nothing, and lines outside an extension of URL is just a name.
import Foundation

struct FixtureSource { var url: URL }
final class FixtureBox { let url: URL; init(url: URL) { self.url = url } }

func fixtureKeep(_ link: URL, _ shown: FixtureShown) -> [String] {
    let source = FixtureSource(url: link)
    let box = FixtureBox(url: source.url)
    var lines = [shown.title(url: box.url)]
    lines.append(contentsOf: ["done"])
    return lines
}

struct FixtureShown { func title(url: URL) -> String { url.lastPathComponent } }

extension URL {
    var fixtureName: String { lastPathComponent }
}
