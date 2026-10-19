import PebbleCore

extension CloudPolicy {
    /// The current policy's promises with no sign-in, for tests about
    /// everything but sign-in: a message may go with no session. No build
    /// reads it; the app's model always takes `CloudPolicy.current`.
    static let noSignInForTests = CloudPolicy(
        version: "test-no-sign-in", runBy: current.runBy, keepsWhatIsSent: current.keepsWhatIsSent,
        countsKeptForDays: current.countsKeptForDays, signInFields: []
    )
}
