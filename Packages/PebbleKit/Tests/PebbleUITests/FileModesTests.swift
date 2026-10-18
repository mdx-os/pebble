import TestScratch
import Testing

/// CI is found by either name, so a test that needs file modes fails as
/// root there rather than skip, however the runner passes the variable on.
struct FileModesTests {
    @Test func ciIsFoundByEitherName() {
        #expect(FileModes.inCI(["TEST_RUNNER_CI": "1"]), "as xcodebuild's runner may pass it on")
        #expect(FileModes.inCI(["CI": "true"]))
        #expect(!FileModes.inCI([:]))
        #expect(!FileModes.inCI(["TEST_RUNNER_OTHER": "1", "CIRCLE": "1"]))
    }
}
