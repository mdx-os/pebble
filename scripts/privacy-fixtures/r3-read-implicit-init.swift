// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

func fixtureRead(_ remote: URL) throws -> Data {
    let data: Data = try .init(contentsOf: remote)
    return data
}
