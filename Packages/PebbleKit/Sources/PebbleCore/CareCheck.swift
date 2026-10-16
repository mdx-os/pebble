import Foundation

/// Words that mean someone may be in danger get a caring, honest reply
/// before any model is asked, whichever model is plugged in.
public enum CareCheck {
    public static let reply = "I'm really glad you told me. I'm a small helper and I can't keep you safe on my own. If you might act on this, please call or text 988 now, or your local emergency number, and reach someone you trust."

    private static let phrases = [
        "kill myself", "kms", "suicide", "suicidal", "end my life", "end it all",
        "hurt myself", "self harm", "want to die", "not worth living",
        "better off without me", "don't want to be here", "dont want to be here",
        "killing myself", "hurting myself", "cutting myself", "wanna die",
        "wish i was dead", "wish i were dead", "no reason to live", "can't go on",
        "cant go on", "want to end it", "self harming",
    ]

    /// A small, fixed check that favors caring too often over missing it.
    /// Matches whole words, so "diet" never reads as "die".
    public static func needsCare(_ text: String) -> Bool {
        let words = normalized(text)
        return phrases.contains { words.contains(" \(normalized($0)) ") }
    }

    private static func normalized(_ text: String) -> String {
        let folded = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        let spaced = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        let collapsed = String(spaced).split(separator: " ").joined(separator: " ")
        return " \(collapsed) "
    }
}
