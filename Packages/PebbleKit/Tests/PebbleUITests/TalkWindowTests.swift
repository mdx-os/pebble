#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// One voice capture serves every window. Each window's composer listens
/// under its own owner, so another window's composer, with the same
/// identifier, never shows, sends, cancels or edits what it hears; and a
/// change to the draft that isn't the capture's own, typed or filled, ends
/// listening before a word heard after can write over it.
@MainActor
struct TalkWindowTests {
    /// Hears what the test says, and counts how listening stopped.
    final class Listener: SpeechListening {
        let access = SpeechAccess.allowed
        let hearsOnDevice = true
        var heard: (@MainActor (String) -> Void)?
        var lastWords: String?
        private(set) var finishes = 0
        private(set) var cancels = 0
        func askForAccess() async -> SpeechAccess { access }
        func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                   ended: @escaping @MainActor () -> Void) throws {
            self.heard = heard
        }
        func finish() async -> String? {
            finishes += 1
            return lastWords
        }
        func cancel() {
            cancels += 1
            heard = nil
        }
    }

    /// A composer's draft and what it sent.
    @MainActor
    final class Draft {
        var text: String
        var sent: [String] = []
        init(_ text: String = "") { self.text = text }
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    let listener = Listener()
    let voice: VoiceCapture
    let first = UUID()
    let second = UUID()

    init() {
        voice = VoiceCapture(listener: listener, requests: TalkRequests())
    }

    func owner(_ window: UUID, _ identifier: String = Composer.todayIdentifier) -> String {
        TalkWindow.owner(of: identifier, in: window)
    }

    /// Listening by tap on `window`'s Today composer, with words heard.
    func listen(in window: UUID, draft: Draft, identifier: String = Composer.todayIdentifier) async throws {
        await voice.begin(.tap, owner: owner(window, identifier), draft: draft.text,
                          write: { draft.text = $0 }, send: { draft.sent.append($0); draft.text = "" })
        try #require(voice.phase == .listening)
        listener.heard?("call Sam")
        #expect(draft.text == "call Sam")
    }

    @Test func theSameComposerInTwoWindowsHasTwoOwners() {
        #expect(owner(first) != owner(second))
        #expect(owner(first) != owner(first, Composer.chatIdentifier))
        #expect(owner(first) != Composer.todayIdentifier, "never the accessibility identifier alone")
        #expect(TalkWindow.owner(of: Composer.chatIdentifier, in: nil) == Composer.chatIdentifier)
        #expect(TalkWindow.token(first) != TalkWindow.token(second))
    }

    /// The second window's controls: its line doesn't show, its microphone
    /// isn't lit, and its Send, Don't send, lift and lost touch do nothing.
    @Test func theSecondWindowsControlsNeverActOnTheFirsts() async throws {
        let draft = Draft()
        try await listen(in: first, draft: draft)
        let theirs = owner(second)
        #expect(!voice.belongs(to: theirs))
        #expect(!voice.isActive(for: theirs))
        // A finger on the second window's microphone, lifted and lost.
        let press = TalkPress()
        var started = 0
        press.down(voice) { _ in started += 1 }
        #expect(started == 0, "nothing starts while the first listens")
        press.lifted(voice, owner: theirs, at: .zero)
        press.down(voice) { _ in started += 1 }
        press.lifted(voice, owner: theirs, at: CGSize(width: 0, height: -200))
        press.down(voice) { _ in started += 1 }
        press.reset(voice, owner: theirs)
        // VoiceOver's double tap on it.
        TalkPress.tapped(voice, owner: theirs) { _ in started += 1 }
        // Its line's Send and Don't send, and its going away.
        await voice.release(owner: theirs)
        voice.cancel(owner: theirs)
        await settle()
        #expect(started == 0)
        #expect(voice.phase == .listening)
        #expect(voice.belongs(to: owner(first)))
        #expect(listener.finishes == 0)
        #expect(listener.cancels == 0)
        #expect(draft.text == "call Sam")
        #expect(draft.sent.isEmpty)
        // The first window's own double tap still sends.
        listener.lastWords = "call Sam"
        TalkPress.tapped(voice, owner: owner(first)) { _ in started += 1 }
        #expect(await until { draft.sent == ["call Sam"] })
    }

    /// Typing in the second window's field, though it shares no draft,
    /// leaves the first's listening alone; typing in the first's ends it
    /// and keeps the words typed.
    @Test func typingEndsOnlyItsOwnWindowsListening() async throws {
        let draft = Draft()
        try await listen(in: first, draft: draft)
        let elsewhere = Draft()
        let theirs = Composer.typing(into: elsewhere.binding, voice: voice, owner: owner(second),
                                     shiftIsDown: { true }, send: { elsewhere.sent.append($0) })
        theirs.wrappedValue = "my own words"
        #expect(voice.phase == .listening)
        let ours = Composer.typing(into: draft.binding, voice: voice, owner: owner(first),
                                   shiftIsDown: { true }, send: { draft.sent.append($0) })
        // The capture's own words, read back through the field, are no edit.
        ours.wrappedValue = "call Sam"
        #expect(voice.phase == .listening)
        ours.wrappedValue = "call Sam tomorrow"
        #expect(voice.phase == .idle)
        #expect(listener.cancels == 1, "the microphone stops")
        listener.heard?("call Sam about lunch")
        #expect(draft.text == "call Sam tomorrow", "no later word writes over it")
        #expect(draft.sent.isEmpty)
    }

    /// Shift Return on the Mac is typing too.
    @Test func aLineBreakEndsListeningAndStays() async throws {
        let draft = Draft()
        try await listen(in: first, draft: draft)
        Composer.addLine(to: draft.binding, voice: voice, owner: owner(second))
        #expect(voice.phase == .listening)
        draft.text = "call Sam"
        Composer.addLine(to: draft.binding, voice: voice, owner: owner(first))
        #expect(voice.phase == .idle)
        #expect(draft.text == "call Sam\n")
    }

    func chat() -> ChatController {
        ChatController(brand: Brand(name: "Nova"), model: LocalStubModel(), names: InMemoryAgentNameStore(),
                       replyBeat: .zero)
    }

    /// A suggestion tapped while the chat listens: the words go in, the
    /// listening ends with them, and a word heard after never replaces them.
    /// Another window's tap leaves this one listening.
    @Test func aSuggestionEndsListeningInItsOwnWindowOnly() async throws {
        let controller = chat()
        let draft = Draft()
        try await listen(in: first, draft: draft, identifier: Composer.chatIdentifier)
        // The capture writes the chat's draft, as the composer's binding does.
        controller.draft = draft.text
        let job = FirstConversation.jobs[0]
        ChatView.fill(job.prompt, in: chat(), voice: voice, window: second)
        #expect(voice.phase == .listening)
        controller.draft = ""
        ChatView.fill(job.prompt, in: controller, voice: voice, window: first)
        #expect(controller.draft == job.prompt)
        #expect(voice.phase == .idle)
        listener.heard?("call Sam about lunch")
        #expect(draft.text == "call Sam", "the capture writes nothing after")
        #expect(draft.sent.isEmpty)
    }

    /// Talk about this, from a card on Today, while Today's composer listens.
    @Test func talkingAboutACardEndsListeningInItsOwnWindowOnly() async throws {
        let draft = Draft()
        try await listen(in: first, draft: draft)
        HomeView.draft("Plan Saturday", in: chat(), voice: voice, window: second)
        #expect(voice.phase == .listening)
        HomeView.draft("Plan Saturday", in: chat(), voice: voice, window: first)
        #expect(voice.phase == .idle)
        #expect(listener.cancels == 1)
    }

    #if os(macOS)
    /// Which of the views under test are on screen.
    @MainActor
    @Observable
    final class Shown {
        var first = true
        var second = true
    }

    /// Two windows' composers, drawn for real: the one going away stops
    /// only its own window's listening.
    struct TwoComposers: View {
        let shown: Shown
        let first: UUID
        let second: UUID

        var body: some View {
            VStack {
                if shown.first { composer.environment(\.talkWindow, first) }
                if shown.second { composer.environment(\.talkWindow, second) }
            }
        }

        var composer: some View {
            Composer(draft: .constant(""), isBusy: false, keyboardSends: false, send: { _ in })
        }
    }

    /// `content` while `shown.first` is true. Read in a body, so a change
    /// to it draws again.
    struct Showing<Content: View>: View {
        let shown: Shown
        let content: () -> Content

        var body: some View {
            if shown.first { content() }
        }
    }

    /// Runs `host`'s window until `done`, or gives up after a few seconds.
    func settle(_ host: NSView, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        host.layoutSubtreeIfNeeded()
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// `view` shown in `window`, with the voice, as in the front window.
    func host(_ view: some View, in window: NSWindow) -> NSView {
        // A view hosted outside a scene has no phase of its own.
        let host = NSHostingView(rootView: view.environment(voice).environment(\.scenePhase, .active))
        window.contentView = host
        return host
    }

    @Test func aComposerGoingAwayStopsOnlyItsOwnWindowsListening() async throws {
        let draft = Draft()
        try await listen(in: first, draft: draft, identifier: Composer.chatIdentifier)
        let shown = Shown()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Under ARC a window released on close is released twice.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = host(TwoComposers(shown: shown, first: first, second: second), in: window)
        // Both show, and the window drawn last says it came forward.
        let tokens = [first, second].map(TalkWindow.token)
        settle(host) { voice.requests.front != nil }
        #expect(voice.requests.front.map(tokens.contains) == true)
        shown.second = false
        settle(host) { voice.phase != .listening }
        #expect(voice.phase == .listening, "the other window's composer leaves it going")
        shown.first = false
        settle(host) { voice.phase != .listening }
        #expect(voice.phase == .cancelled, "its own composer going away stops it")
        #expect(draft.text == "")
    }

    /// The home screen gives its composers its own window, so the Today
    /// composer listens under an owner no other window's has.
    @Test func eachHomeScreenGivesItsComposersItsOwnWindow() async throws {
        let suite = "talk-window-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        func home() -> HomeView {
            HomeView(brand: Brand(name: "Nova"), model: LocalStubModel(), names: InMemoryAgentNameStore(stored: "Pip"),
                     onboarding: InMemoryOnboardingStore(finished: true), memory: nil, looks: looks,
                     conversation: nil, section: .today, needsYou: NeedsYou(rule: .isolated()))
        }
        let shown = Shown()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Under ARC a window released on close is released twice.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = host(Showing(shown: shown, content: home), in: window)
        // Today's composer says its window came forward as it shows.
        settle(host) { voice.requests.front != nil }
        let token = try #require(voice.requests.front)
        let homeWindow = try #require(UUID(uuidString: token), "a window of its own, not none")
        let draft = Draft()
        try await listen(in: homeWindow, draft: draft)
        #expect(voice.owner != Composer.todayIdentifier)
        shown.first = false
        settle(host) { voice.phase != .listening }
        #expect(voice.phase == .cancelled, "Today's composer owns it, under its window")
    }
    #endif

    /// Lets every task already started run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Waits, with a generous limit, until `condition` holds.
    func until(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(60))
        while !condition() {
            if ContinuousClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}
#endif
