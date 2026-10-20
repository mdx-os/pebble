import Foundation
import PebbleCore
import PebbleVoice
import Testing

/// The Talk shortcut, from Shortcuts, Siri, Spotlight or the Action Button,
/// opens the app straight into listening.
@MainActor
struct TalkIntentTests {
    /// The only test that runs the intent itself, so the one shared inbox
    /// it asks through is never raced.
    @Test func theTalkShortcutOpensTheAppListening() async throws {
        #expect(TalkIntent.openAppWhenRun)
        _ = TalkRequests.shared.take()
        _ = try await TalkIntent().perform()
        #expect(TalkRequests.shared.waiting != nil)
        let listener = FakeListener()
        let composer = FakeComposer()
        let voice = VoiceCapture(listener: listener, requests: .shared)
        let took = await voice.answerShortcut(owner: "todayComposer", draft: composer.draft,
                                              write: { composer.write($0) }, send: { composer.send($0) })
        #expect(took)
        #expect(voice.phase == .listening)
        #expect(voice.mode == .tap, "a tap sends, since no finger is holding")
        #expect(voice.owner == "todayComposer")
        #expect(TalkRequests.shared.waiting == nil, "taken once")
        listener.say("What's on today")
        listener.lastWords = "What's on today?"
        await voice.release()
        #expect(composer.sent == ["What's on today?"])
    }

    @Test func aShortcutRunLongAgoIsLetGo() async {
        let requests = TalkRequests()
        let asked = Date(timeIntervalSinceReferenceDate: 1_000)
        requests.ask(at: asked)
        let voice = VoiceCapture(listener: FakeListener(), requests: requests)
        let took = await voice.answerShortcut(owner: "composer", draft: "",
                                              now: asked.addingTimeInterval(TalkRequests.freshFor + 1),
                                              write: { _ in }, send: { _ in })
        #expect(!took)
        #expect(voice.phase == .idle)
        #expect(requests.waiting == nil)
    }

    /// With two windows, the shortcut starts in the one that came to the
    /// front last. The other leaves it waiting, and takes it only once it
    /// is in front.
    @Test func theShortcutStartsInTheWindowInFront() async {
        let requests = TalkRequests()
        requests.cameForward("A")
        requests.cameForward("B")
        requests.ask()
        let listener = FakeListener()
        let voice = VoiceCapture(listener: listener, requests: requests)
        let behind = await voice.answerShortcut(owner: "A.todayComposer", in: "A", draft: "",
                                                write: { _ in }, send: { _ in })
        #expect(!behind)
        #expect(requests.waiting != nil, "left for the window in front")
        #expect(listener.requests.isEmpty)
        let inFront = await voice.answerShortcut(owner: "B.todayComposer", in: "B", draft: "",
                                                 write: { _ in }, send: { _ in })
        #expect(inFront)
        #expect(voice.owner == "B.todayComposer")
        #expect(requests.waiting == nil)
    }

    /// The window in front went away, so another may take the next ask; and
    /// before any window has said, the first to show takes it.
    @Test func noWindowInFrontLetsAnyTakeIt() {
        let requests = TalkRequests()
        requests.ask()
        #expect(requests.take(in: "A"))
        requests.cameForward("B")
        requests.wentAway("A")
        requests.ask()
        #expect(!requests.take(in: "A"), "B is still in front")
        requests.wentAway("B")
        #expect(requests.front == nil)
        #expect(requests.take(in: "A"))
    }

    @Test func noShortcutWaitingStartsNothing() async {
        let listener = FakeListener()
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let took = await voice.answerShortcut(owner: "composer", draft: "", write: { _ in }, send: { _ in })
        #expect(!took)
        #expect(listener.requests.isEmpty)
    }
}
