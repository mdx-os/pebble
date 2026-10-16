import Foundation

/// Words that mean someone may be in danger get a caring, honest reply
/// before any model is asked, whichever model is plugged in.
public enum CareCheck {
    public static let reply = "I'm really glad you told me. I'm a small helper and I can't keep you safe on my own. If you might act on this, please call or text 988 now, or your local emergency number, and reach someone you trust."

    /// The next reply after a care reply. Stays with the person, never
    /// switches to the starter menu.
    public static let followUp = "I'm still here with you. Please reach out now: call or text 988, or your local emergency number, or someone you trust. You can keep talking to me too."

    private static let phrases = [
        "kill myself", "kms", "suicide", "suicidal", "end my life", "end it all",
        "hurt myself", "self harm", "want to die", "not worth living",
        "better off without me", "don't want to be here", "dont want to be here",
        "killing myself", "hurting myself", "cutting myself", "wanna die",
        "wish i was dead", "wish i were dead", "no reason to live", "can't go on",
        "cant go on", "want to end it", "self harming",
        "don't want to live", "dont want to live", "take my life", "take my own life",
        "end my own life", "hang myself", "overdose", "kill me", "wanting to die",
    ]

    /// A small, fixed check that favors caring too often over missing it.
    /// Matches whole words, so "diet" never reads as "die".
    public static func needsCare(_ text: String) -> Bool {
        let words = normalized(text)
        return phrases.contains { words.contains(normalized($0)) }
    }

    /// The care reply to give, if any. Once care starts it stays until the
    /// person picks a starter on purpose, so a short "yes" or "I have the
    /// pills" never lands on a cheerful menu.
    public static func reply(after transcript: [ChatTurn]) -> String? {
        guard let last = transcript.last, last.speaker == .person else { return nil }
        if needsCare(last.text) { return reply }
        let lastAgent = transcript.last(where: { $0.speaker == .agent })?.text
        guard let lastAgent, isCare(lastAgent) else { return nil }
        let trimmed = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let picksStarter = FirstConversation.jobs.contains {
            $0.prompt.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
        return picksStarter ? nil : followUp
    }

    /// The transcript with every care exchange taken out: care replies and
    /// whatever the person said that led to one. A model never sees them.
    public static func redacted(_ transcript: [ChatTurn]) -> [ChatTurn] {
        var kept: [ChatTurn] = []
        for (index, turn) in transcript.enumerated() {
            if turn.speaker == .agent, isCare(turn.text) { continue }
            if turn.speaker == .person {
                let next = transcript[(index + 1)...].first { $0.speaker == .agent }
                if needsCare(turn.text) || (next.map { isCare($0.text) } ?? false) { continue }
            }
            kept.append(turn)
        }
        return kept
    }

    private static func isCare(_ text: String) -> Bool { text == reply || text == followUp }

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
