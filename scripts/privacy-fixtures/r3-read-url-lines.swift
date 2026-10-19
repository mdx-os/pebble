// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

func fixtureLines(_ url: URL) async throws {
    for try await line in url.lines { _ = line }
}
