import Foundation
import SourceScan
import Testing

/// `make brand-check` keeps the product's name out of code. This keeps
/// both names, the product's and the codename, out of the folders and
/// files the app writes, where they would outlive any rename. A folder is
/// named by the app's bundle instead, as `TaskStore.appFolder` does.
struct DiskNameTests {
    /// Paths that predate this guard and already hold people's things.
    /// Moving them would lose what is there, so they stay, and no new one
    /// joins them.
    static let allowed: Set<String> = [
        // The notes folder, shipped before this guard.
        "PebbleCore/Memory.swift: pebble",
    ]

    static func names(root: URL) throws -> [String] {
        let config = try String(contentsOf: root.appendingPathComponent("Config/Brand.xcconfig"), encoding: .utf8)
        let brand = try #require(config.split(separator: "\n").first { $0.hasPrefix("BRAND_NAME") }?
            .split(separator: "=").last?.trimmingCharacters(in: .whitespaces))
        #expect(!brand.isEmpty)
        return [brand.lowercased(), "pebble"]
    }

    /// PERMANENT GUARD.
    @Test func noPathTheAppWritesSpellsAName() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let names = try Self.names(root: root)
        var scanned = 0
        for folder in ["Packages/PebbleKit/Sources", "App/Sources"] {
            for file in try SwiftSource.files(under: root.appendingPathComponent(folder)) {
                let source = SwiftSource(file.text)
                for call in source.calls(named: ["appendingPathComponent", "appending"]) {
                    scanned += 1
                    for literal in source.literals where literal.offset > call.offset && literal.offset < call.end {
                        let text = literal.text.lowercased()
                        guard names.contains(where: text.contains),
                              !Self.allowed.contains("\(file.name): \(literal.text)") else { continue }
                        Issue.record("\(folder)/\(file.name):\(literal.line) names a path \"\(literal.text)\"")
                    }
                }
            }
        }
        #expect(scanned > 5, "the scan found the calls it looks at")
    }

    /// The guard itself catches a path spelled with either name.
    @Test func theGuardCatchesANameInAPath() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let names = try Self.names(root: root)
        for name in names {
            let source = SwiftSource("let url = base.appendingPathComponent(\"\(name)\", isDirectory: true)")
            let call = try #require(source.calls(named: ["appendingPathComponent"]).first)
            let hits = source.literals.filter { $0.offset > call.offset && $0.offset < call.end }
                .filter { literal in names.contains(where: literal.text.lowercased().contains) }
            #expect(hits.count == 1, "\(name)")
        }
    }
}
