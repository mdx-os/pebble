import Foundation

/// The words that promise the device or privacy, and how a line is read
/// for them. docs/VOICE.md: say it only when `PrivacyPlace` says so.
public enum PromisePhrases {
    /// Every phrase that promises where words go or that they stay private.
    /// Matched without regard to case, on word boundaries, so "only on"
    /// never matches "only one".
    public static let phrases = [
        "this device", "on this device", "your device", "on device", "on-device",
        "on your phone", "on this Mac", "on this iPhone", "on this iPad", "your Mac", "your iPhone", "your iPad",
        "stays here", "stay here", "stays on", "stay on", "kept only", "never leaves", "never leave",
        "doesn't leave", "won't leave", "nothing leaves", "only on", "private", "privately", "privacy",
        "nothing was sent", "nothing is sent anywhere", "not sent", "isn't sent", "never sent", "locally", "offline",
        "only you", "no one else", "encrypted", "secure",
        "cloud", "server", "servers", "upload", "uploads", "uploaded",
    ]

    /// Characters a person never sees. Each is read both ways: as nothing,
    /// so `pri\u{200B}vate` is "private", and as a gap, since a line may
    /// break at a zero-width space and show "never" and "leaves" apart.
    public static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

    /// Marks that read as an apostrophe or a hyphen.
    static let apostrophes: Set<Unicode.Scalar> = ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{2032}"]
    static let hyphens: Set<Unicode.Scalar> = ["\u{2010}", "\u{2011}"]

    /// `line` as a person reads it, with invisible characters `asGaps` or
    /// taken out. A `\u{...}`, `\n`, `\t` or `\r` written out in the text
    /// is read as what it stands for, curly apostrophes and hyphens as
    /// plain ones, and every run of white space as one space.
    public static func folded(_ line: String, asGaps: Bool) -> String {
        var scalars: [Unicode.Scalar] = []
        let input = Array(line.unicodeScalars)
        var index = 0
        while index < input.count {
            let scalar = input[index]
            if scalar == "\\", index + 1 < input.count {
                let next = input[index + 1]
                if ["n", "t", "r", "\n"].contains(next) {
                    scalars.append(" ")
                    index += 2
                    continue
                }
                if next == "u", index + 2 < input.count, input[index + 2] == "{",
                   let close = input[(index + 3)...].firstIndex(of: "}"), close - index - 3 <= 8,
                   let value = UInt32(String(String.UnicodeScalarView(input[(index + 3)..<close])), radix: 16),
                   let decoded = Unicode.Scalar(value) {
                    scalars.append(decoded)
                    index = close + 1
                    continue
                }
            }
            scalars.append(scalar)
            index += 1
        }
        var out = ""
        var gap = false
        for scalar in scalars {
            var scalar = scalar
            if invisible.contains(scalar) {
                if asGaps { gap = true }
                continue
            }
            if apostrophes.contains(scalar) { scalar = "'" }
            if hyphens.contains(scalar) { scalar = "-" }
            if Character(scalar).isWhitespace {
                gap = true
                continue
            }
            if gap, !out.isEmpty { out.append(" ") }
            gap = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The phrases in `line`, in the order of `phrases`.
    public static func found(in line: String) -> [String] {
        let readings = Set([folded(line, asGaps: true), folded(line, asGaps: false)])
        return zip(phrases, patterns).filter { _, pattern in
            readings.contains { reading in
                pattern.firstMatch(in: reading, range: NSRange(reading.startIndex..., in: reading)) != nil
            }
        }.map(\.0)
    }

    static let patterns: [NSRegularExpression] = phrases.map { phrase in
        try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b",
                                 options: .caseInsensitive)
    }
}
