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
        // The output is read on a thread of its own, and the wait for it has
        // a generous limit, so a check that hangs fails the test instead of
        // holding the run.
        let read = ReadOutput()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            read.data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 60) == .success else {
            process.terminate()
            Issue.record("scripts/verify-coverage-check.sh ran past 60 s and was stopped")
            return
        }
        let output = String(decoding: read.data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("verify covers Release for iOS Simulator, macOS"), "\(output)")
    }
}

/// What the check printed, written by the reading thread before it signals
/// and read only after the signal.
private final class ReadOutput: @unchecked Sendable {
    var data = Data()
}
#endif
