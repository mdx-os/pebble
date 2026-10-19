#if DEBUG
import Foundation
import PebbleCore

/// The staging test sign-in, for Debug builds only: none of this is
/// compiled into any other build (`make release-test`, and the scan of the
/// Release app in `make build-release`).
///
/// It asks the relay's staging test sign-in, at `path` under the cloud
/// address, for a token made for this one sign-in. The ask carries two
/// values: `nonceSha256`, the SHA-256 of the nonce, and `pass`, from
/// `PEBBLE_STAGING_SIGN_IN_PASS` in the git ignored
/// `Config/Cloud.local.xcconfig` only. The ask leaves the device, so it is
/// never sent from here: it is handed back (`IdentityTokenAnswer.asks`) and
/// shown in the first message's preview, above the sign-in hop, both values
/// covered, and only that preview's yes sends it. The token it brings back
/// goes through `AppleCloudAuth.accept(identityToken:)` like Apple's.
///
/// The hash goes as letters, one from `a` to `p` for each hex digit, as the
/// other sign-in values do, so the redactor never takes it for a number.
public struct StagingIdentityTokenSource: IdentityTokenSource {
    /// Where the ask goes, under the configured address.
    public static let path = "v1/sign-in/dev-token"
    /// The Info.plist key that carries the pass into a Debug build.
    public static let passKey = "PebbleStagingSignInPass"

    let pass: String

    /// Nil without a pass, or with a setting left unexpanded.
    public init?(pass: String?) {
        guard let pass = pass?.trimmingCharacters(in: .whitespacesAndNewlines), !pass.isEmpty,
              !pass.hasPrefix("$(") else { return nil }
        self.pass = pass
    }

    public var kind: IdentitySourceKind { .staging }

    public func identityToken(nonceSha256: String) async -> IdentityTokenAnswer {
        guard let hash = Self.letters(hex: nonceSha256) else { return .refused(CloudWords.signInCouldNotStart) }
        return .asks(IdentityTokenAsk(path: Self.path, fields: ["nonceSha256": hash, "pass": pass], read: Self.token(from:)))
    }

    /// `hex` as letters, `a` for 0 to `p` for 15. Nil for anything but
    /// 64 lowercase hex digits.
    static func letters(hex: String) -> String? {
        let digits = Array("0123456789abcdef")
        let alphabet = Array("abcdefghijklmnop")
        guard hex.count == 64 else { return nil }
        var out = ""
        for character in hex {
            guard let index = digits.firstIndex(of: character) else { return nil }
            out.append(alphabet[index])
        }
        return out
    }

    /// The test sign-in's answer, `{"identityToken": "..."}`. Nil for any
    /// other answer.
    static func token(from answer: Data) -> Data? {
        guard let reply = try? JSONDecoder().decode([String: String].self, from: answer),
              let token = reply["identityToken"], !token.isEmpty else { return nil }
        return Data(token.utf8)
    }
}
#endif
