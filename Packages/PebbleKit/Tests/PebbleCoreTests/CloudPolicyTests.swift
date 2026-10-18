import Foundation
import PebbleCore
import Testing

/// The cloud policy the owner decided, held in one value, and every place
/// that says it saying the same words.
struct CloudPolicyTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// MDx runs it, it keeps no bodies, only counts for 7 days, and
    /// signing in sends Apple's anonymous ID and a per-device key, nothing
    /// more. A field added to sign-in, an email or a name among them,
    /// fails here.
    @Test func thePolicyIsTheOneDecided() {
        let policy = CloudPolicy.current
        #expect(policy.version == "mdx-zero-retention-1")
        #expect(policy.version == CloudPolicy.currentVersion)
        #expect(policy.runBy == "MDx")
        #expect(policy.keepsWhatIsSent == false)
        #expect(policy.countsKeptForDays == 7)
        #expect(policy.signInFields == ["appleUser", "deviceKey"])
    }

    /// The words of this version, word for word. Changing them means a new
    /// version, in `CloudPolicy`, `Config/Cloud.xcconfig` and docs/CLOUD.md.
    @Test func theLinesArePinnedToTheirVersion() {
        #expect(CloudPolicy.currentVersion == "mdx-zero-retention-1")
        #expect(CloudPolicy.current.lines == [
            "Your messages go to a server MDx runs itself. MDx doesn't hand them to anyone else.",
            "MDx doesn't save what you send. It keeps only a count of messages and problems, for 7 days.",
            "Signing in sends just two things: the anonymous ID Apple gives this app for you, and a random key I made for signing in. Never your email or your name.",
            "Turning this off or using Forget everything erases that ID and key, so I sign in fresh next time.",
        ])
        #expect(CloudPolicy.current.previewLine
            == "This goes to MDx's own server. MDx doesn't save it, and keeps only a count of messages and problems for 7 days.")
    }

    /// The lines follow the policy's values, so a change to who runs it or
    /// how long counts are kept changes what the person reads.
    @Test func theLinesSayWhatThePolicySays() {
        let other = CloudPolicy(version: "x", runBy: "Example", keepsWhatIsSent: false,
                                countsKeptForDays: 3, signInFields: ["appleUser", "deviceKey"])
        #expect(other.whoLine.contains("a server Example runs itself"))
        #expect(other.keepsLine.contains("for 3 days"))
        #expect(other.previewLine.contains("Example's own server"))
        #expect(other.previewLine.contains("for 3 days"))
    }

    /// The setting, the turn on question and the preview read their policy
    /// words from `CloudPolicy`, and the dash and device checks see them.
    @Test func theCloudWordsReadThePolicy() {
        #expect(CloudWords.policyLines == CloudPolicy.current.lines)
        #expect(CloudWords.previewPolicy == CloudPolicy.current.previewLine)
        for line in [CloudPolicy.current.whoLine, CloudPolicy.current.keepsLine, CloudPolicy.current.signInLine] {
            #expect(CloudWords.askPoints.contains(line), "\(line)")
        }
        for line in CloudPolicy.current.lines + [CloudPolicy.current.previewLine, CloudWords.policyTitle] {
            #expect(CloudWords.all.contains(line), "\(line)")
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(line)")
        }
    }

    /// The same short summary, word for word, in docs/CLOUD.md, the README
    /// and AGENTS.md, and every line the app shows quoted in docs/CLOUD.md.
    @Test func theDocsSayTheSameInTheSameWords() throws {
        let policy = CloudPolicy.current
        let summary = "\(policy.runBy) runs the cloud service itself. It stores no message bodies, only counts of requests and errors, kept for \(policy.countsKeptForDays) days. Sign-in sends only Apple's anonymous user ID and a key made on the device, never an email or a name."
        func read(_ path: String) throws -> String {
            try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
        }
        let cloud = try read("docs/CLOUD.md")
        for path in ["docs/CLOUD.md", "README.md", "AGENTS.md"] {
            #expect(try read(path).contains(summary), "\(path)")
        }
        for path in ["README.md", "AGENTS.md"] {
            #expect(try read(path).contains("docs/CLOUD.md"), "\(path)")
        }
        #expect(cloud.contains("Policy version: `\(policy.version)`"))
        #expect(cloud.contains("`PEBBLE_CLOUD_POLICY = \(policy.version)`"))
        for line in policy.lines {
            #expect(cloud.contains("- \"\(line)\""), "\(line)")
        }
        #expect(cloud.contains("In the preview: \"\(policy.previewLine)\""))
        for field in policy.signInFields {
            #expect(cloud.contains("- `\(field)`: "), "\(field)")
        }
        for dash in ["\u{2014}", "\u{2013}"] {
            #expect(!cloud.contains(dash))
        }
    }
}
