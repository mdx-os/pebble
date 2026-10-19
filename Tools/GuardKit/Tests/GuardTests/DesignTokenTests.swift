import Foundation
import GuardScan
import SourceScan
import Testing

/// Every screen in PebbleUI takes its colors and type sizes from `Theme`:
/// no literal color and no fixed font size outside Theme.swift. The rules
/// are `TokenLint`, and what each must catch is in `GuardWrongCaseTests`.
struct DesignTokenTests {
    static func screenSources() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let screens = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI"))
        return screens.map { ("PebbleUI/\($0.name)", $0.text) }
    }

    /// PERMANENT GUARD.
    @Test func noScreenSpellsOutAColorOrAFontSize() throws {
        let files = try Self.screenSources()
        #expect(files.count > 5)
        #expect(files.contains { $0.name == TokenLint.themeFile }, "Theme.swift is where the tokens live")
        for file in files {
            for problem in TokenLint.problems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }

    /// Theme.swift really does spell colors out, so leaving it out of the
    /// sweep is what keeps the sweep quiet there, not an empty rule.
    @Test func theThemeFileWouldBeFlaggedUnderAnotherName() throws {
        let theme = try #require(try Self.screenSources().first { $0.name == TokenLint.themeFile })
        let found = TokenLint.problems(in: SyntaxSource.shared(theme.text), file: "PebbleUI/Other.swift")
        #expect(found.contains { $0.rule == "token.literalColor" })
        #expect(found.contains { $0.rule == "token.fixedFont" })
    }
}
