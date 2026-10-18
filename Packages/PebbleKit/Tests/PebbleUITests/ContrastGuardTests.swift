#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Testing
@testable import PebbleUI
import SourceScan

/// Words stay readable: every pair in `Theme.textPairs` clears its minimum
/// (4.5 to 1 for words, 3 to 1 for a field's edge) in light and dark, and no
/// screen colors words in a way the pairs don't cover. A new color for words
/// means a new pair, or this fails.
struct ContrastGuardTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func everyThemePairIsReadable(scheme: ColorScheme) {
        let pairs = Theme.textPairs(scheme)
        #expect(pairs.count > 50)
        for pair in pairs {
            #expect(pair.minimum >= 3)
            #expect(pair.contrast >= pair.minimum,
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

    /// Why a selected sidebar row and a confirmation button get their own
    /// tint: the root tint is `accentText`, light in dark mode, and the
    /// white words those controls write on it would read near 2 to 1.
    @Test func whiteOnTheWordTintIsWhyTheFillTintExists() {
        #expect(Theme.RGB.white.contrast(with: Theme.accentText.rgb(.dark)) < 3)
        for scheme in [ColorScheme.light, .dark] {
            #expect(Theme.RGB.white.contrast(with: Theme.tintFill.rgb(scheme)) >= 4.5)
            let pairs = Theme.textPairs(scheme)
            #expect(pairs.contains { $0.text == "white" && $0.background == "tintFill" })
            #expect(pairs.contains { $0.text == "onAccent" && $0.background == "accent" })
            #expect(pairs.contains { $0.text == "placeholder" })
            #expect(pairs.contains { $0.text == "field edge" })
        }
    }

    // MARK: The source scan

    /// Every source file in PebbleUI, by name.
    static func sources() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        return try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI"))
    }

    /// Every screen's source: PebbleUI and the app target, which draws the
    /// Mac snapshot and could grow screens of its own.
    static func screenSources() throws -> [(name: String, text: String)] {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let app = try SwiftSource.files(under: root.appendingPathComponent("App"))
        return try sources().map { ("PebbleUI/\($0.name)", $0.text) } + app.map { ("App/\($0.name)", $0.text) }
    }

    @Test func noScreenColorsWordsOutsideThePairs() throws {
        let files = try Self.screenSources()
        #expect(files.count > 5)
        #expect(files.contains { $0.name.hasPrefix("App/") }, "the app's own sources are scanned too")
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
            #".foregroundStyle(.quaternary)"#,
            #".foregroundStyle(.gray)"#,
            #".foregroundStyle(Color.gray)"#,
            #".foregroundStyle(Color.red)"#,
            #".foregroundColor(.red)"#,
            #".foregroundStyle(.white.opacity(0.8))"#,
            #".foregroundStyle(Color.white.opacity(0.7))"#,
            #".foregroundStyle(source == .inferred ? Color.primary : Color.secondary)"#,
            #".foregroundStyle(.white)"#,
            #".background(Color.gray, in: Capsule())"#,
            #".fill(Color.red)"#,
            "Text(\"Hi\")\n    .font(.body)\n    .foregroundStyle(Theme.accentSymbol)",
            // Wrapped onto the next line, the argument is still read.
            "Text(\"Open\")\n    .foregroundStyle(\n        Theme.accent\n    )",
            "Text(\"Open\")\n    .foregroundStyle(asks\n        ? Theme.onAccent\n        : Theme.accent)",
            ".tint(\n    Theme.accent\n)",
            ".foregroundStyle(\n    .white.opacity(\n        0.8))",
            // A confirmation button fills with the tint and writes in white.
            "ToolbarItem(placement: .confirmationAction) {\n    Button(\"Done\") { dismiss() }\n}",
        ]
        for line in wrong {
            #expect(!ContrastLint.problems(in: line).isEmpty, "missed: \(line)")
        }
        let right = [
            #"Text("Open").foregroundStyle(Theme.accentText)"#,
            #".foregroundStyle(Theme.secondaryText)"#,
            #".background(Theme.accent, in: Capsule())"#,
            #".tint(Theme.accentText)"#,
            #".tint(Theme.tintFill)"#,
            "Image(systemName: \"sparkles\")\n    .font(.largeTitle)\n    .foregroundStyle(Theme.accentSymbol)",
            "// .foregroundStyle(Theme.accent) is wrong",
            "/* .foregroundStyle(Theme.accent)\n   .tint(.orange) */",
            "/* nested /* .foregroundStyle(.gray) */ still a comment .tint(.red) */",
            #"Text(".foregroundStyle(Theme.accent) and .orange")"#,
            "Text(\"\"\"\n    .foregroundStyle(.white)\n    \"\"\")",
            #"Text("\(name) .foregroundStyle(.secondary)")"#,
            "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}",
            // Art, not words: the character's highlights.
            #".fill(.white.opacity(0.35))"#,
        ]
        for line in right {
            #expect(ContrastLint.problems(in: line).isEmpty, "flagged: \(line)")
        }
    }

    /// The scan reports the line the call starts on, even when its
    /// arguments run over several lines.
    @Test func theScanPointsAtTheCall() {
        let text = "let a = 1\n// .tint(.orange)\nText(\"x\")\n    .foregroundStyle(\n        Theme.accent)\n"
        #expect(ContrastLint.problems(in: text).map(\.line) == [4])
    }
}

/// The rules the source scan applies. The source is read with
/// `SwiftSource`, so comments and the words inside strings are never taken
/// for code, and each call is read through its balanced closing paren,
/// however many lines its arguments take.
enum ContrastLint {
    struct Problem {
        let line: Int
        let reason: String
    }

    typealias Rule = (pattern: String, reason: String)

    /// What may color words: checked on the arguments of every
    /// `foregroundStyle(` and `foregroundColor(` call.
    static let wordRules: [Rule] = [
        (#"\bTheme\.accent\b(?![A-Za-z])"#,
         "the raw accent is too faint for words; use Theme.accentText, or Theme.accentSymbol on an Image"),
        (#"\.(secondary|tertiary|quaternary)\b"#,
         "the system gray is about 3.5 to 1 on white; use Theme.secondaryText"),
        (#"(^|[^A-Za-z]|\bColor)\.gray\b"#, "the system gray is too faint for words; use Theme.secondaryText"),
        (#"(^|[^A-Za-z]|\bColor)\.red\b"#, "the system red is too faint on a card; use Theme.dangerText"),
        (#"\.white\.opacity\("#, "faded white is too faint for words; use Theme.onAccent or the primary ink"),
        (#"^(Color)?\.white$"#, "white is too faint on the accent; use Theme.onAccent"),
    ]

    /// What may fill a surface: checked on every `fill(` and `background(`
    /// call. A system color surface is not in `Theme.textPairs`.
    static let surfaceRules: [Rule] = [
        (#"(^|[^A-Za-z]|\bColor)\.(gray|red)\b"#, "a system color surface is not in Theme.textPairs; use a Theme surface"),
    ]

    /// The tints that may reach system controls. `accentText` writes their
    /// words; `tintFill` sits under white words, as on a selected sidebar row.
    static let allowedTints: Set<String> = ["Theme.accentText", "Theme.tintFill"]

    /// Rules on any code at all, once comments and strings are set aside.
    static let codeRules: [Rule] = [
        (#"\.orange\b"#, "the brand color comes from Theme, never the system orange"),
        (#"\.buttonStyle\(\s*\.bordered"#,
         "system bordered buttons color their words with the tint; use SoftButtonStyle or AccentButtonStyle"),
    ]

    static func problems(in text: String) -> [Problem] {
        let source = SwiftSource(text)
        var found: [Problem] = []

        for call in source.calls(named: ["foregroundStyle", "foregroundColor"]) {
            for rule in wordRules where call.arguments.range(of: rule.pattern, options: .regularExpression) != nil {
                found.append(Problem(line: call.line, reason: rule.reason))
            }
            // The accent symbol is for an Image just above it, never words.
            if call.arguments.contains("Theme.accentSymbol"),
               !source.code(before: call.offset, lines: 3).contains("Image(") {
                found.append(Problem(line: call.line, reason: "Theme.accentSymbol is only for an Image"))
            }
        }
        for call in source.calls(named: ["fill", "background"]) {
            for rule in surfaceRules where call.arguments.range(of: rule.pattern, options: .regularExpression) != nil {
                found.append(Problem(line: call.line, reason: rule.reason))
            }
        }
        for call in source.calls(named: ["tint"]) where !allowedTints.contains(call.arguments) {
            found.append(Problem(line: call.line,
                                 reason: "a tint colors the words of system controls; tint with Theme.accentText or Theme.tintFill only"))
        }
        // A confirmation button is drawn filled with the tint, with white
        // words on it, so it must be a DoneButton, which tints it to keep
        // those words readable.
        for call in source.calls(named: ["ToolbarItem"]) where call.arguments.contains(".confirmationAction") {
            let after = String(source.code[call.offset...].prefix(300))
            if !after.contains("DoneButton") {
                found.append(Problem(line: call.line,
                                     reason: "a confirmation button fills with the tint; use DoneButton so its words stay readable"))
            }
        }
        let code = String(source.code)
        for rule in codeRules {
            var searched = code.startIndex
            while let match = code.range(of: rule.pattern, options: .regularExpression, range: searched..<code.endIndex) {
                let offset = code.distance(from: code.startIndex, to: match.lowerBound)
                found.append(Problem(line: source.line(at: offset), reason: rule.reason))
                searched = match.upperBound
            }
        }
        return found.sorted { $0.line < $1.line }
    }
}
#endif
