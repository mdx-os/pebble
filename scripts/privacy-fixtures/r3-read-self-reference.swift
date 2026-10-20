// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

extension Data {
    static func fixtureCopies(_ all: [Data]) -> [Data] { all.map(Self.init) }
}
