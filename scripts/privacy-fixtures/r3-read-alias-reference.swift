// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

typealias FixtureBytes = Data
func fixtureCopies(_ all: [Data]) -> [FixtureBytes] { all.map(FixtureBytes.init) }
