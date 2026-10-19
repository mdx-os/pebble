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
@MainActor
public final class DeviceSpeech: SpeechListening {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var heard: (@MainActor (String) -> Void)?
    private var ended: (@MainActor () -> Void)?
    private var finishing: CheckedContinuation<String?, Never>?

    /// How long `finish` waits for the recognizer's last words.
    static let lastWordsWait: Duration = .seconds(1.5)

    /// Listens in the person's own language.
    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    public var hearsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
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
        guard listen.onDeviceOnly, let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw Refused.notOnDevice
        }
        tearDown()
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
            tearDown()
            throw Refused.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.feed(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }
        self.request = request
        self.heard = heard
        self.ended = ended
        latest = ""
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(to: self))
    }

    public func finish() async -> String? {
        guard task != nil else { return nil }
        stopHearing()
        request?.endAudio()
        let words = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            finishing = done
            // A recognizer that never says it's final still lets the words go.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.lastWordsWait)
                self?.settle()
            }
        }
        tearDown()
        return words
    }

    public func cancel() {
        task?.cancel()
        settle()
        tearDown()
    }

    /// The microphone's sound, straight into the request. Made here, away
    /// from the main actor, since the audio thread calls it.
    private nonisolated static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    /// The recognizer's answers, brought back to the main actor as plain words.
    private nonisolated static func results(to listener: DeviceSpeech)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak listener] result, error in
            let words = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in listener?.recognized(words, done: done) }
        }
    }

    private func recognized(_ words: String?, done: Bool) {
        if let words, !words.isEmpty {
            latest = words
            if finishing == nil { heard?(words) }
        }
        guard done else { return }
        if finishing != nil {
            settle()
        } else if task != nil {
            let ended = self.ended
            tearDown()
            ended?()
        }
    }

    /// Gives `finish` the last words, once.
    private func settle() {
        guard let done = finishing else { return }
        finishing = nil
        done.resume(returning: latest.isEmpty ? nil : latest)
    }

    private func stopHearing() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func tearDown() {
        stopHearing()
        task = nil
        request = nil
        heard = nil
        ended = nil
        latest = ""
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    enum Refused: Error {
        case notOnDevice
        case noMicrophone
    }
}
