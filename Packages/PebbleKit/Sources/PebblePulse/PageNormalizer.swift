import Foundation
import PebbleCore

/// Turns a fetched page into the text saved under `pulse/snapshots/`.
///
/// The text leaves out clocks, ratings, and "3 days ago" labels, so a second
/// fetch of an unchanged page is byte for byte the same.
public enum PageNormalizer {
    public static let maxReleases = 15
    public static let maxVersions = 30

    public static func normalize(kind: PulseSource.Kind, body: String, contentType: String?) throws -> String {
        switch kind {
        case .appStore:
            return try appStore(body)
        case .releaseFeed:
            return try releaseFeed(body)
        case .firstParty:
            return try firstParty(body, contentType: contentType)
        case .xSearch:
            throw PulseError(message: "X search is not a page.")
        }
    }

    static func appStore(_ html: String) throws -> String {
        let software = softwareApplication(in: html)
        guard let name = software?.name, !name.isEmpty else {
            throw PulseError(message: "App Store page has no app name.")
        }
        let versions = versionHistory(in: html)
        guard !versions.isEmpty else {
            throw PulseError(message: "App Store page has no version history.")
        }
        let shots = screenshots(in: html)
        guard !shots.isEmpty else {
            throw PulseError(message: "App Store page has no screenshots.")
        }

        var lines = ["name: \(name)", "screenshots:"]
        lines.append(contentsOf: shots.map { "- \($0)" })
        lines.append("")
        for version in versions.prefix(maxVersions) {
            lines.append("version: \(version.number)")
            lines.append("released: \(version.released)")
            lines.append("notes: \(version.notes)")
            lines.append("")
        }
        if let description = software?.description, !description.isEmpty {
            lines.append("description:")
            lines.append(HTMLText.bounded(description, limit: 6_000))
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func releaseFeed(_ html: String) throws -> String {
        let pattern = #"<h2 class="text-h2[^"]*">([\s\S]*?)</h2>"#
        let expression = TextScan.regex(pattern, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            throw PulseError(message: "Release feed has no releases.")
        }

        var blocks: [String] = []
        for (index, match) in matches.enumerated() {
            if blocks.count == maxReleases { break }
            let title = HTMLText.inline(ns.substring(with: match.range(at: 1)))
            guard !title.isEmpty else { continue }
            let start = match.range.location
            let lookback = max(0, start - 2_500)
            let before = ns.substring(with: NSRange(location: lookback, length: start - lookback))
            let next = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let forwardLength = min(20_000, next - (match.range.location + match.range.length))
            let afterStart = match.range.location + match.range.length
            let after = forwardLength > 0
                ? ns.substring(with: NSRange(location: afterStart, length: forwardLength))
                : ""

            var lines = ["## \(title)"]
            if let product = productName(in: before) {
                lines.append("product: \(product)")
            }
            if let summary = summary(in: after) {
                lines.append("summary: \(summary)")
                if let body = bodyText(in: after, afterSummary: summary), !body.isEmpty {
                    lines.append(body)
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else {
            throw PulseError(message: "Release feed has no readable releases.")
        }
        return (["count: \(blocks.count)", ""] + blocks).joined(separator: "\n\n")
    }

    static func firstParty(_ body: String, contentType: String?) throws -> String {
        let text: String
        if isMarkdown(body, contentType: contentType) {
            text = HTMLText.markdown(body)
        } else {
            let region = slice(body, from: "<article", to: "</article>")
                ?? slice(body, from: "<main", to: "</main>")
                ?? body
            text = HTMLText.strip(region)
        }
        let bounded = HTMLText.bounded(text, limit: 100_000)
        if bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PulseError(message: "First-party page had no text.")
        }
        return bounded
    }

    private struct StoreVersion {
        var number: String
        var released: String
        var notes: String
    }

    private static func versionHistory(in html: String) -> [StoreVersion] {
        let pattern = #"(?:Version\s+)?([0-9][0-9A-Za-z.]*)\s*</span>\s*<time\s+datetime="(\d{4}-\d{2}-\d{2})""#
        let expression = TextScan.regex(pattern, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen: Set<String> = []
        var versions: [StoreVersion] = []
        for match in matches {
            let number = ns.substring(with: match.range(at: 1))
            let released = ns.substring(with: match.range(at: 2))
            let key = "\(number)|\(released)"
            let notes = notesBefore(match.range.location, in: html)
            if notes.contains("<") { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            versions.append(StoreVersion(number: number, released: released, notes: notes))
        }
        return versions
    }

    private static func notesBefore(_ location: Int, in html: String) -> String {
        let ns = html as NSString
        let start = max(0, location - 700)
        let window = ns.substring(with: NSRange(location: start, length: location - start))
        let endMarker = "<!-- HTML_TAG_END -->"
        let startMarker = "<!-- HTML_TAG_START -->"
        guard let end = window.range(of: endMarker, options: .backwards) else { return "" }
        let beforeEnd = window[..<end.lowerBound]
        guard let begin = beforeEnd.range(of: startMarker, options: .backwards) else { return "" }
        let raw = beforeEnd[begin.upperBound...]
        return HTMLText.inline(String(raw))
    }

    private static func softwareApplication(in html: String) -> (name: String, description: String)? {
        let pattern = #"(?is)<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>"#
        for group in TextScan.groups(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            guard group.count > 1 else { continue }
            let data = Data(group[1].utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (json["@type"] as? String) == "SoftwareApplication" else { continue }
            let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = (json["description"] as? String)?
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name, description)
        }
        return nil
    }

    private static func screenshots(in html: String) -> [String] {
        let pattern = #"PurpleSource\d+/v4/(?:[0-9a-f]{2}/){3}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_.-]+\.(?:jpg|png)"#
        var unique: [String] = []
        for group in TextScan.groups(pattern, in: html) {
            let path = group[0]
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if name.hasPrefix("Placeholder") || name.contains("AppIcon") || name.contains("app-icon") {
                continue
            }
            if !unique.contains(path) {
                unique.append(path)
            }
        }
        let deviceShots = unique.filter { $0.range(of: #"Screen\d+\.jpg"#, options: .regularExpression) != nil }
        let numbered = unique.filter { path in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return name.range(of: #"^\d{2}_"#, options: .regularExpression) != nil
        }
        let chosen = !deviceShots.isEmpty ? deviceShots : (!numbered.isEmpty ? numbered : unique)
        return chosen.sorted { left, right in
            let a = screenNumber(left)
            let b = screenNumber(right)
            if a != b { return a < b }
            let leftName = left.split(separator: "/").last.map(String.init) ?? left
            let rightName = right.split(separator: "/").last.map(String.init) ?? right
            if leftName != rightName { return leftName < rightName }
            return left < right
        }
    }

    private static func screenNumber(_ path: String) -> Int {
        guard let group = TextScan.first(#"Screen(\d+)\.jpg"#, in: path), group.count > 1 else { return 0 }
        return Int(group[1]) ?? 0
    }

    private static func productName(in html: String) -> String? {
        let pattern = #"class="text-sm text-ink/70"[^>]*>\s*<a[^>]*>\s*([^<]+?)\s*</a>"#
        let found = TextScan.groups(pattern, in: html, options: [.dotMatchesLineSeparators])
        guard let group = found.last, group.count > 1 else {
            return nil
        }
        let name = HTMLText.inline(group[1])
        return name.isEmpty ? nil : name
    }

    private static func summary(in html: String) -> String? {
        let pattern = #"<p class="mt-3 mb-3[^"]*"[^>]*>([\s\S]*?)</p>"#
        guard let group = TextScan.first(pattern, in: html, options: [.dotMatchesLineSeparators]), group.count > 1 else {
            return nil
        }
        let text = HTMLText.inline(group[1])
        return text.isEmpty ? nil : text
    }

    private static func bodyText(in html: String, afterSummary summary: String) -> String? {
        guard let range = html.range(of: "</p>") else { return nil }
        let rest = String(html[range.upperBound...])
        let stripped = HTMLText.strip(rest)
            .components(separatedBy: "\n")
            .filter { line in !boilerplate.contains(where: { line.contains($0) }) }
            .joined(separator: "\n")
        let bounded = HTMLText.bounded(stripped, limit: 8_000)
        if bounded == summary { return nil }
        return bounded
    }

    private static let boilerplate = [
        "Date parsed from source",
        "First seen by Releasebot",
        "Original source",
    ]

    private static func isMarkdown(_ body: String, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("markdown") {
            return true
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<head") {
            return false
        }
        return trimmed.hasPrefix("#")
    }

    private static func slice(_ html: String, from open: String, to close: String) -> String? {
        guard let start = html.range(of: open, options: .caseInsensitive) else { return nil }
        guard let end = html.range(of: close, options: .caseInsensitive, range: start.lowerBound..<html.endIndex) else {
            return nil
        }
        return String(html[start.lowerBound..<end.upperBound])
    }
}
