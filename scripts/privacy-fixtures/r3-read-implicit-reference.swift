// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

func fixtureReader(like data: Data) -> (URL, Data.ReadingOptions) throws -> Data {
    type(of: data).init(contentsOf:options:)
}
