// into: Packages/PebbleKit/Sources/PebbleVoice
// filename: DeviceSpeech.swift
// expect: speech recognition outside the reviewed helper
func hear() {
    let local = SFSpeechAudioBufferRecognitionRequest()
    local.requiresOnDeviceRecognition = true
    SFSpeechRecognizer()?.recognitionTask(with: local) { _, _ in }
}
func unrestricted() {
    let other = SFSpeechAudioBufferRecognitionRequest()
    SFSpeechRecognizer()?.recognitionTask(with: other) { _, _ in }
}
