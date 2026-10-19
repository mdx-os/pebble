import Foundation
import Observation

/// Where the person stands on the two things talking needs: the microphone,
/// and turning speech into words.
public enum SpeechAccess: Equatable, Sendable {
    case allowed
    /// One of the two hasn't been asked yet.
    case notAsked
    case microphoneDeclined
    case speechDeclined
}

/// What listening is asked to do. Words are heard only on the device:
/// `VoiceCapture` makes every request with `onDeviceOnly` and an adapter
/// refuses one without it, so there is never a fallback to a server.
public struct ListenRequest: Equatable, Sendable {
    public let onDeviceOnly: Bool

    public init(onDeviceOnly: Bool) {
        self.onDeviceOnly = onDeviceOnly
    }
}

/// The microphone and the recognizer, behind one door. `DeviceSpeech` in
/// PebbleVoice is the real one; tests drive a fake. Nothing that passes
/// through here is written anywhere: the words reach only `heard` and
/// `finish`, and from there only the composer.
@MainActor
public protocol SpeechListening: AnyObject {
    /// The person's answers so far, without asking anything.
    var access: SpeechAccess { get }
    /// Asks the system's questions not yet answered, the microphone first,
    /// and gives where the person stands after.
    func askForAccess() async -> SpeechAccess
    /// True when words can be heard on the device in the person's language.
    var hearsOnDevice: Bool { get }
    /// Starts listening. `heard` gets every word so far each time they
    /// change. `ended` is called when listening stops on its own, never
    /// after `finish` or `cancel`.
    func start(_ request: ListenRequest, heard: @escaping @MainActor (String) -> Void,
               ended: @escaping @MainActor () -> Void) throws
    /// Stops the microphone, waits a moment for the last words and gives
    /// them, or nil when there were none.
    func finish() async -> String?
    /// Stops at once and lets go of everything heard.
    func cancel()
}

/// Why talking can't happen just now.
public enum VoiceUnavailable: Equatable, Sendable {
    case microphoneDeclined
    case speechDeclined
    /// The device can't hear the person's language by itself, and words are
    /// never sent elsewhere to be heard.
    case notOnDevice
    case couldNotStart

    public var line: String {
        switch self {
        case .microphoneDeclined: VoiceWords.microphoneDeclined
        case .speechDeclined: VoiceWords.speechDeclined
        case .notOnDevice: VoiceWords.notOnDevice
        case .couldNotStart: VoiceWords.couldNotStart
        }
    }
}

/// Asks from outside the app to start listening, as the Talk shortcut and
/// the Action Button do. The composer in front takes it once it shows.
@MainActor
@Observable
public final class TalkRequests {
    public static let shared = TalkRequests()
    /// How long an ask waits for a composer, so a shortcut run long ago
    /// never turns the microphone on later by surprise.
    public static let freshFor: TimeInterval = 60

    public private(set) var waiting: Date?

    public init() {}

    public func ask(at now: Date = Date()) {
        waiting = now
    }

    /// True once for each fresh ask; a stale one is let go.
    public func take(now: Date = Date()) -> Bool {
        guard let asked = waiting else { return false }
        waiting = nil
        return now.timeIntervalSince(asked) <= Self.freshFor
    }
}

/// Talking to the agent in one gesture. Hold to listen, with the words
/// showing in the composer as they are heard; let go to send them as a
/// normal message; slide away to send nothing. For VoiceOver and the Talk
/// shortcut, a tap starts it and a tap sends.
///
/// Asks for the microphone and speech only when the person first holds
/// the button, never before. Nothing heard is kept: the words live in the
/// composer's draft and, once sent, in the chat, as typed words do. A
/// release with nothing heard sends nothing.
@MainActor
@Observable
public final class VoiceCapture {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The system is asking for the microphone or speech.
        case asking
        case listening
        /// Let go: the last words are coming in before they are sent.
        case sending
        /// Slid away or stopped: nothing was sent.
        case cancelled
        case unavailable(VoiceUnavailable)
    }

    /// How listening ends: by letting go, or by a second tap.
    public enum Mode: Equatable, Sendable {
        case hold, tap
    }

    public private(set) var phase: Phase = .idle
    public private(set) var mode: Mode = .hold
    /// The words heard so far, while listening. Empty once it ends.
    public private(set) var heard = ""
    /// The composer listening now, or the one a line about the last try
    /// belongs to, by its identifier. Nil when idle.
    public private(set) var owner: String?
    public let requests: TalkRequests

    private let listener: any SpeechListening
    private var target: Target?
    /// Let go while the system was asking, as its question takes the touch.
    private var letGoWhileAsking = false
    /// Goes up with every start and every stop, so a late answer can tell
    /// it no longer counts.
    private var generation = 0

    /// Where the words go: the draft as it was, how to show words in it,
    /// and how to send them.
    private struct Target {
        let before: String
        let write: (String) -> Void
        let send: (String) -> Void
    }

    public init(listener: any SpeechListening, requests: TalkRequests = .shared) {
        self.listener = listener
        self.requests = requests
    }

    public var isActive: Bool {
        phase == .asking || phase == .listening || phase == .sending
    }

    /// Starts listening for the composer `owner`. `draft` is what is already
    /// written, kept in front of the words heard; `write` shows the words in
    /// the composer, and `send` sends the message.
    public func begin(_ mode: Mode, owner: String, draft: String, write: @escaping (String) -> Void,
                      send: @escaping (String) -> Void) async {
        guard !isActive else { return }
        generation += 1
        let started = generation
        self.mode = mode
        self.owner = owner
        heard = ""
        letGoWhileAsking = false
        target = Target(before: draft, write: write, send: send)
        // Checked before any question, so nobody is asked for something
        // that can't work here.
        guard listener.hearsOnDevice else { return stop(.unavailable(.notOnDevice)) }
        var access = listener.access
        if access == .notAsked {
            phase = .asking
            access = await listener.askForAccess()
            guard started == generation else { return }
        }
        switch access {
        case .allowed: break
        case .microphoneDeclined: return stop(.unavailable(.microphoneDeclined))
        case .speechDeclined: return stop(.unavailable(.speechDeclined))
        case .notAsked: return stop(.unavailable(.couldNotStart))
        }
        // Holding, the question took the touch; the person holds again.
        if mode == .hold, letGoWhileAsking { return stop(.idle) }
        do {
            try listener.start(ListenRequest(onDeviceOnly: true), heard: { [weak self] words in
                guard let self, started == self.generation, self.phase == .listening else { return }
                self.heard = words
                self.target?.write(self.message(with: words))
            }, ended: { [weak self] in
                guard let self, started == self.generation, self.phase == .listening else { return }
                // Stopped on its own: the words stay in the composer to
                // send or change, and nothing is sent.
                self.stop(.idle)
            })
        } catch {
            return stop(.unavailable(.couldNotStart))
        }
        phase = .listening
    }

    /// Let go, or the second tap: sends what was heard, if anything was.
    public func release() async {
        if phase == .asking {
            letGoWhileAsking = true
            return
        }
        guard phase == .listening, let target else { return }
        let started = generation
        phase = .sending
        let last = await listener.finish()
        guard started == generation else { return }
        let words = (last ?? heard).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            target.write(target.before)
            return stop(.idle)
        }
        let message = message(with: words)
        // In the draft first, so a send that can't go yet leaves the words there.
        target.write(message)
        stop(.idle)
        target.send(message)
    }

    /// Slid away, or Don't send: nothing is sent, and the draft is as it was.
    public func cancel() {
        guard isActive, let target else { return }
        if phase == .listening || phase == .sending { listener.cancel() }
        target.write(target.before)
        stop(.cancelled)
    }

    /// The same, only for the composer `owner`, as when it goes away.
    public func cancel(owner: String) {
        guard self.owner == owner else { return }
        cancel()
    }

    /// Back to idle after an unavailable line or a cancel has been seen.
    public func settle() {
        guard !isActive else { return }
        owner = nil
        phase = .idle
    }

    /// Takes a waiting Talk shortcut, if one is fresh, and starts listening
    /// with a tap to send.
    @discardableResult
    public func answerShortcut(owner: String, draft: String, now: Date = Date(), write: @escaping (String) -> Void,
                               send: @escaping (String) -> Void) async -> Bool {
        guard !isActive, requests.take(now: now) else { return false }
        await begin(.tap, owner: owner, draft: draft, write: write, send: send)
        return true
    }

    private func message(with words: String) -> String {
        guard let target else { return words }
        let before = target.before.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return target.before }
        return before.isEmpty ? words : before + " " + words
    }

    private func stop(_ next: Phase) {
        generation += 1
        target = nil
        heard = ""
        letGoWhileAsking = false
        // A line about what happened stays with the composer it happened on.
        if next == .idle { owner = nil }
        phase = next
    }
}

/// The words for talking to the agent. docs/VOICE.md.
public enum VoiceWords {
    public static let talkTitle = "Talk"
    public static let holdHint = "Hold to talk, and let go to send."
    public static let tapHint = "Double tap to start listening, and double tap again to send."
    public static let listening = "I'm listening."
    public static let letGoToSend = "Let go to send, or slide away to cancel."
    public static let letGoToCancel = "Let go, and I won't send it."
    public static let tapToSend = "Tap Send when you're done."
    public static let sendTitle = "Send"
    public static let dontSendTitle = "Don't send"
    public static let gettingLastWords = "Getting your last words."
    public static let cancelled = "Okay, I didn't send anything."
    public static let microphoneDeclined = "I can't hear you without the microphone. "
        + "If you'd like to talk, you can allow it in Settings. Typing works just as before."
    public static let speechDeclined = "I can't turn what you say into words without speech recognition. "
        + "If you'd like to talk, you can allow it in Settings. Typing works just as before."
    public static let notOnDevice = "Sorry, I can't understand speech in your language here yet, "
        + "and I won't send your voice anywhere else to be understood. Typing works just as before."
    public static let couldNotStart = "Sorry, I couldn't start listening just now. Try again in a moment, or type instead."

    public static let all: [String] = [
        talkTitle, holdHint, tapHint, listening, letGoToSend, letGoToCancel, tapToSend, sendTitle, dontSendTitle,
        gettingLastWords, cancelled, microphoneDeclined, speechDeclined, notOnDevice, couldNotStart,
    ]
}
