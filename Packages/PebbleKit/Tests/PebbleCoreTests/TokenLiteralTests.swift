import Foundation
import SourceScan
import Testing

/// PERMANENT GUARD. No Swift file holds a string literal shaped like a
/// signed token: three base64url parts, the first starting `eyJ`, joined by
/// dots. The secrets check takes one for a real token, made up or not, so a
/// test builds its token at run time from its parts instead.
struct TokenLiteralTests {
    static var shape: Regex<Substring> { /eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/ }

    /// Every Swift file in the package's sources and tests, the app and the
    /// app's UI tests.
    static func files() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        return try ["Packages/PebbleKit/Sources", "Packages/PebbleKit/Tests", "App", "AppUITests"].flatMap { folder in
            try SwiftSource.files(under: root.appendingPathComponent(folder)).map { ("\(folder)/\($0.name)", $0.text) }
        }
    }

    /// Where `files` hold a token shaped literal, by file and line only, so
    /// the value is never printed.
    static func tokenLiterals(in files: [(name: String, text: String)]) -> [String] {
        files.flatMap { file in
            SwiftSource(file.text).literals.filter { $0.text.contains(shape) }.map { "\(file.name):\($0.line)" }
        }
    }

    @Test func noSourceHoldsATokenShapedLiteral() throws {
        let files = try Self.files()
        #expect(files.contains { $0.name.hasPrefix("Packages/PebbleKit/Tests/PebbleModelTests/") })
        #expect(files.contains { $0.name.hasPrefix("AppUITests/") }, "the app's UI tests are swept too")
        for place in Self.tokenLiterals(in: files) {
            Issue.record("\(place) holds a string literal shaped like a token; build it from its parts at run time")
        }
    }

    /// The sweep finds a token in a plain, raw or multi-line literal, and
    /// not in parts kept apart, in a comment or with fewer than three parts.
    @Test func theSweepFindsATokenShapedLiteral() {
        let token = ["eyJhbGci", "eyJzdWIi", "c2ln-_9"].joined(separator: ".")
        for found in ["let a = \"\(token)\"", "let a = #\"x \(token) y\"#", "let a = \"\"\"\n\(token)\n\"\"\""] {
            #expect(Self.tokenLiterals(in: [("A.swift", found)]) == ["A.swift:1"], "\(found.prefix(10))")
        }
        let apart = "let a = [\"eyJhbGci\", \"eyJzdWIi\", \"c2ln\"].joined(separator: \".\")"
        for missed in [apart, "// \(token)\nlet a = 1", "let a = \"eyJhbGci.eyJzdWIi\"", "let a = \"eyJ\" + \".b.c\""] {
            #expect(Self.tokenLiterals(in: [("A.swift", missed)]).isEmpty, "\(missed.prefix(10))")
        }
    }
}
