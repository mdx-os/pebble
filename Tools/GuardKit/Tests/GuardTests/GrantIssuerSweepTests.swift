import Foundation
import GuardScan
import SourceScan
import Testing

/// Only the question sheet's answer makes a grant. The rule is
/// `GrantIssuerGate` in GuardScan, and what it must catch is in
/// `GuardWrongCaseTests`.
struct GrantIssuerSweepTests {
    /// PERMANENT GUARD. No source in PebbleKit or the app names
    /// `GrantIssuer` but the grants' own file and the question sheet's, so
    /// nothing else, a chat, a model's reply, a note or a task step, can
    /// make, widen or extend a grant.
    @Test func onlyTheQuestionSheetMakesGrants() throws {
        let root = SwiftSource.repositoryRoot(from: #filePath)
        let sources = try SwiftSource.files(under: root.appendingPathComponent("Packages/PebbleKit/Sources"))
        let app = try SwiftSource.files(under: root.appendingPathComponent("App"))
        let files = sources + app.map { ("App/\($0.name)", $0.text) }
        #expect(files.count > 20)
        for allowed in GrantIssuerGate.allowedFiles {
            #expect(files.contains { $0.name == allowed && $0.text.contains("GrantIssuer") }, "\(allowed) moved")
        }
        for file in files {
            for problem in GrantIssuerGate.problems(in: SyntaxSource.shared(file.text), file: file.name) {
                Issue.record(Comment(rawValue: problem.report(in: file.name)))
            }
        }
    }
}
