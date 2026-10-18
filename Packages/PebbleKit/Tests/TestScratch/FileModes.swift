import Foundation
import Testing

/// For the few tests that make a file fail to read or erase with file
/// modes, where the store has no stand in for that, as
/// `BackgroundStoreFaults` is for the summaries. Root ignores file modes,
/// so as root those tests would show nothing. On a machine of one's own
/// they skip and say why. In CI they never skip: they fail, so a runner
/// that tests as root can't leave the suite quietly green. Use both traits:
/// `@Test(.fileModesHoldOrCI, .failsAsRoot)`. `BackgroundTests` checks each
/// test has both.
public enum FileModes {
    public static var hold: Bool { geteuid() != 0 }
    /// `swift test` passes the test `CI` as it is. `xcodebuild` passes on
    /// only variables named `TEST_RUNNER_` something, with the prefix taken
    /// off, so CI that sets `TEST_RUNNER_CI` arrives as `CI`. That name is
    /// read too, for a runner that passes it on as it is.
    public static var inCI: Bool { inCI(ProcessInfo.processInfo.environment) }

    public static func inCI(_ environment: [String: String]) -> Bool {
        environment["CI"] != nil || environment["TEST_RUNNER_CI"] != nil
    }
}

/// Records a failure, rather than run the test, when file modes don't hold.
public struct FailsAsRoot: TestTrait, TestScoping {
    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        guard FileModes.hold else {
            Issue.record("file modes don't hold for root, so this test can't show anything: run the tests as another user")
            return
        }
        try await function()
    }
}

extension Trait where Self == FailsAsRoot {
    public static var failsAsRoot: Self { FailsAsRoot() }
}

extension Trait where Self == ConditionTrait {
    public static var fileModesHoldOrCI: Self {
        .enabled(if: FileModes.hold || FileModes.inCI, "file modes don't hold for root")
    }
}
