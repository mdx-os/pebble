import Foundation
@testable import PebbleCore
import SourceScan
import Testing

/// `make brand-check` keeps the product's name out of code. This keeps
/// both names, the product's and the codename, out of the folders, files
/// and settings suites the app writes, where they would outlive any
/// rename. The app's folder is a plain name instead, `TaskStore.appFolder`.
struct DiskNameTests {
    /// Paths that predate this guard and already hold people's things.
    /// Moving them would lose what is there, so they stay, and no new one
    /// joins them.
    static let allowed: Set<String> = [
        // The notes folder, shipped before this guard.
        "PebbleCore/Memory.swift: pebble",
        // Settings keys people's choices are under, shipped before this
        // guard looked at keys.
        "PebbleCore/AgentLook.swift: pebble.agent.look",
        "PebbleCore/AgentName.swift: pebble.agent.displayName",
        "PebbleCore/Onboarding.swift: pebble.agent.proactivity",
        "PebbleCore/Onboarding.swift: pebble.onboarding.finished",
    ]

    /// The calls that name a place on disk, a settings suite or a settings
    /// key. A call listed with labels counts only when one of them is
    /// written in it, so `URL(string:)` is never taken for a path.
    static let calls: [String: [String]?] = [
        "appendingPathComponent": nil,
        "appending": nil,
        "createDirectory": nil,
        "createFile": nil,
        "fileExists": ["atPath:"],
        "write": ["to:"],
        "URL": ["fileURLWithPath:", "filePath:"],
        "UserDefaults": ["suiteName:"],
        // Settings keys outlive a rename too.
        "set": ["forKey:"],
        "object": ["forKey:"],
        "string": ["forKey:"],
        "bool": ["forKey:"],
        "integer": ["forKey:"],
        "double": ["forKey:"],
        "data": ["forKey:"],
        "array": ["forKey:"],
        "dictionary": ["forKey:"],
        "removeObject": ["forKey:"],
    ]

    /// True when `call` is written with `label`, first or after a comma.
    static func writes(_ call: SwiftSource.Call, _ label: String) -> Bool {
        call.arguments.hasPrefix(label) || call.arguments.contains(", " + label) || call.arguments.contains("," + label)
    }

    static func names(root: URL) throws -> [String] {
        let config = try String(contentsOf: root.appendingPathComponent("Config/Brand.xcconfig"), encoding: .utf8)
        let brand = try #require(config.split(separator: "\n").first { $0.hasPrefix("BRAND_NAME") }?
            .split(separator: "=").last?.trimmingCharacters(in: .whitespaces))
        #expect(!brand.isEmpty)
        return [brand.lowercased(), "pebble"]
    }

    /// Every string literal in `source` that spells one of `names` and
    /// names a place the app writes: inside one of `calls`, or bound to a
    /// name with `let` or `var` that one of them is given. The guard and
    /// its own test both use this, so the test proves the guard.
    static func hits(in source: SwiftSource, names: [String]) -> [SwiftSource.Literal] {
        let names = names.map { $0.lowercased() }
        func spells(_ literal: SwiftSource.Literal) -> Bool {
            names.contains(where: literal.text.lowercased().contains)
        }
        let watched = source.calls(named: Set(calls.keys)).filter { call in
            guard let labels = calls[call.name] ?? nil else { return true }
            return labels.contains { writes(call, $0) }
        }
        let bound = bindings(in: source).filter { spells($0.literal) }
        var found: [SwiftSource.Literal] = []
        for call in watched {
            found += source.literals.filter { $0.offset > call.offset && $0.offset < call.end && spells($0) }
            let code = Array(source.code[call.offset..<call.end])
            found += bound.filter { mentions(code, $0.name) }.map(\.literal)
        }
        var seen: Set<Int> = []
        return found.filter { seen.insert($0.offset).inserted }.sorted { $0.offset < $1.offset }
    }

    /// Each `let name = "..."` or `var name: String = "..."`, with the
    /// literal it is given.
    static func bindings(in source: SwiftSource) -> [(name: String, literal: SwiftSource.Literal)] {
        let code = source.code
        let byOffset = Dictionary(source.literals.map { ($0.offset, $0) }, uniquingKeysWith: { first, _ in first })
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func skipSpace(_ i: inout Int) { while i < code.count, code[i] == " " || code[i] == "\t" { i += 1 } }
        var out: [(String, SwiftSource.Literal)] = []
        var i = 0
        while i < code.count {
            guard isWord(code[i]), i == 0 || !isWord(code[i - 1]) else { i += 1; continue }
            var j = i
            while j < code.count, isWord(code[j]) { j += 1 }
            let word = String(code[i..<j])
            i = j
            guard word == "let" || word == "var" else { continue }
            skipSpace(&j)
            let start = j
            while j < code.count, isWord(code[j]) { j += 1 }
            guard j > start else { continue }
            let name = String(code[start..<j])
            // An optional type, up to the `=`, on the same line.
            while j < code.count, code[j] != "=", code[j] != "\n", code[j] != "{" { j += 1 }
            guard j + 1 < code.count, code[j] == "=", code[j + 1] != "=" else { continue }
            j += 1
            skipSpace(&j)
            if let literal = byOffset[j] { out.append((name, literal)) }
        }
        return out
    }

    /// True when `name` is written in `code` as a whole word.
    static func mentions(_ code: [Character], _ name: String) -> Bool {
        let wanted = Array(name)
        guard wanted.count <= code.count else { return false }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        for start in 0...(code.count - wanted.count) where Array(code[start..<start + wanted.count]) == wanted {
            let before = start == 0 || !isWord(code[start - 1])
            let after = start + wanted.count == code.count || !isWord(code[start + wanted.count])
            if before && after { return true }
        }
        return false
    }

    /// PERMANENT GUARD.
    @Test func noPathTheAppWritesSpellsAName() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let names = try Self.names(root: root)
        var scanned = 0
        for folder in ["Packages/PebbleKit/Sources", "App/Sources"] {
            for file in try SwiftSource.files(under: root.appendingPathComponent(folder)) {
                let source = SwiftSource(file.text)
                scanned += source.calls(named: Set(Self.calls.keys)).count
                for literal in Self.hits(in: source, names: names)
                where !Self.allowed.contains("\(file.name): \(literal.text)") {
                    Issue.record("\(folder)/\(file.name):\(literal.line) names a path \"\(literal.text)\"")
                }
            }
        }
        #expect(scanned > 5, "the scan found the calls it looks at")
    }

    /// The guard's own matcher catches a name in every form it looks for,
    /// and leaves alone what isn't a place on disk.
    @Test func theGuardCatchesANameInAPath() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let names = try Self.names(root: root)
        for name in names {
            let caught = [
                "let url = base.appendingPathComponent(\"\(name)\", isDirectory: true)",
                "let url = base.appending(path: \"\(name)/tasks\")",
                "let url = URL(fileURLWithPath: \"/tmp/\(name)\")",
                "let url = URL(filePath: \"/tmp/\(name)\")",
                "try FileManager.default.createDirectory(atPath: \"/tmp/\(name)\", withIntermediateDirectories: true)",
                "let looks = UserDefaults(suiteName: \"\(name).looks\")",
                "FileManager.default.createFile(atPath: \"/tmp/\(name)\", contents: nil)",
                "try data.write(to: base.appendingPathComponent(\"\(name).json\"))",
                "try data.write(to: URL(filePath: \"/tmp/\(name).json\"), options: .atomic)",
                "let there = FileManager.default.fileExists(atPath: \"/tmp/\(name)\")",
                "defaults.set(true, forKey: \"\(name).seen\")",
                "let seen = defaults.bool(forKey: \"\(name).seen\")",
                "defaults.removeObject(forKey: \"\(name).seen\")",
                "static let key = \"\(name).seen\"\nlet seen = defaults.string(forKey: Self.key)",
                // A literal bound to a name first, then passed in.
                "let dir = \"\(name)\"\nlet url = base.appendingPathComponent(dir)",
                "static let folder: String = \"\(name.uppercased())\"\nlet url = base.appendingPathComponent(Self.folder)",
            ]
            for snippet in caught {
                #expect(Self.hits(in: SwiftSource(snippet), names: names).count == 1, "\(snippet)")
            }
            let left = [
                "let url = URL(string: \"https://\(name).example\")",
                "let title = \"\(name)\"",
                "let dir = \"\(name)\"\nlet url = base.appendingPathComponent(\"kept\")\nprint(dir)",
                "let url = base.appendingPathComponent(\"kept\") // \(name)",
                "let text = String(data: data, encoding: .utf8) ?? \"\(name)\"",
                "let choice = [\"\(name)\"].set(at: 0)",
            ]
            for snippet in left {
                #expect(Self.hits(in: SwiftSource(snippet), names: names).isEmpty, "\(snippet)")
            }
        }
    }

    /// Every bundle identifier the project sets, from `Config/*.xcconfig`
    /// and `project.yml`.
    static func bundleIdentifiers(root: URL) throws -> [String] {
        var texts: [String] = []
        let config = root.appendingPathComponent("Config")
        for name in try FileManager.default.contentsOfDirectory(atPath: config.path) where name.hasSuffix(".xcconfig") {
            texts.append(try String(contentsOf: config.appendingPathComponent(name), encoding: .utf8))
        }
        texts.append(try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8))
        return texts.flatMap { $0.split(separator: "\n") }.compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("#"), line.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER") else { return nil }
            return line.split(whereSeparator: { $0 == "=" || $0 == ":" }).dropFirst().joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// PERMANENT GUARD. The bundle identifier spells the codename, so the
    /// app's folder is never named by it, and holds neither name itself.
    /// Changing the identifier is a signing decision, so it stays, and is
    /// marked a known issue here: once it no longer spells a name, this
    /// test says so and the mark comes off.
    @Test func theAppsFolderSpellsNoNameWhateverTheBundleIdentifierDoes() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let names = try Self.names(root: root)
        let identifiers = try Self.bundleIdentifiers(root: root)
        #expect(identifiers.count >= 2, "the app and its UI tests: \(identifiers)")
        let folder = TaskStore.appFolder.lowercased()
        for name in names { #expect(!folder.contains(name), "the folder \(folder) spells \(name)") }
        for identifier in identifiers { #expect(!folder.contains(identifier.lowercased())) }
        withKnownIssue("The bundle identifier spells the codename. It is left as it is, a signing decision.") {
            for identifier in identifiers {
                #expect(!names.contains(where: identifier.lowercased().contains), "\(identifier)")
            }
        }
    }

    /// Answers Application Support with a folder of the test's own.
    private final class Support: FileManager, @unchecked Sendable {
        let base: URL
        init(base: URL) {
            self.base = base
            super.init()
        }
        override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            base
        }
    }

    /// PERMANENT GUARD. The store the app opens, and the one it falls back
    /// to, both live in the app's plain folder.
    @Test func theAppsStoreLivesInThePlainFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = Support(base: base)
        let store = try TaskStore.opened(fileManager: support)
        let root = base.appendingPathComponent(TaskStore.appFolder).standardizedFileURL.path
        let file = try #require(store.fileURL).standardizedFileURL.path
        #expect(file.hasPrefix(root + "/"), "\(file)")
        let fallback = try #require(TaskStore.forgetOnly(fileManager: support).forgets).standardizedFileURL.path
        #expect(fallback == file)
        // Only the plain folder is made there.
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == [TaskStore.appFolder])
    }

    /// Nothing the store keeps is backed up: not the file's folder, and not
    /// the folder with the marker and the nudge choice.
    @Test func theStoresFoldersAreLeftOutOfBackups() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try TaskStore.opened(fileManager: Support(base: base))
        let file = try #require(store.fileURL)
        let (_, marker) = TaskStore.location(base: base, app: TaskStore.appFolder)
        for folder in [file.deletingLastPathComponent(), marker.deletingLastPathComponent()] {
            let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(folder.lastPathComponent) is backed up")
        }
    }
}
