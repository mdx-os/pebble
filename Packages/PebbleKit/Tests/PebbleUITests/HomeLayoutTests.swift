#if canImport(SwiftUI)
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import Testing
@testable import PebbleUI

/// The wide layout at every iPad size and multitasking width, rendered off
/// screen. AppUITests drives the same layout in the Simulator.
@MainActor
struct HomeLayoutTests {
    let brand = Brand(name: "Nova")

    private func chat() -> ChatController {
        ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                            conversation: ShowcaseScene.sampleFirstChat())
    }

    /// The lines of `text` outside a Debug-only branch that are more than
    /// imports, blank lines and directives. A branch is Debug-only when
    /// `DEBUG` is one of the `&&` terms of its `#if`, with no `||` and no
    /// `!`. Its `#else` and `#elseif` are not.
    nonisolated static func codeOutsideDebug(in text: String) -> [String] {
        let lines = String(SwiftSource(text).code).split(separator: "\n", omittingEmptySubsequences: false)
        var branches: [Bool] = []
        var outside: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func condition(after directive: String) -> Bool {
                let rest = line.dropFirst(directive.count).trimmingCharacters(in: .whitespaces)
                guard !rest.contains("||"), !rest.contains("!") else { return false }
                return rest.components(separatedBy: "&&").contains {
                    $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "()"))) == "DEBUG"
                }
            }
            if line.hasPrefix("#if") {
                branches.append(condition(after: "#if"))
            } else if line.hasPrefix("#elseif") || line.hasPrefix("#else") {
                if !branches.isEmpty { branches[branches.count - 1] = false }
            } else if line.hasPrefix("#endif") {
                _ = branches.popLast()
            } else if !line.isEmpty, !line.hasPrefix("import "), !branches.contains(true) {
                outside.append(line)
            }
        }
        return outside
    }

    /// PERMANENT GUARD. The showcase is Debug only: its sample data, its
    /// example cloud address and its stand-in model never ship. So all of
    /// ShowcaseScene.swift but its imports sits inside `#if DEBUG`.
    @Test func theShowcaseIsDebugOnly() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/ShowcaseScene.swift"),
                              encoding: .utf8)
        #expect(text.contains("public enum ShowcaseScene"))
        #expect(Self.codeOutsideDebug(in: text) == [], "shipped in Release")
        let wrong = [
            "#if DEBUG\nenum A {}\n#endif\nstruct B {}",
            "#if !DEBUG\nstruct B {}\n#endif",
            "#if DEBUG || os(iOS)\nstruct B {}\n#endif",
            "#if DEBUG\nenum A {}\n#else\nstruct B {}\n#endif",
            "#if DEBUG\nenum A {}\n#elseif os(iOS)\nstruct B {}\n#endif",
            "struct B {}\n#if DEBUG\nenum A {}\n#endif",
        ]
        for code in wrong {
            #expect(!Self.codeOutsideDebug(in: code).isEmpty, "missed: \(code)")
        }
        let right = [
            "import Foundation\n#if canImport(SwiftUI) && DEBUG\nimport SwiftUI\nenum A {}\n#endif\n\n#if DEBUG\nstruct B {}\n#endif",
            "#if DEBUG\n#if os(iOS)\nstruct B {}\n#else\nstruct C {}\n#endif\n#endif",
            "// A comment out here.\n#if (DEBUG)\nstruct B {}\n#endif",
        ]
        for code in right {
            #expect(Self.codeOutsideDebug(in: code).isEmpty, "flagged: \(code)")
        }
    }

    /// PERMANENT GUARD. ShowcaseScene exists only in Debug, so a line of
    /// the app or the package that names it outside `#if DEBUG` breaks the
    /// Release build. `make build-release` proves it builds; this says
    /// where it would break, without building. Off the main actor, since
    /// it sweeps every source file.
    @Test nonisolated func theShowcaseIsReadOnlyInDebug() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let app = try SwiftSource.files(under: root.appendingPathComponent("App")).map { ("App/\($0.name)", $0.text) }
        let package = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let files = (app + package).filter { $0.0 != "PebbleUI/ShowcaseScene.swift" }
        var readers: [String] = []
        for (name, text) in files where text.contains("ShowcaseScene") {
            readers.append(name)
            for line in Self.codeOutsideDebug(in: text) where line.contains("ShowcaseScene") {
                Issue.record(Comment(rawValue: "\(name): \(line) names ShowcaseScene outside #if DEBUG, so Release can't build"))
            }
        }
        #expect(readers.sorted() == ["App/Sources/PebbleApp.swift", "App/Sources/SnapshotMode.swift"], "the reads this checks are still there")
        let wrong = "#if DEBUG\nlet a = 1\n#endif\nlet scene = ShowcaseScene.launchKey"
        #expect(Self.codeOutsideDebug(in: wrong).contains { $0.contains("ShowcaseScene") })
    }

    /// The launch arguments the screenshot scripts pass are the keys the
    /// app reads, kept beside `launchKey`, so the two can never drift.
    @Test func theScreenshotScriptsPassTheKeysTheAppReads() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/screenshots.sh"), encoding: .utf8)
        for key in [ShowcaseScene.launchKey, ShowcaseScene.stillKey, ShowcaseScene.sheetKey, ShowcaseScene.darkKey] {
            #expect(script.contains("-\(key) "), "screenshots.sh never passes -\(key)")
        }
        for name in ["PebbleApp.swift", "SnapshotMode.swift"] {
            let app = try String(contentsOf: root.appendingPathComponent("App/Sources/\(name)"), encoding: .utf8)
            let literals = SwiftSource(app).literals.map(\.text)
            for key in [ShowcaseScene.launchKey, ShowcaseScene.stillKey, ShowcaseScene.sheetKey, ShowcaseScene.darkKey] {
                #expect(!literals.contains(key), "\(name) spells \"\(key)\"; read ShowcaseScene's constant")
            }
        }
    }

    @Test("Smoke: the sidebar layout draws at each size", arguments: [
        CGSize(width: 1032, height: 1376), // iPad Pro 13-inch, portrait
        CGSize(width: 1376, height: 1032), // iPad Pro 13-inch, landscape
        CGSize(width: 744, height: 1133),  // iPad mini, portrait
        CGSize(width: 1133, height: 744),  // iPad mini, landscape
        CGSize(width: 678, height: 1032),  // half of a 13-inch in Split View
        CGSize(width: 500, height: 600),   // a small Stage Manager window
    ], HomeSection.allCases)
    func smokeTheSidebarLayoutAtEachSize(size: CGSize, section: HomeSection) throws {
        let controller = chat()
        let feed = FeedModel(sources: [SampleFeedSource()], needsYou: ShowcaseScene.sampleQuestion(), place: .onDevice)
        let view = HomeSplit(
            chat: controller,
            section: .constant(section),
            needsYouCount: feed.feed.needsYou.count,
            todayScreen: FeedView(model: feed, look: .startingPoint, onTalk: { _ in })
                .safeAreaInset(edge: .bottom) {
                    TodayComposer(chat: controller, inFront: true, send: { _ in })
                },
            chatScreen: ChatView(controller: controller, look: .startingPoint, firstMessage: nil),
            memoryScreen: MemoryView(store: ShowcaseScene.sampleMemory(), place: .onDevice),
            newChat: {}
        )
        try smokeRender(view.frame(width: size.width, height: size.height))
    }

    /// The row drawn chosen and the row VoiceOver hears chosen are the same
    /// one. With no selection yet, Today is drawn chosen only beside its own
    /// screen. A collapsed list with no selection, as after going back on
    /// iPhone, has no row chosen.
    @Test(arguments: [nil] + HomeSection.allCases.map(Optional.some), [true, false])
    func theChosenRowIsHeardChosen(section: HomeSection?, regular: Bool) {
        typealias Split = HomeSplit<EmptyView, EmptyView, EmptyView>
        let chosen = HomeSection.allCases.filter { Split.isChosen($0, section: section, regular: regular) }
        if let section {
            #expect(chosen == [section], "the selection is the one row drawn chosen")
        } else if regular {
            #expect(chosen == [.today], "Today shows beside the list, so it is drawn chosen")
        } else {
            #expect(chosen.isEmpty, "a collapsed list with nothing chosen draws no row chosen")
        }
        for place in HomeSection.allCases {
            // Where this code draws the fill, the row it draws is heard chosen.
            #expect(Split.traits(place, section: section, regular: regular, ownFill: true).contains(.isSelected)
                        == Split.isChosen(place, section: section, regular: regular),
                    "\(place) with \(String(describing: section)), regular \(regular)")
            // Where the system draws the selection, as on the Mac, it gives
            // the trait itself, so nothing is added: with no selection the
            // Mac draws none, and Today must not be heard selected.
            #expect(Split.traits(place, section: section, regular: regular, ownFill: false).isEmpty,
                    "\(place) with \(String(describing: section)), regular \(regular), system selection")
        }
        // A count is heard as what it counts, never as a bare number: the
        // one the chosen row draws itself and the system badge on the rest.
        for count in [1, 3] {
            let spoken = Split.spokenCount(count)
            #expect(spoken == HomeWords.waiting(count))
            #expect(spoken.contains("\(count)") && spoken.contains("waiting"), "\(spoken)")
        }
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = (try? String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/HomeView.swift"),
                                encoding: .utf8)) ?? ""
        let code = String(SwiftSource(text).code)
        #expect(code.contains("Self.traits(place, section: section, regular: isRegular, ownFill: Self.drawsOwnFill)"),
                "the sidebar adds the trait only where it draws its own fill")
        #expect(code.range(of: #"Text\(count, format: \.number\)\s*\.monospacedDigit\(\)\s*\.accessibilityLabel\(Self\.spokenCount\(count\)\)"#,
                           options: .regularExpression) != nil, "the drawn count carries the spoken label")
        #expect(code.range(of: #"\.badge\([^\n]*\n?[^\n]*Text\(count, format: \.number\)\.accessibilityLabel\(Self\.spokenCount\(count\)\)\)"#,
                           options: .regularExpression) != nil, "the system badge carries the spoken label too")
        #if os(iOS)
        #expect(Split.drawsOwnFill)
        #else
        #expect(!Split.drawsOwnFill, "the Mac keeps the system's selection")
        #endif
    }

    /// Done draws its own style, so it brings back what the system's would
    /// give: a ring while the keyboard is on it, and the iPad pointer's
    /// highlight. The focus is read in `FocusRing`, a view inside the button,
    /// not on the style, where it stays false.
    @Test func doneShowsKeyboardFocusAndPointerHover() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/Theme.swift"),
                              encoding: .utf8)
        #expect(Self.focusProblems(in: text) == [])
        let wrong = [
            // The focus read on the style, before or after makeBody.
            "struct FillButtonStyle: ButtonStyle {\n    @Environment(\\.isFocused) private var isFocused\n"
                + "    func makeBody(configuration: Configuration) -> some View {\n        FocusRing { configuration.label }\n"
                + "            .pointerHover(in: Capsule())\n    }\n}\n" + Self.rightRing,
            "struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                + "        FocusRing { configuration.label }\n            .pointerHover(in: Capsule())\n    }\n"
                + "    @Environment(\\.isFocused) private var isFocused\n}\n" + Self.rightRing,
            // No pointer highlight, or the capsule outside the ring.
            "struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                + "        FocusRing { configuration.label }\n    }\n}\n" + Self.rightRing,
            "struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                + "        configuration.label\n            .pointerHover(in: Capsule())\n    }\n}\n" + Self.rightRing,
            // A ring that never reads the focus, or never draws.
            Self.rightStyle + "struct FocusRing<Content: View>: View {\n    @ViewBuilder let content: Content\n"
                + "    var body: some View { content }\n}\nstruct Other { @Environment(\\.isFocused) var isFocused }",
            // Words after the style that mention pointerHover don't count for it.
            "struct FillButtonStyle: ButtonStyle {\n    func makeBody(configuration: Configuration) -> some View {\n"
                + "        FocusRing { configuration.label }\n    }\n}\nlet a = Text(\"\").pointerHover(in: Capsule())\n" + Self.rightRing,
        ]
        for text in wrong {
            #expect(!Self.focusProblems(in: text).isEmpty, "missed: \(text)")
        }
        #expect(Self.focusProblems(in: Self.rightStyle + Self.rightRing) == [])
        try smokeRender(DoneButton {}.padding().frame(width: 200, height: 100))
    }

    private static let rightStyle = "struct FillButtonStyle: ButtonStyle {\n"
        + "    func makeBody(configuration: Configuration) -> some View {\n        FocusRing { configuration.label }\n"
        + "            .pointerHover(in: Capsule())\n    }\n}\n"
    private static let rightRing = "struct FocusRing<Content: View>: View {\n"
        + "    @Environment(\\.isFocused) private var isFocused\n    @ViewBuilder let content: Content\n"
        + "    var body: some View {\n        content.overlay {\n            if isFocused {\n"
        + "                Capsule().strokeBorder(Theme.tintFill, lineWidth: 2)\n            }\n        }\n    }\n}\n"

    /// What keeps Done's focus ring and pointer highlight from showing, in
    /// `text`. Each type is read through its own balanced braces, so what
    /// comes after it, or a member after `makeBody`, is never missed.
    static func focusProblems(in text: String) -> [String] {
        let source = SwiftSource(text)
        let code = String(source.code)
        func body(of name: String) -> String? {
            guard let found = code.range(of: #"\bstruct\s+\#(name)\b"#, options: .regularExpression) else { return nil }
            return source.braces(after: code.distance(from: code.startIndex, to: found.lowerBound)).map(source.contents(of:))
        }
        var problems: [String] = []
        if let style = body(of: "FillButtonStyle") {
            if !style.contains(".pointerHover(in: Capsule())") { problems.append("the style takes no pointer highlight") }
            if style.range(of: #"\bisFocused\b"#, options: .regularExpression) != nil {
                problems.append("the style reads the focus itself, where it stays false")
            }
            if !style.contains("FocusRing {") { problems.append("the style's capsule is not inside FocusRing") }
        } else {
            problems.append("no FillButtonStyle")
        }
        if let ring = body(of: "FocusRing") {
            if !ring.contains(#"@Environment(\.isFocused)"#) { problems.append("FocusRing never reads the focus") }
            if ring.range(of: #"if\s+isFocused\s*\{\s*Capsule\(\)\.strokeBorder"#, options: .regularExpression) == nil {
                problems.append("FocusRing draws no ring")
            }
        } else {
            problems.append("no FocusRing")
        }
        return problems
    }


    @Test("Smoke: the shortcuts screen draws", arguments: [ColorScheme.light, .dark])
    func smokeTheShortcutsScreen(scheme: ColorScheme) throws {
        try smokeRender(KeyboardShortcutsView()
            .environment(\.colorScheme, scheme)
            .frame(width: 540, height: 620))
    }

    @Test("Smoke: the wide chat draws at each text size", arguments: [DynamicTypeSize.large, .accessibility3])
    func smokeTheChatWideAtEachTextSize(size: DynamicTypeSize) throws {
        try smokeRender(ChatView(controller: chat(), look: .startingPoint, firstMessage: nil)
            .environment(\.dynamicTypeSize, size)
            .frame(width: 1376, height: 1032))
    }

    /// The chat column stops at a reading width, so lines never run edge to
    /// edge on a 13-inch screen.
    @Test func theChatColumnHasAReadingWidth() {
        #expect(Theme.chatWidth <= 720)
        #expect(Theme.bubbleWidth < Theme.chatWidth)
    }

    /// The window can change shape at any moment. The conversation lives
    /// outside the chat screen, so a new screen shows the same words.
    @Test func aNewChatScreenKeepsTheConversation() throws {
        let controller = chat()
        controller.conversation = try controller.conversation.appendingPerson("Pack lunches")
        let before = controller.conversation.turns.map(\.text)
        _ = ChatView(controller: controller, look: nil, firstMessage: nil)
        _ = ChatView(controller: controller, look: nil, firstMessage: nil)
        #expect(controller.conversation.turns.map(\.text) == before)
    }

    @Test func aKeptConversationIsUsedOnlyWhenItsPrivacyPromiseHolds() {
        let offDevice = Conversation(turns: ShowcaseScene.sampleFirstChat().turns, place: .mayLeaveDevice)
        let controller = ChatController.make(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore(),
                                             conversation: offDevice)
        #expect(controller.conversation.turns.count == 1)
    }
}
#endif
