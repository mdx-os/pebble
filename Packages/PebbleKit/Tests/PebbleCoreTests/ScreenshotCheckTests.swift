#if os(macOS)
import Foundation
import SourceScan
import Testing

/// `scripts/check-screenshots.sh` names a scene it doesn't know, rather than
/// letting the showcase fall back to hello and fail as "no orange fill".
struct ScreenshotCheckTests {
    /// Runs the check on an empty folder, with `script` as the screenshots
    /// script it reads scene names from. Its exit status and what it wrote.
    private func check(script: URL?) throws -> (status: Int32, output: String) {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["scripts/check-screenshots.sh", empty.path]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PEBBLE_SHOTS_SCRIPT"] = script?.path
        process.environment = environment
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func anUnknownSceneIsNamed() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let real = try String(contentsOf: root.appendingPathComponent("scripts/screenshots.sh"), encoding: .utf8)
        #expect(real.contains("todayNeedsYou:"), "the iPad shots still ask for the scene this test misspells")
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID().uuidString).sh")
        try real.replacingOccurrences(of: "todayNeedsYou:", with: "todayNeedsYu:").write(to: bad, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bad) }
        let wrong = try check(script: bad)
        #expect(wrong.status != 0)
        #expect(wrong.output.contains("unknown scene \"todayNeedsYu\""), "\(wrong.output)")

        // The real script's scenes are all known, so it gets as far as the
        // missing files in the empty folder.
        let right = try check(script: nil)
        #expect(right.status != 0)
        #expect(!right.output.contains("unknown scene"), "\(right.output)")
        #expect(right.output.contains("is missing"), "\(right.output)")
    }

    /// A scene check with nothing to check fails, rather than passing with
    /// nothing checked: the script is missing, or it asks for no scene the
    /// check can read.
    @Test func aSceneCheckWithNothingToCheckFails() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).sh")
        let gone = try check(script: missing)
        #expect(gone.status != 0)
        #expect(gone.output.contains("\(missing.path) is missing, so no scene"), "\(gone.output)")

        let none = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID().uuidString).sh")
        try "#!/bin/sh\nshots='today:ipad'\n".write(to: none, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: none) }
        let empty = try check(script: none)
        #expect(empty.status != 0)
        #expect(empty.output.contains("found no scenes asked for"), "\(empty.output)")
    }
}
#endif
