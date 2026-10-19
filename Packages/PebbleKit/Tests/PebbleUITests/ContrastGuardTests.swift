#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Testing
@testable import PebbleUI
import SourceScan

/// Words stay readable: every pair in `Theme.textPairs` clears its minimum
/// (4.5 to 1 for words, 3 to 1 for a field's edge) in light and dark, and no
/// screen colors words in a way the pairs don't cover. A new color for words
/// means a new pair, or this fails. The scan of every screen reads Swift, so
/// it lives in Tools/GuardKit: its rules are `ContrastLint` in GuardScan,
/// the sweep is `ContrastSweepTests`, and what each rule must catch is in
/// `GuardWrongCaseTests`.
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

    /// With Increase Contrast on, each ink that has a deeper pair draws it,
    /// and every pair still clears its minimum, by more than without.
    @Test(arguments: [ColorScheme.light, .dark])
    func everyThemePairIsReadableWithIncreasedContrast(scheme: ColorScheme) {
        let standard = Theme.textPairs(scheme)
        let increased = Theme.textPairs(scheme, increasedContrast: true)
        #expect(increased.count == standard.count)
        for (pair, before) in zip(increased, standard) {
            #expect(pair.contrast >= pair.minimum,
                    "\(pair.text) on \(pair.background) in \(scheme), increased, is \(String(format: "%.2f", pair.contrast)) to 1")
            #expect(pair.contrast >= before.contrast - 0.001, "\(pair.text) on \(pair.background) in \(scheme)")
        }
        for ink in [Theme.secondaryText, Theme.accentText, Theme.dangerText, Theme.fieldEdge] {
            #expect(ink.rgb(scheme, increasedContrast: true) != ink.rgb(scheme))
        }
    }

    /// `accentText` is the one way to write in the accent's color, so it
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

    /// Lines still count after a `\` joins two lines of a multi-line
    /// string, and a paren in a string inside an interpolation never
    /// throws the count off. GuardKit's `ContrastSweepTests` checks the
    /// same for the guards' own reading.
    @Test func theScanCountsLinesThroughEveryKindOfString() {
        let joined = "let a = \"\"\"\n    one \\\n    two\n    \"\"\"\nText(\"x\")\n"
        #expect(SwiftSource(joined).literals.map(\.line) == [1, 5])
        let paren = "let a = \"\\(f(\"(\"))\"\nText(\"x\")\n    .foregroundStyle(Theme.accent)\n"
        #expect(SwiftSource(paren).literals.map(\.line) == [1, 2])
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
#endif
