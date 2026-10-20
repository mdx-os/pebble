// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
// The alias, typealias fixturebytes = Data, lives in another file.
import Foundation

func fixtureRead(_ remote: URL) throws -> Data { try fixturebytes(contentsOf: remote) }
