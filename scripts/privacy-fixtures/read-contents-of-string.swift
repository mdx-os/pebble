// into: Packages/PebbleKit/Sources/PebbleUI
// expect: a read by contents of a URL that no one has checked
import Foundation

func fixturePage(_ remote: URL) -> String? { try? String(contentsOf: remote, encoding: .utf8) }
