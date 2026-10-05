import Foundation

enum HTMLText {
    /// Readable text from an HTML page.
    ///
    /// `<time datetime>` keeps the absolute date and drops the visible label,
    /// which is often a relative date such as "4d ago".
    static func extract(_ html: String) -> String {
        var text = html
        text = replace(text, pattern: #"<script\b[^>]*>[\s\S]*?</script>"#, with: " ")
        text = replace(text, pattern: #"<style\b[^>]*>[\s\S]*?</style>"#, with: " ")
        text = replace(text, pattern: #"<noscript\b[^>]*>[\s\S]*?</noscript>"#, with: " ")
        text = replace(text, pattern: #"<svg\b[^>]*>[\s\S]*?</svg>"#, with: " ")
        text = replace(text, pattern: #"<template\b[^>]*>[\s\S]*?</template>"#, with: " ")
        text = replaceTimes(text)
        text = replace(
            text,
            pattern: #"</?(?:p|div|li|h[1-6]|tr|br|section|article|header|footer|table|ul|ol|blockquote)\b[^>]*>"#,
            with: "\n"
        )
        text = replace(text, pattern: #"<[^>]+>"#, with: " ")
        return decodeEntities(text)
    }

    private static func replaceTimes(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<time\b[^>]*\bdatetime=["']([^"']+)["'][^>]*>[\s\S]*?</time>"#,
            options: [.caseInsensitive]
        ) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let whole = Range(match.range, in: result),
                  let valueRange = Range(match.range(at: 1), in: result)
            else { continue }
            let raw = String(result[valueRange])
            let day = AbsoluteDay.parse(raw) ?? raw
            result.replaceSubrange(whole, with: " \(day) ")
        }
        return result
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&",
               let semi = text[index...].firstIndex(of: ";"),
               text.distance(from: index, to: semi) <= 12
            {
                let token = String(text[text.index(after: index)..<semi])
                if let decoded = entity(token) {
                    result.append(decoded)
                    index = text.index(after: semi)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ token: String) -> String? {
        let named = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "nbsp": " ",
            "middot": "·",
            "hellip": "...",
            "mdash": "-",
            "ndash": "-",
            "rsquo": "'",
            "lsquo": "'",
            "rdquo": "\"",
            "ldquo": "\"",
        ]
        if let value = named[token] { return value }
        if token.hasPrefix("#x"), let scalar = UInt32(token.dropFirst(2), radix: 16), let uni = UnicodeScalar(scalar) {
            return String(uni)
        }
        if token.hasPrefix("#"), let scalar = UInt32(token.dropFirst(), radix: 10), let uni = UnicodeScalar(scalar) {
            return String(uni)
        }
        return nil
    }
}

enum NewsArticleText {
    /// Headline, publish day, and body from schema.org NewsArticle JSON-LD.
    /// Pages that only offer that block still produce a stable snapshot.
    static func extract(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges > 1 {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let json = String(html[range])
            if let text = article(from: json) { return text }
        }
        return nil
    }

    private static func article(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        guard let found = findArticle(root) else { return nil }
        let body = (found["articleBody"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return nil }
        let headline = (found["headline"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lines: [String] = []
        if !headline.isEmpty { lines.append("headline: \(headline)") }
        if let published = found["datePublished"] as? String, let day = AbsoluteDay.parse(published) {
            lines.append("published: \(day)")
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private static func findArticle(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let body = dict["articleBody"] as? String, !body.isEmpty { return dict }
            for child in dict.values {
                if let found = findArticle(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findArticle(child) { return found }
            }
        }
        return nil
    }
}

enum AbsoluteDay {
    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return prefix
            }
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d{4})\b"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let monthRange = Range(match.range(at: 1), in: trimmed),
              let dayRange = Range(match.range(at: 2), in: trimmed),
              let yearRange = Range(match.range(at: 3), in: trimmed),
              let month = months[trimmed[monthRange].lowercased()],
              let day = Int(trimmed[dayRange]),
              let year = Int(trimmed[yearRange]),
              (1...31).contains(day)
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let months = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
}
