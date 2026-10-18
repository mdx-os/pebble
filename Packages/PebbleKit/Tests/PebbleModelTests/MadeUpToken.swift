import Foundation

/// A made up identity token shaped like Apple's: a JSON header and a JSON
/// payload, each base64url encoded, then a signature, joined by dots. It is
/// put together at run time, so no line of the tests holds a whole one for
/// a secrets scan to take for real. No key signs it.
enum MadeUpToken {
    static func make(header: String, payload: String, signature: String) -> String {
        joined(base64url(header), base64url(payload), signature)
    }

    /// `parts` joined by dots, for shapes that aren't encoded JSON.
    static func joined(_ parts: String...) -> String {
        parts.joined(separator: ".")
    }

    static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
