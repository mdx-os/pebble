// into: Packages/PebbleKit/Sources/PebbleCore
// expect: ok
import Speech

func fixtureListen(_ request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechRecognizer? {
    request.requiresOnDeviceRecognition = true
    return SFSpeechRecognizer()
}
