// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

typealias FixtureBytes = Data
func fixtureRead(_ remote: URL) throws -> FixtureBytes { try FixtureBytes(contentsOf: remote) }
