#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SourceScan
import SwiftUI
import Testing
@testable import PebbleUI

@MainActor
struct FirstRunScreensTests {
    let brand = Brand(name: "Nova")

    @Test("Smoke: every showcase screen draws in light and dark", arguments: ShowcaseScene.allCases, [ColorScheme.light, .dark])
    func smokeEveryScreenInLightAndDark(scene: ShowcaseScene, scheme: ColorScheme) throws {
        try smokeRender(scene.view(brand: brand)
            .environment(\.colorScheme, scheme)
            .frame(width: 393, height: 852))
    }

    #if os(macOS)
    /// Scrolled down to reach Continue, as at a large text size or in a
    /// short window, the next page still opens at its top, heading and all.
    @Test func eachPageOpensAtItsTop() throws {
        let suite = "first-run-top-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(brand: brand, names: InMemoryAgentNameStore(), store: InMemoryOnboardingStore(),
                                    looks: looks, page: .hello, draftName: "", onFinish: { _ in })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 280), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Under ARC a window released on close is released twice.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: OnboardingView(model: model, place: .onDevice)
            .environment(\.holdsStill, true)
            .environment(\.dynamicTypeSize, .accessibility3))
        window.contentView = host
        func settle(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            host.layoutSubtreeIfNeeded()
            while !done(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            }
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        settle { scrollView(in: host) != nil }
        let scroller = try #require(scrollView(in: host))
        let top = scroller.contentView.bounds.origin.y
        func offset() -> CGFloat { scroller.contentView.bounds.origin.y - top }
        func bottom() -> CGFloat {
            (scroller.documentView?.frame.height ?? 0) - scroller.contentView.bounds.height
        }
        // Down to the foot of the page, where Continue waits.
        settle { bottom() > 100 }
        #expect(bottom() > 100, "the page outgrows the window, so it scrolls")
        scroller.contentView.scroll(to: CGPoint(x: 0, y: top + bottom()))
        scroller.reflectScrolledClipView(scroller.contentView)
        settle { offset() > 100 }
        #expect(offset() > 100, "scrolled down to Continue")
        model.advance()
        settle { model.page == .name && abs(offset()) < 1 }
        #expect(model.page == .name)
        #expect(abs(offset()) < 1, "the next page opens at its top, scrolled \(offset())")
    }
    #endif

    /// Each view of the first run that reads Reduce Motion also holds still
    /// for the screenshots, so its entrances settle and two shots match.
    @Test func theFirstRunHoldsStillForTheScreenshots() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let text = try String(contentsOf: root.appendingPathComponent("Packages/PebbleKit/Sources/PebbleUI/OnboardingView.swift"),
                              encoding: .utf8)
        #expect(Self.stillProblems(in: text) == [])
        #expect(text.contains("struct OnboardingView") && text.contains("struct IdeaCardButton"))
        let wrong = [
            "struct A: View {\n    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n}",
            "struct A: View {\n    @Environment(\\.accessibilityReduceMotion) private var systemReduceMotion\n"
                + "    @Environment(\\.holdsStill) private var holdsStill\n    private var reduceMotion: Bool { systemReduceMotion }\n}",
            "struct A: View {\n    @Environment(\\.accessibilityReduceMotion) private var systemReduceMotion\n"
                + "    @Environment(\\.holdsStill) private var holdsStill\n"
                + "    private var reduceMotion: Bool { systemReduceMotion || holdsStill }\n}\n"
                + "struct B: View {\n    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n}",
        ]
        for text in wrong {
            #expect(!Self.stillProblems(in: text).isEmpty, "missed: \(text)")
        }
    }

    /// Each struct in `text` that reads Reduce Motion without folding in
    /// `holdsStill`, read through its own braces.
    static func stillProblems(in text: String) -> [String] {
        let source = SwiftSource(text)
        let code = String(source.code)
        var problems: [String] = []
        var at = code.startIndex
        while let found = code.range(of: #"\bstruct\s+(\w+)"#, options: .regularExpression, range: at..<code.endIndex) {
            at = found.upperBound
            let offset = code.distance(from: code.startIndex, to: found.lowerBound)
            guard let braces = source.braces(after: offset) else { continue }
            let body = source.contents(of: braces)
            guard body.contains(#"\.accessibilityReduceMotion"#) else { continue }
            if !body.contains(#"@Environment(\.holdsStill)"#)
                || body.range(of: #"var\s+reduceMotion\s*:\s*Bool\s*\{\s*systemReduceMotion\s*\|\|\s*holdsStill\s*\}"#,
                              options: .regularExpression) == nil {
                problems.append("\(code[found]) reads Reduce Motion without holdsStill")
            }
        }
        return problems
    }

    @Test func finishingTheFirstRunSavesNameLookAndFlag() throws {
        let suite = "pebble.ui.onboarding.\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let names = InMemoryAgentNameStore()
        let store = InMemoryOnboardingStore()
        var sent: String?? = .none
        let model = OnboardingModel(brand: brand, names: names, store: store, looks: looks,
                                    page: .hello, draftName: "", onFinish: { sent = .some($0) })
        model.advance()
        #expect(model.page == .name)
        model.draftName = "   "
        model.commitName()
        #expect(model.page == .name)
        #expect(model.hint == FirstConversation.needsAName)
        model.draftName = " Pip "
        model.commitName()
        // Not saved until the first run finishes.
        #expect(names.loadDisplayName() == nil)
        #expect(model.page == .look)
        model.look = .tide
        model.advance()
        #expect(model.page == .ideas)
        #expect(!store.hasFinished())
        let job = try #require(model.starters.first)
        model.pick(job)
        #expect(sent == .some(job.prompt))
        #expect(store.hasFinished())
        #expect(names.loadDisplayName() == "Pip")
        #expect(AgentLook.load(from: looks) == .tide)
        #expect(model.displayName == "Pip")
    }

    @Test func skippingEverythingStillFinishesOnce() throws {
        let suite = "pebble.ui.skip.\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let store = InMemoryOnboardingStore()
        var finishes = 0
        let model = OnboardingModel(brand: brand, names: InMemoryAgentNameStore(), store: store, looks: looks,
                                    page: .name, draftName: "", onFinish: { line in
                                        #expect(line == nil)
                                        finishes += 1
                                    })
        model.skipName()
        model.advance()
        model.finishWithoutIdea()
        #expect(store.hasFinished())
        #expect(finishes == 1)
        #expect(model.displayName == brand.name)
    }

    @Test func theProactivityPageIsHiddenUntilThereIsAChoice() throws {
        let suite = "first-run.hidden.\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(brand: brand, names: InMemoryAgentNameStore(), store: InMemoryOnboardingStore(),
                                    looks: looks, page: .hello, draftName: "", onFinish: { _ in })
        #expect(!model.visiblePages.contains(.proactivity))
    }

    @Test func forgettingFromTheMemoryScreenErasesItFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store, place: .onDevice)
        model.newNote = "Door code 4417"
        model.add()
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.notes.count == 2)
        #expect(model.newNote.isEmpty)
        let secret = try #require(model.notes.first)
        model.forget(secret)
        #expect(model.notes.map(\.text) == ["Prefers tea"])
        #expect(model.status == MemoryWords.forgotten)
        let bytes = try Data(contentsOf: url)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("4417"))

        let tea = try #require(model.notes.first)
        model.beginEdit(tea)
        model.editDraft = "Prefers coffee"
        model.saveEdit()
        #expect(model.editingID == nil)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("tea"))

        let coffee = try #require(model.notes.first)
        model.beginEdit(coffee)
        model.forget(coffee)
        #expect(model.editingID == nil)
        #expect(model.editDraft.isEmpty)

        model.forgetEverything()
        #expect(model.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Smoke: the source labels draw",
          arguments: [MemorySource.toldMe, .fromApp("Calendar"), .inferred], [ColorScheme.light, .dark])
    func smokeSourceLabels(source: MemorySource, scheme: ColorScheme) throws {
        try smokeRender(SourceLabel(source: source).environment(\.colorScheme, scheme))
    }

    @Test func theMemoryScreenShowsWhereEachNoteCameFrom() {
        let model = MemoryModel(store: ShowcaseScene.sampleMemory(), place: .onDevice)
        #expect(Set(model.notes.map(\.source)) == [.toldMe, .fromApp("Calendar"), .inferred])
    }

    @Test func aBlankNoteFromTheScreenIsRefusedKindly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        model.newNote = "   "
        model.add()
        #expect(model.notes.isEmpty)
        #expect(model.status == MemoryWords.needsWords)
    }

    @Test func extraApprovalsFromOneQuestionAreRefused() {
        let action = ProposedAction(kind: .purchase,
                                    recipient: Recipient(id: "merchant:1", displayName: "Rise Bakery", handle: "risebakery.example"),
                                    details: "Sourdough", price: Price(minorUnits: 1450, currency: "CAD"))
        let rule = AskFirst.isolated()
        var approvals: [Approval] = []
        let sheet = ConfirmationState(request: rule.ask(action)!, rule: rule,
                                      onApprove: { approvals.append($0) }, onDecline: {})
        sheet.tapPrimary()
        #expect(sheet.tapPrimary() == .ignored)
        #expect(approvals.count == 1)
        #expect(rule.decide(action, approval: approvals.first) == .proceed)
        for extra in approvals {
            #expect(rule.decide(action, approval: extra) == .stop)
        }
    }

    @Test func notNowClosesTheQuestionForGood() {
        let action = ProposedAction(kind: .send, recipient: Recipient(id: "c:1", displayName: "Sam", handle: "416 555 0101"), details: "Hi")
        let rule = AskFirst.isolated()
        let request = rule.ask(action)!
        var declined = false
        let sheet = ConfirmationState(request: request, rule: rule, onApprove: { _ in }, onDecline: { declined = true })
        sheet.cancel()
        #expect(declined)
        #expect(rule.decide(action, approval: request.approve()) == .stop)
    }

    @Test func anUnreadableMemoryIsShownAndCanBeCleared() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pebble-ui-\(UUID().uuidString).json")
        try Data("not notes {".utf8).write(to: url)
        let model = MemoryModel(store: MemoryStore(fileURL: url), place: .onDevice)
        #expect(model.isUnreadable)
        #expect(model.hasStoredFile)
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.status == MemoryWords.unreadable)
        #expect(model.newNote == "Prefers tea")
        model.forgetEverything()
        #expect(!model.isUnreadable)
        #expect(!model.hasStoredFile)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
