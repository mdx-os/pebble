import Foundation
import PebbleCore
@testable import PebbleVoice
import Testing

/// A microphone and recognizer the tests drive. Every start keeps its own
/// way to answer, so a test can answer for a listen long gone, as the
/// system's recognizer does after a cancel.
@MainActor
final class FakeHearing: Hearing {
    var hearsOnDevice = true
    private(set) var answers: [@Sendable (String?, Bool) -> Void] = []
    private(set) var stops = 0
    private(set) var audioEnds = 0

    func start(answer: @escaping @Sendable (String?, Bool) -> Void) throws {
        answers.append(answer)
    }

    func endAudio() {
        audioEnds += 1
    }

    func stop() {
        stops += 1
    }

    /// The recognizer of listen `index`, counting from zero, says `words`.
    func answer(_ index: Int, _ words: String?, done: Bool = false) {
        answers[index](words, done)
    }
}

/// The waits for last words, each held until the test lets it go.
@MainActor
final class HeldPauses {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0

    func pause() async {
        await withCheckedContinuation { waiting.append($0); count += 1 }
    }

    func letGo(_ index: Int) {
        waiting[index].resume()
    }
}

/// What one listen was told: the words it heard and whether it ended.
@MainActor
final class Heard {
    private(set) var words: [String] = []
    private(set) var ends = 0

    func start(on speech: DeviceSpeech) throws {
        try speech.start(ListenRequest(onDeviceOnly: true), heard: { self.words.append($0) },
                         ended: { self.ends += 1 })
    }
}

/// Lets every answer already sent reach the main actor.
@MainActor
func answersArrive() async {
    await Task { @MainActor in }.value
    try? await Task.sleep(for: .milliseconds(50))
    await Task { @MainActor in }.value
}

@MainActor
struct DeviceSpeechTests {
    @Test func aCancelStopsTheRecognizerAndDropsItsLateAnswers() async throws {
        let hearing = FakeHearing()
        let speech = DeviceSpeech(hearing: hearing)
        let first = Heard()
        try first.start(on: speech)
        hearing.answer(0, "hello")
        #expect(await waitUntil { first.words == ["hello"] })
        let stopsBefore = hearing.stops
        speech.cancel()
        #expect(hearing.stops == stopsBefore + 1, "a cancel stops the recognition")
        // The recognizer still says its last words, and then that it ended.
        hearing.answer(0, "hello there", done: true)
        await answersArrive()
        #expect(first.words == ["hello"])
        #expect(first.ends == 0)
        #expect(await speech.finish() == nil)
    }

    @Test func aLateAnswerFromTheListenBeforeNeverReachesTheNextOne() async throws {
        let hearing = FakeHearing()
        let speech = DeviceSpeech(hearing: hearing)
        let first = Heard()
        try first.start(on: speech)
        hearing.answer(0, "old words")
        #expect(await waitUntil { first.words == ["old words"] })
        // Slid away and held again at once: the finger is down on the new listen.
        speech.cancel()
        let second = Heard()
        try second.start(on: speech)
        hearing.answer(0, "old words, final", done: true)
        hearing.answer(1, "new")
        #expect(await waitUntil { second.words == ["new"] })
        await answersArrive()
        #expect(second.words == ["new"], "the old listen's words never show in the new one")
        #expect(second.ends == 0, "the old listen's end never ends the new one")
        #expect(first.words == ["old words"])
        // The new listen still hears, and its own end still ends it.
        hearing.answer(1, "new words", done: true)
        #expect(await waitUntil { second.ends == 1 })
        #expect(second.words == ["new", "new words"])
    }

    @Test func theWaitForTheLastListensWordsNeverEndsTheNextOne() async throws {
        let hearing = FakeHearing()
        let pauses = HeldPauses()
        let speech = DeviceSpeech(hearing: hearing, pause: { await pauses.pause() })
        try Heard().start(on: speech)
        hearing.answer(0, "first")
        let firstFinish = Task { await speech.finish() }
        #expect(await waitUntil { pauses.count == 1 })
        hearing.answer(0, "first words", done: true)
        #expect(await firstFinish.value == "first words")

        try Heard().start(on: speech)
        hearing.answer(1, "second")
        let secondFinish = Task { await speech.finish() }
        #expect(await waitUntil { pauses.count == 2 })
        // The first listen's wait runs out while the second waits for its last words.
        pauses.letGo(0)
        await answersArrive()
        hearing.answer(1, "second words", done: true)
        #expect(await secondFinish.value == "second words")
        pauses.letGo(1)
    }

    @Test func aFinishCancelledAndFollowedByANewListenLeavesTheNewOneGoing() async throws {
        let hearing = FakeHearing()
        let pauses = HeldPauses()
        let speech = DeviceSpeech(hearing: hearing, pause: { await pauses.pause() })
        try Heard().start(on: speech)
        let finishing = Task { await speech.finish() }
        #expect(await waitUntil { hearing.audioEnds == 1 && pauses.count == 1 })
        speech.cancel()
        let next = Heard()
        try next.start(on: speech)
        _ = await finishing.value
        hearing.answer(1, "still here")
        #expect(await waitUntil { next.words == ["still here"] })
        pauses.letGo(0)
    }
}
