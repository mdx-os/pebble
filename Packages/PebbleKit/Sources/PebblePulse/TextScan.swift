import Foundation

enum TextScan {
    static func groups(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        let expression = regex(pattern, options: options)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return expression.matches(in: text, options: [], range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let piece = match.range(at: index)
                if piece.location == NSNotFound { return "" }
                return ns.substring(with: piece)
            }
        }
    }

    static func first(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String]? {
        groups(pattern, in: text, options: options).first
    }

    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Bad regular expression: \(pattern)")
        }
    }
}
