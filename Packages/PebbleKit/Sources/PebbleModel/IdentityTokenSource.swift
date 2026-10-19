import Foundation
import PebbleCore

/// Where the cloud sign-in gets an identity token. Every source sits behind
/// this one seam: Sign in with Apple for real (`AppleIdentityTokenSource`),
/// a staging test sign-in in Debug builds only, and a fake in tests.
///
/// A source is given the SHA-256 of the nonce `AppleCloudAuth` made for
/// this one sign-in (`startAppleSignIn`), and answers with a token, a plain
/// refusal, or a request for one that leaves the device. Whatever it
/// answers, the token goes through `AppleCloudAuth.accept(identityToken:)`
/// and then the same sign-in hop, with the same three values, the same
/// preview and the same yes. A source never sends anything itself to the
/// cloud's address: a request that leaves the device is handed back
/// (`IdentityTokenAnswer.asks`), shown in the next preview above the hop,
/// and sent only by that preview's yes.
public protocol IdentityTokenSource: Sendable {
    /// What the sign-in row offers, and its words.
    var kind: IdentitySourceKind { get }

    /// A token for a sign-in whose nonce has the SHA-256 `nonceSha256`, as
    /// lowercase hex, or a plain refusal, or the request that would get one.
    func identityToken(nonceSha256: String) async -> IdentityTokenAnswer
}

/// The kinds of source a build can offer. A Release build has only Apple:
/// the staging test sign-in isn't compiled into it at all, which
/// `make release-test` and `make build-release` both check.
public enum IdentitySourceKind: String, Sendable, CaseIterable {
    case apple
    #if DEBUG
    case staging
    #endif
}

/// A source's answer.
public enum IdentityTokenAnswer: Sendable {
    /// The identity token's bytes, as Apple writes one.
    case token(Data)
    /// No token, and a line that says why in plain words. Nothing was sent.
    case refused(String)
    /// The token comes from a request that leaves the device. Nothing has
    /// gone yet: the request is shown in the next preview, above the
    /// sign-in hop, and only that preview's yes sends it.
    case asks(IdentityTokenAsk)
}

/// A request for an identity token, made on this device and not yet sent.
/// It goes under the cloud's address, at `path`, with `fields` as a flat
/// JSON body, and is held to every rule a sign-in hop is: plain path
/// segments, short token names, values the redactor leaves alone, and every
/// value covered on the card.
public struct IdentityTokenAsk: Sendable {
    public let path: String
    public let fields: [String: String]
    /// Reads the token from the answer's bytes. Nil when there is none.
    public let read: @Sendable (Data) -> Data?

    public init(path: String, fields: [String: String], read: @escaping @Sendable (Data) -> Data?) {
        self.path = path
        self.fields = fields
        self.read = read
    }
}

/// What asking the offered source came to, for the sign-in row.
public enum IdentitySignInOutcome: Sendable, Equatable {
    /// A token is held for the first message's preview.
    case ready
    /// The token is asked for in the first message's preview, above the
    /// sign-in, and nothing has gone yet.
    case asksWithFirstMessage
    /// No token, and the line that says why. Nothing was sent.
    case refused(String)
    /// This build offers no way to sign in. Nothing was asked or sent.
    case unavailable
}

/// Which source a build offers, from its settings.
public enum IdentitySignIn {
    /// The Info.plist key for `PEBBLE_SIGN_IN` (`Config/Cloud.xcconfig`).
    public static let settingKey = "PebbleSignIn"

    /// The source a build with these settings offers, or nil for none:
    /// - `apple`: Sign in with Apple, in every configuration.
    /// - `staging`: the staging test sign-in, in a Debug build only, with a
    ///   cloud address and a pass, and never in any other build, where the
    ///   code for it doesn't exist.
    /// Anything else offers none, and then no sign-in is ever asked for.
    public static func offered(infoDictionary: [String: Any]?, endpoint: URL?) -> (any IdentityTokenSource)? {
        let setting = (infoDictionary?[settingKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch setting {
        case IdentitySourceKind.apple.rawValue?:
            #if canImport(AuthenticationServices)
            return AppleIdentityTokenSource()
            #else
            return nil
            #endif
        #if DEBUG
        case IdentitySourceKind.staging.rawValue?:
            guard endpoint != nil else { return nil }
            return StagingIdentityTokenSource(pass: infoDictionary?[StagingIdentityTokenSource.passKey] as? String)
        #endif
        default:
            return nil
        }
    }
}
