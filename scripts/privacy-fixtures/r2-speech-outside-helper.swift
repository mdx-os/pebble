// into: Packages/PebbleKit/Sources/PebbleModel
// filename: OnDeviceSpeech.swift
// expect: speech recognition outside the reviewed helper
func recognizeOnDevice() {
    let local = SFSpeechAudioBufferRecognitionRequest()
    local.requiresOnDeviceRecognition = true
    SFSpeechRecognizer()?.recognitionTask(with: local) { _, _ in }
}
func unrestricted() {
    let other = SFSpeechAudioBufferRecognitionRequest()
    SFSpeechRecognizer()?.recognitionTask(with: other) { _, _ in }
}
