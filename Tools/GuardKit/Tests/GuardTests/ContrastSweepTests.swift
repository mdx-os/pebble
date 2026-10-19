import Foundation
import GuardScan
import SourceScan
import Testing

/// No screen colors words in a way `Theme.textPairs` doesn't cover. The
/// pairs themselves are checked in PebbleKit's `ContrastGuardTests`; the
/// rules are `ContrastLint`, and what each must catch is in
/// `GuardWrongCaseTests`.
struct ContrastSweepTests {
    /// Every screen's source: PebbleUI and the app target, which draws the
    /// Mac snapshot and could grow screens of its own.
    static func screenSources() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let screens = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App"))
        return screens.map { ("PebbleUI/\($0.name)", $0.text) } + app.map { ("App/\($0.name)", $0.text) }
    }

    /// PERMANENT GUARD. Both rule sets, contrast and accent, on every screen.
    @Test func noScreenColorsWordsOutsideThePairs() throws {
        let files = try Self.screenSources()
        #expect(files.count > 5)
        #expect(files.contains { $0.name.hasPrefix("App/") }, "the app's own sources are scanned too")
        for file in files {
            for problem in ContrastLint.problems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }

    /// The scan reports the line the call's name is on, even when its
    /// arguments run over several lines.
    @Test func theScanPointsAtTheCall() {
        let text = "let a = 1\n// .tint(.orange)\nText(\"x\")\n    .foregroundStyle(\n        Theme.accent)\n"
        #expect(ContrastLint.problems(in: text).map(\.line) == [4])
        #expect(ContrastLint.problems(in: text).map(\.column) == [6])
    }

    /// Lines still count after a `\` joins two lines of a multi-line
    /// string, and a paren in a string inside an interpolation never
    /// throws the count off.
    @Test func theScanCountsLinesThroughEveryKindOfString() {
        let joined = "let a = \"\"\"\n    one \\\n    two\n    \"\"\"\nText(\"x\")\n"
        #expect(SyntaxSource(joined).literals.map(\.line) == [1, 5])
        let paren = "let a = \"\\(f(\"(\"))\"\nText(\"x\")\n    .foregroundStyle(Theme.accent)\n"
        #expect(SyntaxSource(paren).literals.map(\.line) == [1, 1, 2])
        #expect(ContrastLint.problems(in: paren).map(\.line) == [3])
    }
}
