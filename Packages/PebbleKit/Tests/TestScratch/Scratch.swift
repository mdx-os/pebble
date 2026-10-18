import Foundation
import Testing

/// Each test's scratch files go in a folder of its own, removed once the
/// test ends, staged copies and switch files included.
public enum Scratch {
    @TaskLocal public static var folder: URL?

    public static func url(_ name: String) -> URL {
        (folder ?? FileManager.default.temporaryDirectory).appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }
}

public struct ScratchFiles: TestTrait, SuiteTrait, TestScoping {
    public init() {}

    public var isRecursive: Bool { true }

    public func scope(for test: Test, testCase: Test.Case?) -> ScratchFiles? {
        testCase == nil ? nil : self
    }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("background-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            // A test may leave its folder read only.
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? manager.removeItem(at: folder)
        }
        try await Scratch.$folder.withValue(folder) { try await function() }
    }
}

extension Trait where Self == ScratchFiles {
    public static var scratchFiles: Self { ScratchFiles() }
}
