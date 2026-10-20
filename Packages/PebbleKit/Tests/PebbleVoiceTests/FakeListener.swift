import Foundation
import PebbleCore

/// A recognizer the tests drive: what the person has allowed, what the
/// device can hear, and the words it hears, each said by the test.
@MainActor
final class FakeListener: SpeechListening {
    var access: SpeechAccess
    /// Where the person stands once the questions are answered.
    var answer: SpeechAccess
    var hearsOnDevice = true
    var startFails = false
    /// The words `finish` gives, as the recognizer's last answer.
    var lastWords: String?
    /// While true, the questions wait until `answerQuestions` is called.
    var holdsQuestions = false

    private(set) var asked = 0
    private(set) var requests: [ListenRequest] = []
    private(set) var finishes = 0
    private(set) var cancels = 0
    private var heard: (@MainActor (String) -> Void)?
    private var ended: (@MainActor () -> Void)?
    private var questions: CheckedContinuation<Void, Never>?

    init(access: SpeechAccess = .allowed, answer: SpeechAccess = .allowed) {
        self.access = access
        self.answer = answer
    }

    func askForAccess() async -> SpeechAccess {
        asked += 1
        if holdsQuestions {
            await withCheckedContinuation { questions = $0 }
        }
        access = answer
        return access
    }

    func answerQuestions() {
        questions?.resume()
        questions = nil
    }

    var isAsking: Bool { questions != nil }

    func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
               ended: @escaping @MainActor () -> Void) throws {
        requests.append(request)
        if startFails { throw CocoaError(.featureUnsupported) }
        self.heard = heard
        self.ended = ended
    }

    func finish() async -> String? {
        finishes += 1
        heard = nil
        ended = nil
        return lastWords
    }

    func cancel() {
        cancels += 1
        heard = nil
        ended = nil
    }

    /// The recognizer hears `words`, all of them so far.
    func say(_ words: String) {
        heard?(words)
    }

    /// Listening stops by itself, as at the recognizer's time limit.
    func stopOnItsOwn() {
        let ended = self.ended
        heard = nil
        self.ended = nil
        ended?()
    }
}

/// A recognizer whose last words wait until the test gives them.
@MainActor
final class SlowFinishListener: SpeechListening {
    let access = SpeechAccess.allowed
    let hearsOnDevice = true
    private var last: CheckedContinuation<String?, Never>?

    func askForAccess() async -> SpeechAccess { access }

    func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
               ended: @escaping @MainActor () -> Void) throws {}

    func finish() async -> String? {
        await withCheckedContinuation { last = $0 }
    }

    /// Lets the wait end even after a cancel, as a late answer would.
    func cancel() {}

    func giveLastWords(_ words: String) {
        last?.resume(returning: words)
        last = nil
    }
}

/// The composer, as the capture sees it: its draft, and what it sent.
@MainActor
final class FakeComposer {
    var draft: String
    private(set) var sent: [String] = []
    /// Every value the draft took, in order.
    private(set) var shown: [String] = []

    init(draft: String = "") {
        self.draft = draft
    }

    func write(_ text: String) {
        draft = text
        shown.append(text)
    }

    func send(_ text: String) {
        sent.append(text)
        draft = ""
    }
}

extension VoiceCapture {
    func begin(_ mode: Mode, on composer: FakeComposer) async {
        await begin(mode, owner: "composer", draft: composer.draft,
                    write: { composer.write($0) }, send: { composer.send($0) })
    }
}

/// Waits, with a generous limit, until `condition` holds. AGENTS.md: a
/// wait never goes without a limit, so a regression fails instead of hanging.
@MainActor
func waitUntil(_ condition: () -> Bool, limit: Duration = .seconds(60)) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: limit)
    while !condition() {
        if clock.now > end { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
