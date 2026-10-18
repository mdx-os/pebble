import Foundation

/// Swift source read just well enough for the guards in the tests: code,
/// comments and string literals told apart, and calls matched through their
/// balanced closing paren across lines.
///
/// This is not a Swift parser. It knows line and block comments (nested
/// too), plain, multi-line and raw string literals, and the `\( )`
/// interpolations inside them. That is all the guards need, and it means a
/// comment or a word inside a string is never taken for code.
public struct SwiftSource: Sendable {
    /// One string literal, with what it says and where it starts.
    public struct Literal: Sendable, Equatable {
        /// What is between the quotes, interpolations and all.
        public let text: String
        /// The line the opening quote is on, from 1.
        public let line: Int
        /// Where the opening quote is in `code`.
        public let offset: Int
        /// Just past the closing quote in `code`.
        public let end: Int
    }

    /// One call, such as `.foregroundStyle(...)`, with its arguments.
    public struct Call: Sendable, Equatable {
        public let name: String
        /// The arguments as code, comments and string contents blanked, with
        /// runs of white space folded to one space.
        public let arguments: String
        /// The line the call's name is on, from 1.
        public let line: Int
        /// Where the call's name starts in `code`.
        public let offset: Int
        /// Just past the call's closing paren in `code`.
        public let end: Int
    }

    /// The code of the trailing closure right after `call`, between its
    /// balanced braces, or nil when no `{` follows.
    public func trailingClosure(of call: Call) -> String? {
        trailingClosureBraces(of: call).map { String(code[($0.lowerBound + 1)..<min($0.upperBound, code.count)]) }
    }

    /// Where the trailing closure's `{` and its matching `}` are in `code`,
    /// as `open..<close`, or nil when no `{` follows the call.
    public func trailingClosureBraces(of call: Call) -> Range<Int>? {
        var open = call.end
        while open < code.count, code[open].isWhitespace { open += 1 }
        guard open < code.count, code[open] == "{" else { return nil }
        var depth = 0
        var close = open
        while close < code.count {
            if code[close] == "{" { depth += 1 }
            if code[close] == "}" { depth -= 1; if depth == 0 { break } }
            close += 1
        }
        return open..<close
    }

    /// The source with every comment and every string literal's contents
    /// turned to spaces. Quotes and new lines stay, so offsets and line
    /// numbers are the same as in the original.
    public let code: [Character]
    public let literals: [Literal]

    public init(_ text: String) {
        let chars = Array(text)
        var code = chars
        var literals: [Literal] = []
        var line = 1
        var i = 0

        func blank(_ index: Int) {
            if chars[index] != "\n" { code[index] = " " }
        }
        func at(_ index: Int, _ string: String) -> Bool {
            let wanted = Array(string)
            guard index + wanted.count <= chars.count else { return false }
            return Array(chars[index..<index + wanted.count]) == wanted
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                line += 1
                i += 1
            } else if at(i, "//") {
                while i < chars.count, chars[i] != "\n" { blank(i); i += 1 }
            } else if at(i, "/*") {
                var depth = 0
                repeat {
                    if at(i, "/*") { depth += 1; blank(i); blank(i + 1); i += 2 }
                    else if at(i, "*/") { depth -= 1; blank(i); blank(i + 1); i += 2 }
                    else { if chars[i] == "\n" { line += 1 }; blank(i); i += 1 }
                } while i < chars.count && depth > 0
            } else if c == "#" || c == "\"" {
                // A raw string starts with one or more # before its quote.
                var hashes = 0
                while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
                guard i + hashes < chars.count, chars[i + hashes] == "\"" else {
                    i += max(hashes, 1)
                    continue
                }
                let start = i
                let startLine = line
                var j = i + hashes
                let multiline = at(j, "\"\"\"")
                j += multiline ? 3 : 1
                let opened = j
                let quote = multiline ? "\"\"\"" : "\""
                let closer = quote + String(repeating: "#", count: hashes)
                let escape = "\\" + String(repeating: "#", count: hashes)
                var end = chars.count
                while j < chars.count {
                    if at(j, escape) {
                        let after = j + escape.count
                        if after < chars.count, chars[after] == "(" {
                            // An interpolation: skip to its balanced close.
                            // A string inside it is skipped whole, so a
                            // paren in its words never counts.
                            var depth = 0
                            var k = after
                            while k < chars.count {
                                if chars[k] == "\"" {
                                    k += 1
                                    while k < chars.count, chars[k] != "\"", chars[k] != "\n" {
                                        k += chars[k] == "\\" ? 2 : 1
                                    }
                                    k += 1
                                    continue
                                }
                                if chars[k] == "(" { depth += 1 }
                                if chars[k] == ")" { depth -= 1; if depth == 0 { break } }
                                if chars[k] == "\n" { line += 1 }
                                k += 1
                            }
                            j = k + 1
                        } else {
                            // An escape. A `\` at the end of a line in a
                            // multi-line string joins the lines, and the new
                            // line it skips still counts.
                            if after < chars.count, chars[after] == "\n" { line += 1 }
                            j = after + 1
                        }
                        continue
                    }
                    if at(j, closer) { end = j; break }
                    if chars[j] == "\n" { line += 1 }
                    j += 1
                }
                let contents = String(chars[opened..<min(end, chars.count)])
                literals.append(Literal(text: contents, line: startLine, offset: start,
                                        end: min(end + closer.count, chars.count)))
                for k in opened..<min(end, chars.count) { blank(k) }
                i = min(end + closer.count, chars.count)
            } else {
                i += 1
            }
        }
        self.code = code
        self.literals = literals
    }

    /// The line, from 1, that `offset` in `code` is on.
    public func line(at offset: Int) -> Int {
        code[..<min(offset, code.count)].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The code just before `offset`, from the start of the line `lines`
    /// lines above it.
    public func code(before offset: Int, lines: Int) -> String {
        var start = offset
        var seen = 0
        while start > 0 {
            if code[start - 1] == "\n" {
                seen += 1
                if seen > lines { break }
            }
            start -= 1
        }
        return String(code[start..<offset])
    }

    /// Every call to one of `names`, written `name(` with nothing but white
    /// space between, new lines included, and not part of a longer name.
    /// Arguments run to the balanced closing paren, across lines.
    public func calls(named names: Set<String>) -> [Call] {
        var found: [Call] = []
        var i = 0
        while i < code.count {
            guard code[i].isLetter || code[i] == "_",
                  i == 0 || !(code[i - 1].isLetter || code[i - 1].isNumber || code[i - 1] == "_") else {
                i += 1
                continue
            }
            var j = i
            while j < code.count, code[j].isLetter || code[j].isNumber || code[j] == "_" { j += 1 }
            let name = String(code[i..<j])
            var open = j
            while open < code.count, code[open].isWhitespace { open += 1 }
            guard names.contains(name), open < code.count, code[open] == "(" else {
                i = j
                continue
            }
            var depth = 0
            var close = open
            while close < code.count {
                if code[close] == "(" { depth += 1 }
                if code[close] == ")" { depth -= 1; if depth == 0 { break } }
                close += 1
            }
            let raw = String(code[(open + 1)..<min(close, code.count)])
            let folded = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            found.append(Call(name: name, arguments: folded, line: line(at: i), offset: i,
                              end: min(close + 1, code.count)))
            i = j
        }
        return found
    }

    /// Every `.swift` file under `folder`, by path relative to it. Both
    /// sides resolve symlinks, such as `/var` and `/private/var`, the same
    /// way, so the names never come out cut in the wrong place.
    public static func files(under folder: URL) throws -> [(name: String, text: String)] {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let walk = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: nil) else { return [] }
        let base = resolved.pathComponents
        let urls = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try urls.map { url in
            let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard Array(parts.prefix(base.count)) == base else { throw Outside(path: url.path, folder: folder.path) }
            let name = parts.dropFirst(base.count).joined(separator: "/")
            return (name, try String(contentsOf: url, encoding: .utf8))
        }.sorted { $0.name < $1.name }
    }

    /// A file that resolves to somewhere outside the folder it was found in.
    public struct Outside: Error, CustomStringConvertible {
        public let path: String
        public let folder: String
        public var description: String { "\(path) is not under \(folder)" }
    }

    /// The repository's root, found from a test file's `#filePath`.
    public static func repositoryRoot(from filePath: String) -> URL {
        var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) { return url }
            url = url.deletingLastPathComponent()
        }
        return url
    }
}
