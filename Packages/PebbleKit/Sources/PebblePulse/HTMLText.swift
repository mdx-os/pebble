import Foundation

/// Turns fetched HTML into the stable text git should diff.
enum HTMLText {
    static func strip(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        let cut: [(String, NSRegularExpression.Options)] = [
            ("(?is)<script\\b[^>]*>.*?</script>", [.caseInsensitive, .dotMatchesLineSeparators]),
            ("(?is)<style\\b[^>]*>.*?</style>", [.caseInsensitive, .dotMatchesLineSeparators]),
            ("(?is)<svg\\b[^>]*>.*?</svg>", [.caseInsensitive, .dotMatchesLineSeparators]),
            ("(?is)<noscript\\b[^>]*>.*?</noscript>", [.caseInsensitive, .dotMatchesLineSeparators]),
            ("(?s)<!--.*?-->", [.dotMatchesLineSeparators]),
        ]
        for (pattern, options) in cut {
            text = replace(pattern, in: text, with: " ", options: options)
        }
        text = replace("(?i)<br\\s*/?>", in: text, with: "\n", options: [.caseInsensitive])
        text = replace("(?i)</(p|div|li|h1|h2|h3|h4|tr|section|article|ul|ol)>", in: text, with: "\n", options: [.caseInsensitive])
        text = replace("<[^>]+>", in: text, with: " ", options: [])
        text = decode(text)
        let lines = text.components(separatedBy: "\n").map { line in
            line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func inline(_ html: String) -> String {
        strip(html).replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func markdown(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var kept: [String] = []
        var blankRun = 0
        for line in lines {
            if line.range(of: #"^<a id="[^"]*"\s*/>$"#, options: .regularExpression) != nil {
                continue
            }
            if line.hasPrefix("<!--"), line.hasSuffix("-->") {
                continue
            }
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 {
                    kept.append("")
                }
            } else {
                blankRun = 0
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bounded(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n[truncated]"
    }

    private static func replace(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options
    ) -> String {
        let expression = TextScan.regex(pattern, options: options)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func decode(_ text: String) -> String {
        var result = text
        let named = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        result = replaceNumeric(result, pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);")
        return result
    }

    private static func replaceNumeric(_ text: String, pattern: String) -> String {
        let expression = TextScan.regex(pattern)
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            let full = match.range(at: 0)
            let token = match.range(at: 1)
            output += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let raw = ns.substring(with: token)
            output += character(from: raw)
            cursor = full.location + full.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func character(from raw: String) -> String {
        let value: UInt32?
        if raw.lowercased().hasPrefix("x") {
            value = UInt32(raw.dropFirst(), radix: 16)
        } else {
            value = UInt32(raw)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }
}
