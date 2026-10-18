import Foundation
import Testing

/// For the few tests that make the notes fail to erase with file modes:
/// the notes' store has no stand in for that, as `BackgroundStoreFaults`
/// is for the summaries. Root ignores file modes, so as root those tests
/// would show nothing. On a machine of one's own they skip and say why.
/// In CI they never skip: they fail, so a runner that tests as root can't
/// leave the suite quietly green. Use both traits:
/// `@Test(.fileModesHoldOrCI, .failsAsRoot)`.
enum FileModes {
    static var hold: Bool { geteuid() != 0 }
    static var inCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }
}

/// Records a failure, rather than run the test, when file modes don't hold.
struct FailsAsRoot: TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard FileModes.hold else {
            Issue.record("file modes don't hold for root, so this test can't show anything: run the tests as another user")
            return
        }
        try await function()
    }
}

extension Trait where Self == FailsAsRoot {
    static var failsAsRoot: Self { FailsAsRoot() }
}

extension Trait where Self == ConditionTrait {
    static var fileModesHoldOrCI: Self {
        .enabled(if: FileModes.hold || FileModes.inCI, "file modes don't hold for root")
    }
}
