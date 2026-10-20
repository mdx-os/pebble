// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

// copyItem(at:to:) downloads when the source is not a file URL.
func fixtureCopy(_ remote: URL, to local: URL) throws {
    try FileManager.default.copyItem(at: remote, to: local)
}
