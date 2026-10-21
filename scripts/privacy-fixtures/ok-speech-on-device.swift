// into: Packages/PebbleKit/Sources/PebbleVoice
// filename: DeviceSpeech.swift
// expect: ok
import Speech

func hear(_ recognizer: SFSpeechRecognizer) -> SFSpeechRecognitionTask {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    return recognizer.recognitionTask(with: request) { _, _ in }
}
