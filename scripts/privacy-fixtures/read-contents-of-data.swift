// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

let fixtureData = try? Data(contentsOf: URL(string: "https://example.com/feed")!)
