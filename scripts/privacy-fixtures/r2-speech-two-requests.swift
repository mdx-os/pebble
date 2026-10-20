// into: Packages/PebbleKit/Sources/PebbleCore
// expect: speech recognition outside the reviewed helper
import Speech
func listen() {
 let recognizer = SFSpeechRecognizer()
 let local = SFSpeechAudioBufferRecognitionRequest()
 local.requiresOnDeviceRecognition = true
 recognizer?.recognitionTask(with: local) { _, _ in }
 let unrestricted = SFSpeechAudioBufferRecognitionRequest()
 recognizer?.recognitionTask(with: unrestricted) { _, _ in }
}
