import Foundation
import GuardScan
import SourceScan
import Testing

/// Speech is heard on the device only, and nothing heard is kept. The rules
/// are `SpeechGate` in GuardScan, and what each must catch is in
/// `GuardWrongCaseTests`.
struct SpeechSweepTests {
    /// PERMANENT GUARD. Every recognition request in PebbleKit and the app
    /// asks for on-device recognition and is never turned back, only the
    /// adapter names the Speech framework, and no voice file names anything
    /// that writes to disk or a log.
    @Test func speechIsHeardOnTheDeviceOnlyAndNeverKept() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let sources = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App"))
        let files = sources + app.map { ("App/\($0.name)", $0.text) }
        #expect(files.count > 20)
        // The adapter is still where the guard looks, and still makes a request.
        let adapter = try #require(files.first { $0.name == SpeechGate.adapterFile }, "the adapter moved")
        #expect(adapter.text.contains("SFSpeechAudioBufferRecognitionRequest()"))
        for file in SpeechGate.voiceFiles {
            #expect(files.contains { $0.name == file }, "\(file) moved")
        }
        for file in files {
            for problem in SpeechGate.problems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }
}
