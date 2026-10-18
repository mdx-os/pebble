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
            // The next item's DoneButton doesn't count for this one.
            "ToolbarItem(placement: .confirmationAction) {\n    Button(\"Done\") { dismiss() }\n}\n"
                + "ToolbarItem(placement: .cancellationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)",
            // Done without hiding the toolbar's glass gets a ring around it,
            // whatever the placement, or with none.
            "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}",
            "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.visible)",
            "ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}",
            "ToolbarItem(placement: .topBarTrailing) {\n    DoneButton { dismiss() }\n}",
            "ToolbarItem(placement: .cancellationAction) {\n    DoneButton { dismiss() }\n}",
            "ToolbarItem {\n    DoneButton { dismiss() }\n}",
            // The hiding belongs to the item, not to something after it.
            "ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}\nText(\"a\")\n.sharedBackgroundVisibility(.hidden)",
            // Done outside a ToolbarItem escapes both rules above.
            "ToolbarItemGroup(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)",
            "ToolbarItemGroup {\n    DoneButton { dismiss() }\n}",
            ".toolbar {\n    DoneButton { dismiss() }\n}",
            "VStack {\n    DoneButton(title: \"Done\") { dismiss() }\n}",
            "ToolbarItem {\n    Text(\"a\")\n}\n.sharedBackgroundVisibility(.hidden)\nDoneButton { dismiss() }",
            // The fill tint, anywhere but a fill.
            #"Text("Open").tint(Theme.tintFill)"#,
            #"Text("Open").foregroundStyle(Theme.tintFill)"#,
            "List { Text(\"a\") }\nText(\"b\").tint(Theme.tintFill)",
            "struct DoneButton: View { var body: some View { Button(\"Done\") {} } }\n"
                + "struct Other: View { var body: some View { Text(\"x\").tint(Theme.tintFill) } }",
            // The call's paren on the next line is still the call.
            "Text(\"Open\")\n    .foregroundStyle\n    (Theme.accent)",
            ".tint\n(.orange)",
            // White in a branch of the argument.
            #".foregroundStyle(flag ? .white : Theme.onAccent)"#,
            #".foregroundStyle(flag ? Theme.onAccent : Color.white)"#,
            // The fill tint on any list but the sidebar's.
            "List(items) { item in\n    Button(item.title) {}\n}\n.tint(Theme.tintFill)",
            "struct Other: View {\n    var body: some View {\n        List(selection: $picked) {\n            Text(\"a\")\n        }\n"
                + "        .tint(Theme.tintFill)\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        List {\n            Text(\"a\")\n        }\n"
                + "        .tint(Theme.tintFill)\n    }\n}",
            // White for words on the fill, anywhere the fill isn't under it.
            #"Text("Open").foregroundStyle(Theme.onTintFill)"#,
            "struct Card: View {\n    var body: some View {\n        Text(\"a\").foregroundStyle(Theme.onTintFill)\n"
                + "            .background(Theme.accent)\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        Text(\"a\").foregroundStyle(Theme.onTintFill)\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n"
                + "        Text(\"a\").foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.onTintFill))\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        Text(\"a\").tint(flag ? Theme.onTintFill : .primary)\n    }\n}",
            // A ternary styles every other row too, over their tinted icons.
            "struct HomeSplit: View {\n    var body: some View {\n        HStack { Text(\"a\"); Text(\"3\") }\n"
                + "            .foregroundStyle(chosen ? AnyShapeStyle(Theme.onTintFill) : AnyShapeStyle(.primary))\n    }\n}",
            "struct HomeSplit: View {\n    func ink() -> some View {\n        if !chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
                + "        }\n    }\n}",
            "struct HomeSplit: View {\n    func ink() -> some View {\n        if chosen {\n            row()\n        } else {\n"
                + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }\n}",
            "struct HomeSplit: View {\n    func ink() -> some View {\n        if chosen {\n            row().overlay {\n"
                + "                Text(\"a\").foregroundStyle(Theme.onTintFill)\n            }\n        }\n    }\n}",
            "struct FillButtonStyle: ButtonStyle {}\nstruct Other: View {\n"
                + "    var body: some View { Text(\"a\").foregroundStyle(Theme.onTintFill) }\n}",
            "let ink = Theme.onTintFill",
            // A `chosen` that isn't the row's own.
            "struct HomeSplit: View {\n    var body: some View {\n"
                + "        let chosen = !Self.isChosen(place, section: section, regular: true)\n"
                + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        let chosen = true\n"
                + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        }\n    }\n}",
            "struct HomeSplit: View {\n    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
                + "        let chosen = !chosen\n        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n"
                + "        }\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        if chosen {\n"
                + "            row().foregroundStyle(Theme.onTintFill)\n        }\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        Self.ink(chosen: !chosen) { Text(\"a\") }\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        let chosen = !Self.isChosen(place, section: section, regular: true)\n"
                + "        Self.ink(chosen: chosen) { Text(\"a\") }\n    }\n}",
            "struct HomeSplit: View {\n    var body: some View {\n        Self.ink(chosen: flag) { Text(\"a\") }\n    }\n}",
        ]
        for line in wrong {
            #expect(!ContrastLint.problems(in: line).isEmpty, "missed: \(line)")
        }
        let right = [
            #"Text("Open").foregroundStyle(Theme.accentText)"#,
            #".foregroundStyle(Theme.secondaryText)"#,
            #".background(Theme.accent, in: Capsule())"#,
            #".tint(Theme.accentText)"#,
            "struct HomeSplit: View {\n    var body: some View {\n        List(selection: $section) {\n            Text(\"a\")\n"
                + "        }\n        // The sidebar.\n        .tint(Theme.tintFill)\n    }\n}",
            "struct DoneButton: View {\n    var body: some View {\n        Button(\"Done\") {}\n            .tint(Theme.tintFill)\n    }\n}",
            "Image(systemName: \"sparkles\")\n    .font(.largeTitle)\n    .foregroundStyle(Theme.accentSymbol)",
            "// .foregroundStyle(Theme.accent) is wrong",
            "/* .foregroundStyle(Theme.accent)\n   .tint(.orange) */",
            "/* nested /* .foregroundStyle(.gray) */ still a comment .tint(.red) */",
            #"Text(".foregroundStyle(Theme.accent) and .orange")"#,
            "Text(\"\"\"\n    .foregroundStyle(.white)\n    \"\"\")",
            #"Text("\(name) .foregroundStyle(.secondary)")"#,
            "ToolbarItem(placement: .confirmationAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)",
            "ToolbarItem(placement: .primaryAction) {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)",
            "ToolbarItem {\n    DoneButton { dismiss() }\n}\n.sharedBackgroundVisibility(.hidden)",
            ".toolbar {\n    ToolbarItem(placement: .confirmationAction) {\n        DoneButton(title: \"Done\") { dismiss() }\n"
                + "    }\n    .sharedBackgroundVisibility(.hidden)\n}",
            "struct DoneButton: View {\n    var body: some View { Button(\"Done\") {} }\n}",
            // An item with no Done keeps the toolbar's glass.
            "ToolbarItem(placement: .cancellationAction) {\n    Button(\"Cancel\") { dismiss() }\n}",
            // Art, not words: the character's highlights.
            #".fill(.white.opacity(0.35))"#,
            // White on the fill: the chosen sidebar row, its badge, and Done.
            "struct HomeSplit: View {\n    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
                + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
                + "        }\n    }\n}",
            "struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                + "        configuration.label.foregroundStyle(Theme.onTintFill)\n    }\n}",
            "static let onTintFill = RGB.white.color",
            "// Theme.onTintFill only on the fill",
            // The row's own chosen, from Self.isChosen.
            "struct HomeSplit: View {\n    var body: some View {\n"
                + "        let chosen = Self.isChosen(place, section: section, regular: isRegular) && Self.drawsOwnFill\n"
                + "        Self.ink(chosen: chosen) { Text(\"a\") }\n"
                + "        Self.ink(chosen: Self.isChosen(place, section: section, regular: true)) { Text(\"b\") }\n    }\n"
                + "    static func ink(chosen: Bool, row: () -> some View) -> some View {\n"
                + "        if chosen {\n            row().foregroundStyle(Theme.onTintFill)\n        } else {\n            row()\n"
                + "        }\n    }\n}",
        ]
        for line in right {
            #expect(ContrastLint.problems(in: line).isEmpty, "flagged: \(line)")
        }
    }

    /// The scan wants `.sharedBackgroundVisibility(.hidden)` right after the
    /// item, with no `if #available` around it. That API is iOS 26 and
    /// macOS 26, so it holds only while both minimums are 26 or later.
    @Test func theDoneRingNeedsNoAvailabilityCheck() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let package = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Package.swift"), encoding: .utf8)
        #expect(package.contains("platforms: [.iOS(.v26), .macOS(.v26)]"))
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.range(of: #"deploymentTarget:\s*\n\s*iOS: "26\.0"\s*\n\s*macOS: "26\.0""#,
                              options: .regularExpression) != nil)
    }

    /// The scan reports the line the call starts on, even when its
    /// arguments run over several lines.
    @Test func theScanPointsAtTheCall() {
        let text = "let a = 1\n// .tint(.orange)\nText(\"x\")\n    .foregroundStyle(\n        Theme.accent)\n"
        #expect(ContrastLint.problems(in: text).map(\.line) == [4])
    }

    /// Lines still count after a `\` joins two lines of a multi-line
    /// string, and a paren in a string inside an interpolation never
    /// throws the count off.
    @Test func theScanCountsLinesThroughEveryKindOfString() {
        let joined = "let a = \"\"\"\n    one \\\n    two\n    \"\"\"\nText(\"x\")\n"
        #expect(SwiftSource(joined).literals.map(\.line) == [1, 5])
        let paren = "let a = \"\\(f(\"(\"))\"\nText(\"x\")\n    .foregroundStyle(Theme.accent)\n"
        #expect(SwiftSource(paren).literals.map(\.line) == [1, 2])
        #expect(ContrastLint.problems(in: paren).map(\.line) == [3])
    }

    /// Names come out right when the folder is reached through a symlink,
    /// as `/var` is for `/private/var`.
    @Test func filesAreNamedFromTheFolderThroughSymlinks() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("scan-link-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try "let a = 1".write(to: real.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "let b = 2".write(to: real.appendingPathComponent("Sub/B.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(try SwiftSource.files(under: real).map(\.name) == ["A.swift", "Sub/B.swift"])
        #expect(try SwiftSource.files(under: link).map(\.name) == ["A.swift", "Sub/B.swift"])
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
        // Anywhere in the argument, so a branch of a ternary counts too.
        // Faded white has its own rule above.
        (#"(^|[^A-Za-z]|\bColor)\.white\b(?!\s*\.\s*opacity)"#, "white is too faint on the accent; use Theme.onAccent"),
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
        // `tintFill` is too faint for words on dark, so it tints only what
        // fills with it: the sidebar's List and DoneButton.
        for call in source.calls(named: ["tint"]) where call.arguments == "Theme.tintFill" {
            if !tintsAFill(call, in: source) {
                found.append(Problem(line: call.line,
                                     reason: "Theme.tintFill is only for the sidebar's List(selection:) in HomeSplit "
                                        + "and DoneButton, where it is a fill"))
            }
        }
        // Anything else in tintFill is drawn in it, words or icons.
        for call in source.calls(named: ["foregroundStyle", "foregroundColor"]) where call.arguments.contains("Theme.tintFill") {
            found.append(Problem(line: call.line, reason: "Theme.tintFill is a fill, never words"))
        }
        // White is only readable on `tintFill`, so `onTintFill` is written
        // only where that fill is under it: FillButtonStyle, and the
        // sidebar's chosen row in HomeSplit, its badge included.
        let code = String(source.code)
        var at = code.startIndex
        while let match = code.range(of: #"\bonTintFill\b"#, options: .regularExpression, range: at..<code.endIndex) {
            at = match.upperBound
            let offset = code.distance(from: code.startIndex, to: match.lowerBound)
            if code[..<match.lowerBound].range(of: #"\blet\s+\z"#, options: .regularExpression) != nil { continue }
            if !onTheFill(offset, in: source) {
                found.append(Problem(line: source.line(at: offset),
                                     reason: "Theme.onTintFill is only for words on tintFill: FillButtonStyle "
                                        + "and HomeSplit's chosen row"))
            }
        }
        // A confirmation button is drawn filled with the tint, with white
        // words on it, so it must be a DoneButton, which tints it to keep
        // those words readable.
        // Only its own closure counts, never the next item's.
        let items = toolbarItems(in: source)
        // Done is checked only inside a ToolbarItem. In a ToolbarItemGroup,
        // straight in `.toolbar { }`, which the system wraps for itself, or
        // anywhere else, neither rule would see it.
        var searchedDone = code.startIndex
        while let match = code.range(of: #"\bDoneButton\b"#, options: .regularExpression,
                                     range: searchedDone..<code.endIndex) {
            searchedDone = match.upperBound
            let offset = code.distance(from: code.startIndex, to: match.lowerBound)
            if code[..<match.lowerBound].range(of: #"\bstruct\s+\z"#, options: .regularExpression) != nil { continue }
            if !items.contains(where: { $0.braces?.contains(offset) == true }) {
                found.append(Problem(line: source.line(at: offset),
                                     reason: "DoneButton goes in its own ToolbarItem, so the Done rules can check it"))
            }
        }
        for item in items {
            let content = item.braces.map(source.contents(of:)) ?? ""
            if item.arguments.contains(".confirmationAction"),
               !content.contains("DoneButton")
                || content.range(of: #"\bButton\s*[({]"#, options: .regularExpression) != nil {
                found.append(Problem(line: item.line,
                                     reason: "a confirmation button fills with the tint; use DoneButton so its words stay readable"))
            }
            // On iOS 26 the toolbar puts a glass ring around the fill
            // unless the item hides its shared background. That is so
            // whatever the placement, so any item holding Done hides it.
            guard content.range(of: #"\bDoneButton\b"#, options: .regularExpression) != nil,
                  let braces = item.braces else { continue }
            let after = braces.upperBound < source.code.count ? String(source.code[(braces.upperBound + 1)...]) : ""
            if after.range(of: #"\A\s*\.\s*sharedBackgroundVisibility\(\s*\.hidden\s*\)"#,
                           options: .regularExpression) == nil {
                found.append(Problem(line: item.line,
                                     reason: "Done draws its own fill; add .sharedBackgroundVisibility(.hidden) "
                                        + "so the toolbar draws no glass ring around it"))
            }
        }
        found += inkProblems(in: source)
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

    /// True when a `.tint(Theme.tintFill)` call is on the sidebar: a
    /// `List(selection:` inside `HomeSplit`, whose closure it closes. Or it
    /// is in `DoneButton`'s body. A selected row and Done fill with the tint
    /// and write white on it; any other list or control would draw its
    /// words or icons in the fill, too faint on dark.
    static func tintsAFill(_ call: SwiftSource.Call, in source: SwiftSource) -> Bool {
        if inside("HomeSplit", call.offset, source) {
            for list in source.calls(named: ["List"]) where list.offset < call.offset && list.arguments.hasPrefix("selection:") {
                // Only white space and a `.` between the List's closure and the tint.
                guard let braces = source.trailingClosureBraces(of: list), braces.upperBound < call.offset else { continue }
                let between = String(source.code[(braces.upperBound + 1)..<call.offset])
                if between.trimmingCharacters(in: .whitespacesAndNewlines) == "." { return true }
            }
        }
        return inside("DoneButton", call.offset, source)
    }

    /// True when `onTintFill` at `offset` has `tintFill` under it: anywhere
    /// in `FillButtonStyle`, which draws that fill, or in HomeSplit inside
    /// an `if chosen {` branch, where the chosen row draws it. A ternary
    /// such as `chosen ? onTintFill : .primary` is not enough: it sets a
    /// style on every other row too, and covers their tinted icons and the
    /// system's own selection.
    static func onTheFill(_ offset: Int, in source: SwiftSource) -> Bool {
        if inside("FillButtonStyle", offset, source) { return true }
        guard inside("HomeSplit", offset, source) else { return false }
        // The innermost brace still open at `offset`.
        var depth = 0
        var at = offset
        while at > 0 {
            at -= 1
            let character = source.code[at]
            if character == "}" { depth += 1 }
            if character == "{" {
                if depth == 0 { break }
                depth -= 1
            }
        }
        guard at >= 0, source.code[at] == "{" else { return false }
        let before = String(source.code[..<at])
        return before.range(of: #"\bif\s+chosen\s*\z"#, options: .regularExpression) != nil
            && chosenIsTied(at: at, in: source)
    }

    /// True when the `chosen` in scope at `offset` is the row's: the
    /// nearest one declared before it is a `chosen: Bool` parameter of the
    /// function it sits in, or a `let chosen = Self.isChosen(...)`, with
    /// at most `&& Self.drawsOwnFill` after it. Any other `chosen`, such as
    /// `let chosen = !Self.isChosen(...)`, could put white on a row with no
    /// fill under it.
    static func chosenIsTied(at offset: Int, in source: SwiftSource) -> Bool {
        let before = String(source.code[..<offset])
        // The last declaration before `offset`, found going forward.
        var last: Range<String.Index>?
        var from = before.startIndex
        while let next = before.range(of: #"\b(?:let|var)\s+chosen\b|\bchosen\s*:\s*Bool\b"#,
                                      options: .regularExpression, range: from..<before.endIndex) {
            last = next
            from = next.upperBound
        }
        guard let declared = last else { return false }
        if before[declared].hasPrefix("chosen") {
            // A parameter: still inside the parentheses of a `func`.
            let lead = String(before[..<declared.lowerBound])
            return lead.range(of: #"\bfunc\s+\w+\s*(?:<[^>]*>)?\s*\((?:[^()]|\([^()]*\))*\z"#,
                              options: .regularExpression) != nil
        }
        let line = before[declared.upperBound...].prefix { $0 != "\n" }
        return line.range(of: #"\A\s*=\s*Self\.isChosen\([^()]*\)\s*(?:&&\s*Self\.drawsOwnFill\s*)?\z"#,
                          options: .regularExpression) != nil
    }

    /// Every call that hands a row its `chosen` in HomeSplit,
    /// `ink(chosen:)`, passes the row's own: `Self.isChosen(...)` or a
    /// `chosen` tied to it.
    static func inkProblems(in source: SwiftSource) -> [Problem] {
        source.calls(named: ["ink"]).filter { call in
            inside("HomeSplit", call.offset, source)
                && String(source.code[..<call.offset]).range(of: #"\bfunc\s+\z"#, options: .regularExpression) == nil
        }.compactMap { call in
            if call.arguments.range(of: #"\Achosen:\s*Self\.isChosen\([^()]*\)\z"#, options: .regularExpression) != nil {
                return nil
            }
            if call.arguments == "chosen: chosen", chosenIsTied(at: call.offset, in: source) { return nil }
            return Problem(line: call.line, reason: "ink(chosen:) takes the row's own chosen, from Self.isChosen")
        }
    }

    /// Every `ToolbarItem`, with a placement or with none: its arguments,
    /// the line it starts on, and its content's braces.
    static func toolbarItems(in source: SwiftSource) -> [(arguments: String, line: Int, braces: Range<Int>?)] {
        var items = source.calls(named: ["ToolbarItem"]).map {
            (arguments: $0.arguments, line: $0.line, braces: source.trailingClosureBraces(of: $0))
        }
        let code = String(source.code)
        var at = code.startIndex
        while let match = code.range(of: #"\bToolbarItem\s*\{"#, options: .regularExpression, range: at..<code.endIndex) {
            at = match.upperBound
            let offset = code.distance(from: code.startIndex, to: match.lowerBound)
            items.append((arguments: "", line: source.line(at: offset), braces: source.braces(after: offset)))
        }
        return items
    }

    /// True when `offset` is after `struct name` with no other type
    /// started between.
    static func inside(_ name: String, _ offset: Int, _ source: SwiftSource) -> Bool {
        let code = String(source.code[..<offset])
        guard let start = code.range(of: #"\bstruct\s+\#(name)\b"#, options: [.regularExpression, .backwards]) else {
            return false
        }
        let after = code[start.upperBound...]
        return after.range(of: #"\b(struct|class|enum|extension)\s"#, options: .regularExpression) == nil
    }
}
#endif
