// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

func fixtureBytes(_ url: URL) -> URL.AsyncBytes { url.resourceBytes }
