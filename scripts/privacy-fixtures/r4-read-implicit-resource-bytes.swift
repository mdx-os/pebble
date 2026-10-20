// into: Packages/PebbleKit/Sources/PebbleCore
// expect: a read by contents of a URL that no one has checked
import Foundation

extension URL {
    func fixtureDrain() async throws {
        for try await byte in resourceBytes { _ = byte }
    }
}
