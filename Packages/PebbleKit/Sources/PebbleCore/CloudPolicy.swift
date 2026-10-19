import Foundation

/// What the cloud service promises, in one place: who runs it, what it
/// keeps and for how long, and what signing in sends. The cloud setting,
/// the turn on question and the preview read their lines from here, and
/// docs/CLOUD.md says the same in the same words.
///
/// A build that ships may reach the cloud only when its settings name this
/// very policy (`PEBBLE_CLOUD_POLICY` equal to `currentVersion`; see
/// `scripts/release-endpoint-check.sh` and `CloudEndpoint`). Any change to
/// what the service does, or to the lines below, gets a new version, so a
/// build checked against the old one can't show words that are no longer
/// true.
public struct CloudPolicy: Sendable, Equatable {
    /// The version every check compares against. The Release check reads
    /// this line from the source, so keep it on one line, as it is.
    public static let currentVersion = "mdx-zero-retention-2"

    public let version: String
    /// Who runs the server: the people who make the app, not a third party.
    public let runBy: String
    /// False: the words sent are never written down by the service.
    public let keepsWhatIsSent: Bool
    /// How long the service keeps its only records, counts of messages and
    /// of problems, with nothing from any message in them.
    public let countsKeptForDays: Int
    /// The names of the values signing in sends, and nothing else: Apple's
    /// identity token, the one-time nonce made for that one sign-in, and a
    /// random key made on this device. No email and no name, ever. The
    /// server checks the token once, keeps only Apple's anonymous ID from
    /// it and the key, and throws the token away.
    public let signInFields: [String]

    public init(version: String, runBy: String, keepsWhatIsSent: Bool, countsKeptForDays: Int, signInFields: [String]) {
        self.version = version
        self.runBy = runBy
        self.keepsWhatIsSent = keepsWhatIsSent
        self.countsKeptForDays = countsKeptForDays
        self.signInFields = signInFields
    }

    public static let current = CloudPolicy(
        version: currentVersion,
        runBy: "MDx",
        keepsWhatIsSent: false,
        countsKeptForDays: 7,
        signInFields: ["appleToken", "nonce", "deviceKey"]
    )

    /// True when the server takes a message only from a device signed in
    /// to it: whenever signing in sends anything at all. The current
    /// policy does, so with no session and no sign-in hop in the preview,
    /// no message goes (`CloudModel`).
    public var needsSignIn: Bool { !signInFields.isEmpty }

    /// Who runs it, said plainly.
    public var whoLine: String {
        "Your messages go to a server \(runBy) runs itself. \(runBy) doesn't hand them to anyone else."
    }

    /// What it keeps, and for how long.
    public var keepsLine: String {
        "\(runBy) doesn't save what you send. It keeps only a count of messages and problems, for \(countsKeptForDays) days."
    }

    /// What signing in sends. Values are covered in the preview, so this
    /// says what they are.
    public var signInLine: String {
        "Signing in sends just three things: a sign-in token from Apple, a one-time code I made for it, and a random key I made for signing in. Never your email or your name."
    }

    /// What the server does with them.
    public var tokenLine: String {
        "\(runBy) checks Apple's token once and then throws it away. It keeps only the anonymous ID Apple gives this app for you, and that key."
    }

    /// What turning the cloud off and Forget everything do to sign-in.
    public var forgetLine: String {
        "Turning this off or using Forget everything erases my copy of that key, so I sign in fresh next time with a new one."
    }

    /// The policy as the cloud setting shows it, in order.
    public var lines: [String] { [whoLine, keepsLine, signInLine, tokenLine, forgetLine] }

    /// What the preview says over a sign-in hop, whose values are covered,
    /// so the person knows what goes under the dots.
    public var previewSignInLine: String {
        "To sign in, this carries an Apple sign-in token, used once, with a one-time code and the key I made. Never your email or your name."
    }

    /// The one line the preview shows, under where it goes.
    public var previewLine: String {
        "This goes to \(runBy)'s own server. \(runBy) doesn't save it, and keeps only a count of messages and problems for \(countsKeptForDays) days."
    }
}
