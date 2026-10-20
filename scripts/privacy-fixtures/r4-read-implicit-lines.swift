// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

typealias FixtureLink = URL
extension FixtureLink {
    func fixtureCount() async throws -> Int {
        var count = 0
        for try await _ in lines { count += 1 }
        return count
    }
}
