#if os(macOS)
import Foundation
import SourceScan
import Testing

/// `make verify` builds only the iOS Simulator's Release build and leaves
/// the Mac's to its macOS archive. `scripts/verify-coverage-check.sh`
/// reads the Makefile and fails if verify stops covering a Release build
/// that `make build-release` makes, such as when archive leaves verify.
struct VerifyCoverageTests {
    @Test func verifyCoversEveryReleaseBuild() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["scripts/verify-coverage-check.sh"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("verify covers Release for iOS Simulator, macOS"), "\(output)")
    }
}
#endif
