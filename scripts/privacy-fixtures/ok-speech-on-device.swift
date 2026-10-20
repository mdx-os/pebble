// into: Packages/PebbleKit/Sources/PebbleModel
// filename: OnDeviceSpeech.swift
// expect: ok
import Speech

func recognizeOnDevice(_ request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechRecognizer? {
    request.requiresOnDeviceRecognition = true
    return SFSpeechRecognizer()
}
