// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
// A type from elsewhere given a URL: it may load it, so it is reviewed.
import Foundation

func fixtureOpen(_ remote: URL) -> Any { FixtureLoader(url: remote) }
