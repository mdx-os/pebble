// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

extension Data {
    static func fixtureRead(_ remote: URL) throws -> Data { try Self(contentsOf: remote) }
}
