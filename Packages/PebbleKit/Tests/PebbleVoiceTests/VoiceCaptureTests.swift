import Foundation
import PebbleCore
import Testing

/// Hold to talk, let go to send: every way a capture can go, on a fake
/// recognizer. What is sent is exactly what was heard, and a cancel, an
/// empty release or a refusal sends nothing.
@MainActor
struct VoiceCaptureTests {
    let listener = FakeListener()
    let composer = FakeComposer()

    func capture() -> VoiceCapture {
        VoiceCapture(listener: listener, requests: TalkRequests())
    }

    @Test func holdThenReleaseSendsExactlyTheHeardWords() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        #expect(voice.phase == .listening)
        #expect(voice.owner == "composer")
        listener.say("Remind me")
        listener.say("Remind me to call Sam")
        listener.lastWords = "Remind me to call Sam after lunch."
        await voice.release()
        #expect(composer.sent == ["Remind me to call Sam after lunch."])
        #expect(listener.finishes == 1)
        #expect(listener.cancels == 0)
        #expect(voice.phase == .idle)
        #expect(voice.owner == nil)
    }

    @Test func theWordsShowInTheComposerAsTheyAreHeard() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        listener.say("Book")
        #expect(composer.draft == "Book")
        #expect(voice.heard == "Book")
        listener.say("Book a table")
        #expect(composer.draft == "Book a table")
        #expect(composer.sent.isEmpty, "nothing goes until the person lets go")
    }

    /// Without a last answer from the recognizer, the words heard so far go.
    @Test func releaseSendsTheWordsHeardWhenNoLastAnswerComes() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        listener.say("Water the plants")
        listener.lastWords = nil
        await voice.release()
        #expect(composer.sent == ["Water the plants"])
    }

    @Test func typedWordsStayInFrontOfTheHeardOnes() async {
        let typed = FakeComposer(draft: "Hi,")
        let voice = capture()
        await voice.begin(.hold, on: typed)
        listener.say("can you check the weather")
        #expect(typed.draft == "Hi, can you check the weather")
        listener.lastWords = "can you check the weather?"
        await voice.release()
        #expect(typed.sent == ["Hi, can you check the weather?"])
    }

    @Test func cancelSendsNothing() async {
        let typed = FakeComposer(draft: "Half a thought")
        let voice = capture()
        await voice.begin(.hold, on: typed)
        listener.say("never mind")
        listener.lastWords = "never mind"
        voice.cancel()
        #expect(typed.sent.isEmpty)
        #expect(typed.draft == "Half a thought", "the draft is as it was")
        #expect(listener.cancels == 1)
        #expect(listener.finishes == 0)
        #expect(voice.phase == .cancelled)
        // A late release after the cancel sends nothing either.
        await voice.release()
        #expect(typed.sent.isEmpty)
        voice.settle()
        #expect(voice.phase == .idle)
    }

    @Test func aShortTapWithNothingHeardSendsNothing() async {
        let typed = FakeComposer(draft: "Typed but not sent")
        let voice = capture()
        await voice.begin(.hold, on: typed)
        listener.lastWords = nil
        await voice.release()
        #expect(typed.sent.isEmpty)
        #expect(typed.draft == "Typed but not sent")
        #expect(voice.phase == .idle)
    }

    @Test func emptyOrBlankWordsSendNothing() async {
        for last in ["", "  ", "\n"] {
            let listener = FakeListener()
            let composer = FakeComposer()
            let voice = VoiceCapture(listener: listener, requests: TalkRequests())
            await voice.begin(.hold, on: composer)
            listener.say(last)
            listener.lastWords = last
            await voice.release()
            #expect(composer.sent.isEmpty, "sent for \(last.debugDescription)")
            #expect(voice.phase == .idle)
        }
    }

    @Test func aDeclinedMicrophoneSaysSoAndNeverStarts() async {
        listener.access = .microphoneDeclined
        let voice = capture()
        await voice.begin(.hold, on: composer)
        #expect(voice.phase == .unavailable(.microphoneDeclined))
        #expect(VoiceUnavailable.microphoneDeclined.line == VoiceWords.microphoneDeclined)
        #expect(listener.requests.isEmpty)
        #expect(listener.asked == 0, "an answer already given is never asked again")
        #expect(composer.shown.isEmpty, "typing is left as it was")
    }

    @Test func declinedSpeechSaysSoAndNeverStarts() async {
        let listener = FakeListener(access: .notAsked, answer: .speechDeclined)
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        await voice.begin(.hold, on: composer)
        #expect(listener.asked == 1)
        #expect(voice.phase == .unavailable(.speechDeclined))
        #expect(VoiceUnavailable.speechDeclined.line == VoiceWords.speechDeclined)
        #expect(listener.requests.isEmpty)
        #expect(composer.sent.isEmpty)
    }

    @Test func withoutOnDeviceRecognitionNothingIsAskedOrStarted() async {
        let listener = FakeListener(access: .notAsked)
        listener.hearsOnDevice = false
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        await voice.begin(.hold, on: composer)
        #expect(voice.phase == .unavailable(.notOnDevice))
        #expect(VoiceUnavailable.notOnDevice.line == VoiceWords.notOnDevice)
        #expect(listener.asked == 0, "nobody is asked for something that can't work here")
        #expect(listener.requests.isEmpty, "and nothing is sent elsewhere to be heard")
    }

    @Test func aStartThatFailsSaysSo() async {
        listener.startFails = true
        let voice = capture()
        await voice.begin(.hold, on: composer)
        #expect(voice.phase == .unavailable(.couldNotStart))
        await voice.release()
        #expect(composer.sent.isEmpty)
    }

    /// Every listen asks for on-device recognition, whichever way it starts.
    @Test func noServerFallbackIsEverRequested() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        await voice.release()
        await voice.begin(.tap, on: composer)
        voice.cancel()
        let asking = FakeListener(access: .notAsked)
        let later = VoiceCapture(listener: asking, requests: TalkRequests())
        await later.begin(.tap, on: composer)
        let requests = listener.requests + asking.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.onDeviceOnly })
    }

    @Test func nothingIsAskedUntilTheMicIsFirstHeld() async {
        let listener = FakeListener(access: .notAsked)
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        #expect(listener.asked == 0)
        #expect(voice.phase == .idle)
        await voice.begin(.hold, on: composer)
        #expect(listener.asked == 1)
        #expect(voice.phase == .listening)
    }

    /// The system's question takes the touch, so a hold that started it
    /// ends there, and the person holds again once they've answered.
    @Test func lettingGoWhileAskedSendsNothingAndDoesNotListen() async {
        let listener = FakeListener(access: .notAsked)
        listener.holdsQuestions = true
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let composer = self.composer
        let started = Task { await voice.begin(.hold, on: composer) }
        #expect(await waitUntil { listener.isAsking })
        #expect(voice.phase == .asking)
        await voice.release()
        listener.answerQuestions()
        await started.value
        #expect(voice.phase == .idle)
        #expect(listener.requests.isEmpty)
        #expect(composer.sent.isEmpty)
    }

    /// With a tap, there is no touch to lose: once allowed, it listens.
    @Test func aTapThatAsksListensOnceAllowed() async {
        let listener = FakeListener(access: .notAsked)
        listener.holdsQuestions = true
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let composer = self.composer
        let started = Task { await voice.begin(.tap, on: composer) }
        #expect(await waitUntil { listener.isAsking })
        listener.answerQuestions()
        await started.value
        #expect(voice.phase == .listening)
        #expect(voice.mode == .tap)
    }

    @Test func cancelWhileAskedNeverListens() async {
        let listener = FakeListener(access: .notAsked)
        listener.holdsQuestions = true
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let composer = self.composer
        let started = Task { await voice.begin(.tap, on: composer) }
        #expect(await waitUntil { listener.isAsking })
        voice.cancel()
        #expect(voice.phase == .idle, "nothing had begun, so there is no line to show")
        #expect(voice.owner == nil)
        listener.answerQuestions()
        await started.value
        #expect(voice.phase == .idle)
        #expect(listener.requests.isEmpty)
        #expect(listener.cancels == 0)
        #expect(composer.sent.isEmpty)
    }

    /// What the person types while it listens by tap, as with the Action
    /// Button, ends listening and stays: later words, Send and Don't send
    /// never write over it, and nothing is sent.
    enum AfterTheEdit: CaseIterable {
        case moreWords, send, dontSend
    }

    @Test(arguments: AfterTheEdit.allCases)
    func anEditWhileListeningIsNeverLostOrSent(_ after: AfterTheEdit) async {
        let typed = FakeComposer(draft: "Hi,")
        let voice = capture()
        await voice.begin(.tap, on: typed)
        listener.say("call Sam")
        #expect(typed.draft == "Hi, call Sam")
        // The capture's own words are not an edit.
        voice.edited(owner: "composer", to: typed.draft)
        #expect(voice.phase == .listening)
        // Another composer's change is not this one's edit.
        voice.edited(owner: "todayComposer", to: "elsewhere")
        #expect(voice.phase == .listening)
        typed.draft = "Hi, call Sam tomorrow"
        voice.edited(owner: "composer", to: typed.draft)
        #expect(voice.phase == .idle)
        #expect(voice.owner == nil)
        #expect(listener.cancels == 1, "the microphone stops")
        switch after {
        case .moreWords:
            listener.say("call Sam about lunch")
        case .send:
            listener.lastWords = "call Sam about lunch"
            await voice.release()
        case .dontSend:
            voice.cancel()
        }
        #expect(typed.draft == "Hi, call Sam tomorrow")
        #expect(typed.sent.isEmpty)
        #expect(typed.shown == ["Hi, call Sam"], "nothing written after the edit")
        #expect(voice.phase == .idle)
        #expect(listener.finishes == 0)
    }

    /// An edit while the last words are on their way drops them too.
    @Test func anEditWhileTheLastWordsComeIsKept() async {
        let listener = SlowFinishListener()
        let voice = VoiceCapture(listener: listener, requests: TalkRequests())
        let typed = FakeComposer(draft: "")
        await voice.begin(.tap, on: typed)
        let sending = Task { await voice.release() }
        #expect(await waitUntil { voice.phase == .sending })
        typed.draft = "My own words"
        voice.edited(owner: "composer", to: typed.draft)
        #expect(voice.phase == .idle)
        listener.giveLastWords("call Sam")
        await sending.value
        #expect(typed.draft == "My own words")
        #expect(typed.sent.isEmpty)
    }

    @Test func stoppingOnItsOwnKeepsTheWordsAndSendsNothing() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        listener.say("Plan Saturday")
        listener.stopOnItsOwn()
        #expect(voice.phase == .idle)
        #expect(composer.draft == "Plan Saturday", "there to send or change")
        #expect(composer.sent.isEmpty)
        await voice.release()
        #expect(composer.sent.isEmpty)
    }

    /// A composer going away stops only its own listening.
    @Test func onlyTheOwnerCancelsByName() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        voice.cancel(owner: "todayComposer")
        #expect(voice.phase == .listening)
        voice.cancel(owner: "composer")
        #expect(voice.phase == .cancelled)
    }

    /// Two windows show the same composer, each under its own owner. The
    /// second can't cancel, edit, finish or send the first's listening, and
    /// never sees it as its own.
    @Test func aSecondWindowsComposerNeverActsOnTheFirsts() async {
        let first = "A.composer", second = "B.composer"
        let voice = capture()
        await voice.begin(.tap, owner: first, draft: composer.draft,
                          write: { composer.write($0) }, send: { composer.send($0) })
        listener.say("call Sam")
        #expect(voice.belongs(to: first))
        #expect(voice.isActive(for: first))
        #expect(!voice.belongs(to: second), "the second window shows no Send or Don't send")
        #expect(!voice.isActive(for: second))
        voice.cancel(owner: second)
        voice.edited(owner: second, to: "typed in the other window")
        await voice.release(owner: second)
        #expect(voice.phase == .listening)
        #expect(listener.cancels == 0)
        #expect(listener.finishes == 0)
        #expect(composer.draft == "call Sam")
        #expect(composer.sent.isEmpty)
        // A start from the second window while the first listens is ignored too.
        await voice.begin(.tap, owner: second, draft: "", write: { _ in }, send: { _ in })
        #expect(voice.belongs(to: first))
        listener.lastWords = "call Sam"
        await voice.release(owner: first)
        #expect(composer.sent == ["call Sam"])
    }

    /// Don't send in the right window still cancels.
    @Test func theOwnersOwnDontSendCancels() async {
        let voice = capture()
        await voice.begin(.tap, on: composer)
        listener.say("call Sam")
        voice.cancel(owner: "composer")
        #expect(voice.phase == .cancelled)
        #expect(composer.draft == "")
        #expect(composer.sent.isEmpty)
    }

    /// The capture lets go of the words once they're sent or dropped, so
    /// the composer and the chat are the only places they are.
    @Test func nothingHeardIsKeptAfterward() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        listener.say("Call the dentist")
        await voice.release()
        #expect(voice.heard.isEmpty)
        await voice.begin(.hold, on: composer)
        listener.say("Something private")
        voice.cancel()
        #expect(voice.heard.isEmpty)
        #expect(!Mirror(reflecting: voice).children.contains { "\($0.value)".contains("Something private") })
    }

    @Test func aSecondStartWhileListeningIsIgnored() async {
        let voice = capture()
        await voice.begin(.hold, on: composer)
        await voice.begin(.tap, on: FakeComposer(draft: "other"))
        #expect(listener.requests.count == 1)
        #expect(voice.mode == .hold)
    }

    @Test func theWordsUseNoDash() {
        for line in VoiceWords.all {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "dash in: \(line)")
        }
    }
}
