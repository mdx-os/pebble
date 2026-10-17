#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Testing
@testable import PebbleUI

/// Words stay readable: every pair in `Theme.textPairs` clears 4.5 to 1 in
/// light and dark, and no screen colors words in a way the pairs don't
/// cover. A new color for words means a new pair, or this fails.
struct ContrastGuardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func everyThemePairIsReadable(scheme: ColorScheme) {
        let pairs = Theme.textPairs(scheme)
        #expect(pairs.count > 50)
        for pair in pairs {
            #expect(pair.contrast >= 4.5,
                    "\(pair.text) on \(pair.background) in \(scheme) is \(String(format: "%.2f", pair.contrast)) to 1")
        }
    }

    /// `accentText` is the one way to write in the accent's warmth, so it
    /// must read on a card and on the accent wash in both schemes.
    @Test(arguments: [ColorScheme.light, .dark])
    func accentWordsReadOnTheCardAndTheWash(scheme: ColorScheme) {
        let words = Theme.accentText.rgb(scheme)
        for base in [Theme.backdropEnds(scheme).top, Theme.backdropEnds(scheme).bottom] {
            let card = Theme.RGB.white.over(base, opacity: Theme.cardOpacity(scheme))
            #expect(words.contrast(with: card) >= 4.5)
            #expect(words.contrast(with: Theme.accentRGB.over(card, opacity: Theme.accentWash)) >= 4.5)
        }
    }

    /// Why the raw accent and the system gray are kept off words.
    @Test func theRawAccentAndTheSystemGrayAreTooFaintForWords() {
        let card = Theme.RGB.white.over(Theme.backdropEnds(.light).top, opacity: Theme.cardOpacity(.light))
        #expect(Theme.accentRGB.contrast(with: card) < 4.5)
        // The system secondary label: #3C3C43 at 60 percent.
        let systemGray = Theme.RGB(60 / 255, 60 / 255, 67 / 255).over(.white, opacity: 0.6)
        #expect(systemGray.contrast(with: .white) < 4.5)
    }

    // MARK: The source scan

    /// Every source file in PebbleUI, by name.
    static func sources() throws -> [(name: String, text: String)] {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleUI")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        return try names.sorted().map { ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test func noScreenColorsWordsOutsideThePairs() throws {
        let files = try Self.sources()
        #expect(files.count > 5)
        for file in files {
            for problem in ContrastLint.problems(in: file.text) {
                Issue.record("\(file.name):\(problem.line): \(problem.reason)")
            }
        }
    }

    /// The scan itself catches what it is for, and lets the right things by.
    @Test func theScanCatchesEachMistake() {
        let wrong = [
            #"Text("Open").foregroundStyle(Theme.accent)"#,
            #".foregroundStyle(asks ? Theme.onAccent : Theme.accent)"#,
            #".foregroundColor(Theme.accent)"#,
            #".tint(Theme.accent)"#,
            #".tint(.orange)"#,
            #"Color.orange.opacity(0.18)"#,
            #".buttonStyle(.bordered)"#,
            #".buttonStyle(.borderedProminent)"#,
            #".foregroundStyle(.secondary)"#,
            #".foregroundStyle(.tertiary)"#,
            #".foregroundStyle(source == .inferred ? Color.primary : Color.secondary)"#,
            #".foregroundStyle(.white)"#,
            "Text(\"Hi\")\n    .font(.body)\n    .foregroundStyle(Theme.accentSymbol)",
        ]
        for line in wrong {
            #expect(!ContrastLint.problems(in: line).isEmpty, "missed: \(line)")
        }
        let right = [
            #"Text("Open").foregroundStyle(Theme.accentText)"#,
            #".foregroundStyle(Theme.secondaryText)"#,
            #".background(Theme.accent, in: Capsule())"#,
            #".tint(Theme.accentText)"#,
            "Image(systemName: \"sparkles\")\n    .font(.largeTitle)\n    .foregroundStyle(Theme.accentSymbol)",
            "// .foregroundStyle(Theme.accent) is wrong",
        ]
        for line in right {
            #expect(ContrastLint.problems(in: line).isEmpty, "flagged: \(line)")
        }
    }
}

/// The rules the source scan applies, one line at a time.
enum ContrastLint {
    struct Problem {
        let line: Int
        let reason: String
    }

    static let rules: [(pattern: String, reason: String)] = [
        (#"\b(foregroundStyle|foregroundColor)\(.*\bTheme\.accent\b(?![A-Za-z])"#,
         "the raw accent is too faint for words; use Theme.accentText, or Theme.accentSymbol on an Image"),
        (#"\.tint\((?!Theme\.accentText\))"#,
         "a tint colors the words of system controls; tint with Theme.accentText only"),
        (#"\.orange\b"#, "the brand color comes from Theme, never the system orange"),
        (#"\.buttonStyle\(\.bordered"#,
         "system bordered buttons color their words with the tint; use SoftButtonStyle or AccentButtonStyle"),
        (#"\b(foregroundStyle|foregroundColor)\(.*(\.secondary|\.tertiary)\b"#,
         "the system gray is about 3.5 to 1 on white; use Theme.secondaryText"),
        (#"\b(foregroundStyle|foregroundColor)\(\s*(Color)?\.white\s*\)"#,
         "white is too faint on the accent; use Theme.onAccent"),
    ]

    static func problems(in text: String) -> [Problem] {
        let lines = text.components(separatedBy: "\n")
        var found: [Problem] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            for rule in rules where line.range(of: rule.pattern, options: .regularExpression) != nil {
                found.append(Problem(line: index + 1, reason: rule.reason))
            }
            // The accent symbol is for an Image just above it, never words.
            if line.contains("Theme.accentSymbol") {
                let above = lines[max(0, index - 3)...index].joined(separator: "\n")
                if !above.contains("Image(") {
                    found.append(Problem(line: index + 1, reason: "Theme.accentSymbol is only for an Image"))
                }
            }
        }
        return found
    }
}
#endif
