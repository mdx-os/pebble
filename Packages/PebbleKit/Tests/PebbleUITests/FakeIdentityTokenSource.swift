import Foundation
@testable import PebbleModel

/// An identity token source for tests. Its tokens are made at run time
/// (`MadeUpToken`), shaped like Apple's and carrying the nonce hash they
/// were asked for, so no line of the tests holds a whole one. It can
/// answer with a token, a refusal, or an ask that leaves the device, the
/// way the staging test sign-in does. No key signs anything.
final class FakeIdentityTokenSource: IdentityTokenSource, @unchecked Sendable {
    enum Answer {
        case token
        /// A token that isn't three plain parts, which `accept` refuses.
        case misshapenToken
        case refuse(String)
        case ask
    }

    /// Where its ask goes, under the cloud's address.
    static let askPath = "v1/sign-in/test-token"
    /// The pass its ask carries, letters only, made at run time.
    let pass = AppleCloudAuth.letters("made up pass " + UUID().uuidString)

    let kind: IdentitySourceKind
    let answer: Answer
    private let lock = NSLock()
    private var _asked: [String] = []
    private var _made: [Data] = []

    init(kind: IdentitySourceKind = .apple, answer: Answer = .token) {
        self.kind = kind
        self.answer = answer
    }

    /// Every nonce hash it was asked with, in order.
    var asked: [String] { lock.withLock { _asked } }
    /// Every token it made, in order.
    var made: [Data] { lock.withLock { _made } }

    func identityToken(nonceSha256: String) async -> IdentityTokenAnswer {
        lock.withLock { _asked.append(nonceSha256) }
        switch answer {
        case .token:
            return .token(mint(nonceSha256))
        case .misshapenToken:
            return .token(Data("not a token".utf8))
        case .refuse(let line):
            return .refused(line)
        case .ask:
            let hash = StagingIdentityTokenSource.letters(hex: nonceSha256) ?? ""
            return .asks(IdentityTokenAsk(path: Self.askPath, fields: ["nonceSha256": hash, "pass": pass]) { answer in
                guard let reply = try? JSONDecoder().decode([String: String].self, from: answer),
                      let token = reply["identityToken"] else { return nil }
                return Data(token.utf8)
            })
        }
    }

    /// A new made up token for `nonceSha256`, kept in `made`.
    func mint(_ nonceSha256: String) -> Data {
        let token = Data(MadeUpToken.make(header: #"{"alg":"none","kid":"made-up"}"#,
                                          payload: "{\"nonce\":\"\(nonceSha256)\",\"sub\":\"\(UUID().uuidString)\"}",
                                          signature: AppleCloudAuth.letters(UUID().uuidString)).utf8)
        lock.withLock { _made.append(token) }
        return token
    }
}
