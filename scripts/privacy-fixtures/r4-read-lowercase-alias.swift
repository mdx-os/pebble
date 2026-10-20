// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

typealias bytes = Data
func fixtureRead(_ remote: URL) throws -> Data { try bytes(contentsOf: remote) }
