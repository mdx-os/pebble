import Foundation
import SourceScan
import Testing

/// Nothing a test makes outlives it: not a defaults suite written to
/// `~/Library/Preferences`, and not a window left open, or released twice,
/// when a `#require` throws partway through.
enum TestCleanup {
    /// Each place in `text` that makes a defaults suite or a window without
    /// cleaning up in the same block. A suite, made as `UserDefaults(` or
    /// `UserDefaults.init(`, needs a `let` name that is a fresh UUID, so
    /// tests run side by side never share one, and a `defer` that calls
    /// `removePersistentDomain(forName:)` with that same name. A window
    /// needs `isReleasedWhenClosed = false`, since under ARC a window
    /// released on close is released twice, and a `defer` that closes it.
    static func problems(in text: String, file: String) -> [String] {
        let source = SwiftSource(text)
        var problems: [String] = []
        let suites = source.calls(named: ["UserDefaults"])
            + source.calls(named: ["init"]).filter {
                String(source.code[..<$0.offset]).range(of: #"\bUserDefaults\s*\.\s*\z"#, options: .regularExpression) != nil
            }
        for call in suites where call.arguments.hasPrefix("suiteName:") {
            let braces = source.enclosingBraces(of: call.offset)
            let block = braces.map(source.contents(of:)) ?? ""
            let name = call.arguments.dropFirst("suiteName:".count).trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"\A[A-Za-z_]\w*\z"#, options: .regularExpression) != nil else {
                problems.append("\(file):\(call.line): name the suite with a let, so its removal can name it too")
                continue
            }
            if !isFreshName(name, before: call.offset, in: braces, of: source) {
                problems.append("\(file):\(call.line): the suite \(name) is not a fresh UUID name, "
                    + "so tests run side by side could share it")
            }
            if !defers(block, #"\.removePersistentDomain\(\s*forName:\s*\#(name)\s*\)"#) {
                problems.append("\(file):\(call.line): a defaults suite with no "
                    + "defer { defaults.removePersistentDomain(forName: \(name)) } in the same block")
            }
        }
        for call in source.calls(named: ["NSWindow"]) {
            let block = source.enclosingBraces(of: call.offset).map(source.contents(of:)) ?? ""
            if block.range(of: #"\.isReleasedWhenClosed\s*=\s*false"#, options: .regularExpression) == nil {
                problems.append("\(file):\(call.line): a window without isReleasedWhenClosed = false")
            }
            if !defers(block, #"\.close\(\)"#) {
                problems.append("\(file):\(call.line): a window not closed in a defer")
            }
        }
        return problems
    }

    /// True when `name` is a `let` in the same block, before `offset`, set
    /// to a string literal that holds `\(UUID().uuidString)`.
    private static func isFreshName(_ name: String, before offset: Int, in braces: Range<Int>?,
                                    of source: SwiftSource) -> Bool {
        let start = braces.map { $0.lowerBound + 1 } ?? 0
        guard start < offset else { return false }
        let code = String(source.code[start..<offset])
        // The last one before `offset`, found going forward.
        var last: Range<String.Index>?
        var from = code.startIndex
        while let next = code.range(of: #"\blet\s+\#(name)\s*=\s*""#, options: .regularExpression,
                                    range: from..<code.endIndex) {
            last = next
            from = next.upperBound
        }
        guard let found = last else { return false }
        let quote = start + code.distance(from: code.startIndex, to: found.upperBound) - 1
        guard let literal = source.literals.first(where: { $0.offset == quote }) else { return false }
        return literal.text.contains(#"\(UUID().uuidString)"#)
    }

    /// True when `block` has a `defer` whose body matches `pattern`.
    private static func defers(_ block: String, _ pattern: String) -> Bool {
        let source = SwiftSource(block)
        var from = 0
        let code = String(source.code)
        while let found = code.range(of: #"\bdefer\s*\{"#, options: .regularExpression,
                                     range: code.index(code.startIndex, offsetBy: from)..<code.endIndex) {
            let offset = code.distance(from: code.startIndex, to: found.lowerBound)
            guard let braces = source.braces(after: offset) else { break }
            if source.contents(of: braces).range(of: pattern, options: .regularExpression) != nil { return true }
            from = braces.upperBound
        }
        return false
    }
}

struct TestCleanupTests {
    /// PERMANENT GUARD. Every defaults suite and window the tests make is
    /// cleaned up in a defer.
    @Test func everySuiteAndWindowInTheTestsIsCleanedUp() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let files = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Tests"))
        #expect(files.count > 20)
        for file in files {
            for problem in TestCleanup.problems(in: file.text, file: file.name) {
                Issue.record(Comment(rawValue: problem))
            }
        }
    }

    @Test func theGuardCatchesWhatIsLeftBehind() {
        let wrong = [
            // A suite never removed, or removed only on the happy path.
            "func a() throws {\n let d = try #require(UserDefaults(suiteName: suite))\n}",
            "func a() throws {\n let d = try #require(UserDefaults(suiteName: suite))\n d.removePersistentDomain(forName: suite)\n}",
            "func a() { f(looks: UserDefaults(suiteName: \"x\")!) }",
            // Removing some other suite doesn't count.
            "func a() throws {\n let suite = \"a.\\(UUID().uuidString)\"\n let d = try #require(UserDefaults(suiteName: suite))\n"
                + " defer { d.removePersistentDomain(forName: other) }\n}",
            // Made through init, the same suite.
            "func a() throws {\n let suite = \"a.\\(UUID().uuidString)\"\n let d = try #require(UserDefaults.init(suiteName: suite))\n}",
            // A fixed name, shared by tests run side by side.
            "func a() throws {\n let suite = \"first-run.hidden\"\n let d = try #require(UserDefaults(suiteName: suite))\n"
                + " defer { d.removePersistentDomain(forName: suite) }\n}",
            "func a() throws {\n let d = try #require(UserDefaults(suiteName: suite))\n"
                + " defer { d.removePersistentDomain(forName: suite) }\n}",
            // A window released on close, or closed only at the end.
            "func a() {\n let w = NSWindow()\n defer { w.close() }\n}",
            "func a() {\n let w = NSWindow()\n w.isReleasedWhenClosed = false\n w.close()\n}",
            // Cleaned up in some other block doesn't count.
            "func a() {\n let w = NSWindow()\n}\nfunc b() {\n w.isReleasedWhenClosed = false\n defer { w.close() }\n}",
        ]
        for text in wrong {
            #expect(!TestCleanup.problems(in: text, file: "Wrong.swift").isEmpty, "missed: \(text)")
        }
        let right = [
            "func a() throws {\n let suite = \"a.\\(UUID().uuidString)\"\n let d = try #require(UserDefaults(suiteName: suite))\n"
                + " defer { d.removePersistentDomain(forName: suite) }\n}",
            "func a() throws {\n let suite = \"a.\\(UUID().uuidString)\"\n let d = try #require(UserDefaults.init(suiteName: suite))\n"
                + " defer { d.removePersistentDomain(forName: suite) }\n}",
            "func a() {\n let w = NSWindow()\n w.isReleasedWhenClosed = false\n defer { w.close() }\n}",
            "let standard = UserDefaults.standard",
            "// UserDefaults(suiteName: x) in a comment",
        ]
        for text in right {
            #expect(TestCleanup.problems(in: text, file: "Right.swift").isEmpty, "flagged: \(text)")
        }
    }
}
