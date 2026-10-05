import Foundation
import PebbleCore

enum AppStoreLookup {
    static func url(appID: String) -> URL {
        URL(string: "https://itunes.apple.com/lookup?id=\(appID)&country=us")!
    }
}

enum AppStoreSnapshot {
    /// Version history, release notes, and screenshot URLs.
    ///
    /// Ratings are not read, even when the page and the lookup payload include them.
    static func text(pageHTML: String?, lookupJSON: Data?, sourceName: String) -> String {
        let lookup = lookupJSON.flatMap(decodeLookup)
        let versions = pageHTML.map(versionHistory) ?? []
        var lines: [String] = []
        let name = lookup?.trackName?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("name: \(name?.isEmpty == false ? name! : sourceName)")
        if let seller = lookup?.sellerName?.trimmingCharacters(in: .whitespacesAndNewlines), !seller.isEmpty {
            lines.append("seller: \(seller)")
        }
        lines.append("")

        if !versions.isEmpty {
            for version in versions {
                lines.append("version: \(version.number)")
                if let day = version.day { lines.append("released: \(day)") }
                lines.append(version.notes)
                lines.append("")
            }
        } else if let lookup {
            if let version = lookup.version, !version.isEmpty {
                lines.append("version: \(version)")
            }
            if let raw = lookup.currentVersionReleaseDate, let day = AbsoluteDay.parse(raw) {
                lines.append("released: \(day)")
            }
            if let notes = lookup.releaseNotes, !notes.isEmpty {
                lines.append(notes)
                lines.append("")
            }
        }

        let shots = (lookup?.screenshotUrls ?? []) + (lookup?.ipadScreenshotUrls ?? [])
        if !shots.isEmpty {
            lines.append("screenshots:")
            lines.append(contentsOf: shots)
        }
        return SnapshotText.normalize(lines.joined(separator: "\n"))
    }

    private struct VersionNote {
        var number: String
        var day: String?
        var notes: String
    }

    private struct Lookup: Decodable {
        var results: [Item]
        struct Item: Decodable {
            var trackName: String?
            var sellerName: String?
            var version: String?
            var currentVersionReleaseDate: String?
            var releaseNotes: String?
            var screenshotUrls: [String]?
            var ipadScreenshotUrls: [String]?
        }
    }

    private static func decodeLookup(_ data: Data) -> Lookup.Item? {
        guard let decoded = try? JSONDecoder().decode(Lookup.self, from: data) else { return nil }
        return decoded.results.first
    }

    private static func versionHistory(in html: String) -> [VersionNote] {
        guard let blob = jsonObject(after: "\"page\":\"versionHistory\",\"pageData\":", in: html),
              let data = blob.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var items: [[String: Any]] = []
        collectParagraphs(root, into: &items)
        var notes: [VersionNote] = []
        var seen: Set<String> = []
        for item in items {
            guard let rawNumber = item["primarySubtitle"] as? String else { continue }
            let number = versionLabel(rawNumber)
            guard !number.isEmpty, seen.insert(number).inserted else { continue }
            guard let text = item["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let day = (item["secondarySubtitle"] as? String).flatMap(AbsoluteDay.parse)
            notes.append(VersionNote(number: number, day: day, notes: trimmed))
        }
        return notes
    }

    private static func versionLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "version "
        if text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func collectParagraphs(_ value: Any, into items: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if dict["$kind"] as? String == "TitledParagraph", dict["style"] as? String == "detail" {
                items.append(dict)
            }
            for child in dict.values { collectParagraphs(child, into: &items) }
        } else if let array = value as? [Any] {
            for child in array { collectParagraphs(child, into: &items) }
        }
    }

    private static func jsonObject(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        var index = range.upperBound
        guard index < text.endIndex, text[index] == "{" else { return nil }
        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
