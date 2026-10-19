@preconcurrency import AVFoundation
import PebbleCore
@preconcurrency import Speech

/// The microphone and the system's recognizer, heard on the device only.
///
/// Every recognition request here asks for on-device recognition, and a
/// listen asked for any other way is refused, so speech is never sent to a
/// server, not even when the device can't hear the language: then
/// `hearsOnDevice` is false and nothing starts. `SpeechGate` in
/// Tools/GuardKit keeps every request this way, and keeps the recognizer in
/// this one file.
///
/// No audio is recorded: the microphone's sound goes straight to the
/// recognizer and nowhere else. The words go only to `heard` and `finish`,
/// never to a file, a log or a cache.
///
/// Each listen has its own number. The recognizer can answer late, after a
/// cancel and even after the next listen has begun, so an answer, or the
/// wait for the last words, that isn't for the listen going now is dropped.
@MainActor
public final class DeviceSpeech: SpeechListening {
    private let hearing: any Hearing
    /// Waits for the recognizer's last words, `lastWordsWait` unless a test says.
    private let pause: @MainActor () async -> Void
    /// The listen going now. Goes up with every stop.
    private var listen = 0
    private var listening = false
    private var latest = ""
    private var heard: (@MainActor (String) -> Void)?
    private var ended: (@MainActor () -> Void)?
    private var finishing: CheckedContinuation<String?, Never>?

    /// How long `finish` waits for the recognizer's last words.
    static let lastWordsWait: Duration = .seconds(1.5)

    /// Listens in the person's own language.
    public convenience init(locale: Locale = .current) {
        self.init(hearing: DeviceHearing(locale: locale))
    }

    init(hearing: any Hearing, pause: @escaping @MainActor () async -> Void = {
        try? await Task.sleep(for: DeviceSpeech.lastWordsWait)
    }) {
        self.hearing = hearing
        self.pause = pause
    }

    public var hearsOnDevice: Bool {
        hearing.hearsOnDevice
    }

    public var access: SpeechAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .denied: return .microphoneDeclined
        default: return .notAsked
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .speechDeclined
        }
    }

    public func askForAccess() async -> SpeechAccess {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        if AVAudioApplication.shared.recordPermission == .granted,
           SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
            }
        }
        return access
    }

    public func start(_ listen: ListenRequest, heard: @escaping @MainActor (String) -> Void,
                      ended: @escaping @MainActor () -> Void) throws {
        guard listen.onDeviceOnly, hearing.hearsOnDevice else {
            throw Refused.notOnDevice
        }
        tearDown()
        let current = self.listen
        do {
            try hearing.start(answer: Self.answers(to: self, for: current))
        } catch {
            tearDown()
            throw error
        }
        self.heard = heard
        self.ended = ended
        latest = ""
        listening = true
    }

    public func finish() async -> String? {
        guard listening else { return nil }
        let current = listen
        hearing.endAudio()
        let words = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            finishing = done
            // A recognizer that never says it's final still lets the words go.
            Task { @MainActor [weak self, pause] in
                await pause()
                self?.settle(current)
            }
        }
        // A cancel while waiting has let go already, and a new listen may have begun since.
        if current == listen { tearDown() }
        return words
    }

    public func cancel() {
        settle(listen)
        tearDown()
    }

    /// The recognizer's answers for listen `current`, brought back to the
    /// main actor. Made here, away from the main actor, since the
    /// recognizer answers on its own queue.
    private nonisolated static func answers(to listener: DeviceSpeech, for current: Int)
        -> @Sendable (String?, Bool) -> Void {
        { [weak listener] words, done in
            Task { @MainActor in listener?.recognized(words, done: done, for: current) }
        }
    }

    private func recognized(_ words: String?, done: Bool, for current: Int) {
        // An answer for a listen that has stopped, or for one before this one.
        guard current == listen, listening else { return }
        if let words, !words.isEmpty {
            latest = words
            if finishing == nil { heard?(words) }
        }
        guard done else { return }
        if finishing != nil {
            settle(current)
        } else {
            let ended = self.ended
            tearDown()
            ended?()
        }
    }

    /// Gives `finish` the last words of listen `current`, once.
    private func settle(_ current: Int) {
        guard current == listen, let done = finishing else { return }
        finishing = nil
        done.resume(returning: latest.isEmpty ? nil : latest)
    }

    private func tearDown() {
        hearing.stop()
        listen += 1
        listening = false
        heard = nil
        ended = nil
        latest = ""
    }

    enum Refused: Error {
        case notOnDevice
        case noMicrophone
    }
}

/// The microphone and the recognizer, one listen at a time, as
/// `DeviceSpeech` drives them. Tests put a fake here to answer late.
@MainActor
protocol Hearing: AnyObject {
    var hearsOnDevice: Bool { get }
    /// Starts the microphone and a recognition. `answer` gets every word so
    /// far, and whether the recognizer is done, on any queue, until `stop`
    /// and sometimes after.
    func start(answer: @escaping @Sendable (String?, Bool) -> Void) throws
    /// Stops the microphone; the recognizer goes on to its last words.
    func endAudio()
    /// Stops the microphone and the recognition at once.
    func stop()
}

/// The real microphone and recognizer.
@MainActor
final class DeviceHearing: Hearing {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var hearsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    func start(answer: @escaping @Sendable (String?, Bool) -> Void) throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw DeviceSpeech.Refused.notOnDevice
        }
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone to hear from, as on a device with none attached.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw DeviceSpeech.Refused.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feed(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(to: answer))
    }

    func endAudio() {
        stopHearing()
        request?.endAudio()
    }

    func stop() {
        stopHearing()
        // The recognizer stops at once. What it still says after is for no
        // listen, and `DeviceSpeech` drops it.
        task?.cancel()
        task = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The microphone's sound, straight into the request. Made here, away
    /// from the main actor, since the audio thread calls it.
    private nonisolated static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    /// The recognizer's answers as plain words, and whether it is done.
    private nonisolated static func results(to answer: @escaping @Sendable (String?, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            answer(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }

    private func stopHearing() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
