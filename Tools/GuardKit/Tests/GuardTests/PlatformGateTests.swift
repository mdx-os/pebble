import Foundation
import GuardScan
import SourceScan
import Testing

/// PebbleKit's tests build for iOS too, so a test that reaches for AppKit
/// must sit behind a Mac-only `#if`. The rules are `PlatformGate` in
/// GuardScan, and what each must catch is in `GuardWrongCaseTests`. This
/// package builds only for the Mac, so its own sources aren't swept.
struct PlatformGateTests {
    /// PERMANENT GUARD. No test names AppKit, imports it or uses a Mac-only
    /// Foundation type outside a branch that holds only on the Mac, so the
    /// tests still build for iOS.
    @Test func everyAppKitNameInTheTestsIsBehindAMacGate() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let files = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Tests"))
        #expect(files.count > 20)
        for file in files {
            for problem in PlatformGate.ungated(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }
}
