import Foundation
import PebbleCore

/// One snapshot file per source. The file is the text git diffs.
public struct SnapshotDocument {
    public static func render(source: PulseSource, body: String) -> String {
        var lines = [
            "source: \(source.id)",
            "title: \(source.title)",
            "kind: \(source.kind.rawValue)",
        ]
        if let url = source.url {
            lines.append("url: \(url.absoluteString)")
        }
        if let fetchURL = source.fetchURL {
            lines.append("fetch: \(fetchURL.absoluteString)")
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n\n" + trimmed + "\n"
    }
}

public struct SnapshotStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func read(_ id: String) throws -> String? {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func write(_ id: String, text: String) throws {
        let url = try fileURL(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func fileURL(for id: String) throws -> URL {
        guard id.range(of: #"^[a-z][a-z0-9]*(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw PulseError(message: "Unsafe snapshot id \(id).")
        }
        return directory.appendingPathComponent("\(id).txt")
    }
}
