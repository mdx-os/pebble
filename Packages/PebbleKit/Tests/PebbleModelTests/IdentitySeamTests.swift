import Foundation
import PebbleCore
@testable import PebbleModel
import Testing
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// A server for a token ask: it answers the ask with a token made for the
/// nonce hash the ask carried, or with none, then the sign-in hop with a
/// session, and takes a message only with that session. Never touches the
/// network.
final class AskServer: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [CloudRequest] = []
    let givesToken: Bool
    let source: FakeIdentityTokenSource
    let session = AppleCloudAuth.letters(UUID().uuidString)

    init(source: FakeIdentityTokenSource, givesToken: Bool = true) {
        self.source = source
        self.givesToken = givesToken
    }

    var sent: [CloudRequest] { lock.withLock { _sent } }

    func send(_ request: CloudRequest) async throws -> Data {
        lock.withLock { _sent.append(request) }
        if request.url.path.hasSuffix("/" + FakeIdentityTokenSource.askPath) {
            guard givesToken, let hash = try JSONDecoder().decode([String: String].self, from: request.body)["nonceSha256"] else {
                return try JSONEncoder().encode(["note": "none"])
            }
            let hex = hash.map { String(Array("0123456789abcdef")[Array("abcdefghijklmnop").firstIndex(of: $0) ?? 0]) }.joined()
            return try JSONEncoder().encode(["identityToken": String(decoding: source.mint(hex), as: UTF8.self)])
        }
        if request.url.path.hasSuffix("/" + AppleCloudAuth.signInPath) {
            return try JSONEncoder().encode(["session": session])
        }
        guard request.headers[AppleCloudAuth.sessionHeader] == session else { throw URLError(.userAuthenticationRequired) }
        return try JSONEncoder().encode(["reply": "Here's a short note you can send."])
    }
}

/// Every source of an identity token sits behind one seam, and the hop
/// after it doesn't change.
struct IdentitySeamTests {
    let endpoint = URL(string: "https://cloud.example.com/base")!

    func auth(_ source: FakeIdentityTokenSource?) -> AppleCloudAuth {
        AppleCloudAuth(keychain: InMemoryCloudKeychain(), source: source)
    }

    func transcript() -> [ChatTurn] {
        Conversation.firstRun(named: "Pip", onDevice: false).turns
            + [ChatTurn(id: UUID(), speaker: .person, text: "Help me plan a quiet Saturday.")]
    }

    // MARK: The seam

    /// A token from the source goes through `accept`, then the very hop:
    /// the three values, the token as letters, and the nonce whose SHA-256
    /// the source was given.
    @Test func aTokenFromTheSourceGoesThroughTheSameHop() async throws {
        let source = FakeIdentityTokenSource()
        let auth = auth(source)
        #expect(auth.identitySource == .apple)
        #expect(await auth.askForIdentityToken() == .ready)
        let hashed = try #require(source.asked.first)
        let token = try #require(source.made.first)
        let hop = try #require(try auth.signIn(for: endpoint))
        #expect(hop.ask == nil)
        #expect(hop.tokenField == nil)
        #expect(hop.path == AppleCloudAuth.signInPath)
        let fields = try #require(hop.fields)
        #expect(fields.keys.sorted() == CloudPolicy.current.signInFields.sorted())
        #expect(fields["appleToken"] == AppleCloudAuth.letters(String(decoding: token, as: UTF8.self)))
        #expect(AppleCloudAuth.sha256(try #require(fields["nonce"])) == hashed)
        #expect(!auth.holdsTokenOrNonce, "the hop took the token and nonce")
    }

    /// The source's token is checked by `accept` like Apple's: one that
    /// isn't three plain parts is refused, said plainly, and nothing is
    /// held or made into a hop.
    @Test func aSourcesTokenIsCheckedByAccept() async throws {
        let auth = auth(FakeIdentityTokenSource(answer: .misshapenToken))
        #expect(await auth.askForIdentityToken() == .refused(CloudWords.signInTokenRefused))
        #expect(!auth.holdsTokenOrNonce)
        #expect(try auth.signIn(for: endpoint) == nil)
    }

    /// A refusal holds nothing, makes no hop, and its line is what the
    /// row says.
    @Test func aRefusalHoldsNothingAndSaysWhy() async throws {
        let auth = auth(FakeIdentityTokenSource(answer: .refuse(CloudWords.appleSignInCancelled)))
        #expect(await auth.askForIdentityToken() == .refused(CloudWords.appleSignInCancelled))
        #expect(!auth.holdsTokenOrNonce)
        #expect(try auth.signIn(for: endpoint) == nil)
    }

    /// With no source, nothing is asked and nothing is sent: a chat says
    /// it needs signing in with Apple, the line it said before.
    @Test func withNoSourceNothingIsAskedOrSent() async throws {
        let auth = auth(nil)
        #expect(auth.identitySource == nil)
        #expect(await auth.askForIdentityToken() == .unavailable)
        #expect(!auth.holdsTokenOrNonce)
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth)
        await #expect(throws: CloudModelError.needsSignIn) { try await model.reply(to: transcript()) }
        #expect(transport.sent.isEmpty)
        #expect(reviewer.seen.isEmpty)
    }

    /// With a source but no sign-in yet, nothing is sent either, and the
    /// chat says the person can sign in.
    @Test func withASourceButNoSignInTheChatSaysToSignIn() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               auth: auth(FakeIdentityTokenSource()))
        await #expect(throws: CloudModelError.signInFirst) { try await model.reply(to: transcript()) }
        #expect(transport.sent.isEmpty)
        #expect(reviewer.seen.isEmpty)
    }

    // MARK: A token ask, as the staging test sign-in makes

    /// An ask that leaves the device is never sent by asking: it shows in
    /// the first message's preview, above the hop, and the one yes sends
    /// the ask, then the hop with only its token filled in, then the
    /// message. The token goes through `accept`, paired with the nonce the
    /// hop carries.
    @Test func theTokenAskGoesInTheSamePreviewAboveTheHop() async throws {
        let source = FakeIdentityTokenSource(kind: .staging, answer: .ask)
        let auth = auth(source)
        #expect(await auth.askForIdentityToken() == .asksWithFirstMessage)
        #expect(auth.holdsTokenOrNonce, "the ask and its nonce wait for the preview")
        let server = AskServer(source: source)
        let reviewer = RecordingReviewer(answer: .send)
        let model = CloudModel(endpoint: endpoint, transport: server, reviewer: reviewer, auth: auth)
        _ = try await model.reply(to: transcript())

        let preview = try #require(reviewer.seen.first)
        let ask = try #require(preview.ask)
        let hop = try #require(preview.signIn)
        #expect(preview.hops == [ask, hop, preview.request])
        #expect(ask.url == endpoint.appendingPathComponent(FakeIdentityTokenSource.askPath))
        let asked = try #require(CloudSignIn(path: "", body: ask.body).fields)
        #expect(asked.keys.sorted() == ["nonceSha256", "pass"])
        #expect(asked["pass"] == source.pass)
        #expect(preview.tokenField == "appleToken")
        let shownHop = try #require(CloudSignIn(path: "", body: hop.body).fields)
        #expect(shownHop["appleToken"] == "")

        // On the wire: the ask exactly as shown, then the hop with only its
        // token filled in, then the message with its session.
        let sent = server.sent
        #expect(sent.count == 3)
        #expect(sent.first == ask)
        let wentHop = try #require(CloudSignIn(path: "", body: sent[1].body).fields)
        let token = try #require(source.made.last)
        #expect(wentHop["appleToken"] == AppleCloudAuth.letters(String(decoding: token, as: UTF8.self)))
        #expect(wentHop.filter { $0.key != "appleToken" } == shownHop.filter { $0.key != "appleToken" })
        #expect(sent[1].url == hop.url)
        #expect(sent[1].headers == hop.headers)
        #expect(AppleCloudAuth.sha256(try #require(wentHop["nonce"])) == source.asked.first)
        #expect(sent[2].headers[AppleCloudAuth.sessionHeader] == server.session)
        #expect(!auth.holdsTokenOrNonce, "nothing is held once the reply is over")
    }

    /// A preview with an ask that is declined sends nothing at all, and
    /// lets go of the ask and its nonce.
    @Test func aDeclinedTokenAskSendsNothingAndHoldsNothing() async throws {
        let source = FakeIdentityTokenSource(kind: .staging, answer: .ask)
        let auth = auth(source)
        #expect(await auth.askForIdentityToken() == .asksWithFirstMessage)
        let server = AskServer(source: source)
        let model = CloudModel(endpoint: endpoint, transport: server, reviewer: RecordingReviewer(answer: .cancel), auth: auth)
        await #expect(throws: CloudModelError.notSent) { try await model.reply(to: transcript()) }
        #expect(server.sent.isEmpty)
        #expect(!auth.holdsTokenOrNonce)
    }

    /// An ask answered with no token sends nothing more: not the hop, not
    /// the message.
    @Test func aTokenAskWithNoTokenSendsNothingMore() async throws {
        let source = FakeIdentityTokenSource(kind: .staging, answer: .ask)
        let auth = auth(source)
        #expect(await auth.askForIdentityToken() == .asksWithFirstMessage)
        let server = AskServer(source: source, givesToken: false)
        let model = CloudModel(endpoint: endpoint, transport: server, reviewer: RecordingReviewer(answer: .send), auth: auth)
        await #expect(throws: CloudModelError.noToken) { try await model.reply(to: transcript()) }
        #expect(server.sent.count == 1)
        #expect(server.sent.first?.url.path.hasSuffix(FakeIdentityTokenSource.askPath) == true)
        #expect(!auth.holdsTokenOrNonce)
    }

    /// The ask is held to the hop's rules before anything is shown: a path
    /// that isn't plain, a body that isn't a flat object, or a value the
    /// redactor would change is refused. A hop whose token part isn't
    /// empty while it waits is refused too.
    @Test func aTokenAskIsHeldToTheHopsRules() throws {
        let hopBody = try CloudSignIn.encoded(["appleToken": "", "nonce": "abc", "deviceKey": "def"])
        func preview(askPath: String = "v1/ask", askBody: Data = Data(#"{"pass":"abc"}"#.utf8),
                     hop: Data? = nil) throws -> CloudPreview {
            try CloudModel.preview(
                for: transcript(), endpoint: endpoint, redactor: Redactor(names: ["Sam"]),
                signIn: CloudSignIn(path: "v1/sign-in", body: hop ?? hopBody, sessionHeader: "Cloud-Session",
                                    ask: CloudSignIn.Ask(path: askPath, body: askBody), tokenField: "appleToken"))
        }
        #expect(try preview().ask != nil)
        #expect(throws: CloudTransportError.signInPathRefused("../ask")) { try preview(askPath: "../ask") }
        #expect(throws: CloudTransportError.signInBodyRefused) { try preview(askBody: Data(#"{"pass":{"a":"b"}}"#.utf8)) }
        #expect(throws: CloudTransportError.signInCarriesPersonalDetails) { try preview(askBody: Data(#"{"pass":"Sam"}"#.utf8)) }
        let filled = try CloudSignIn.encoded(["appleToken": "abc", "nonce": "abc", "deviceKey": "def"])
        #expect(throws: CloudTransportError.signInBodyRefused) { try preview(hop: filled) }
    }

    // MARK: Which source a build offers

    /// Apple is offered only when the setting says apple. The staging test
    /// sign-in, in this Debug build, only with `staging`, a pass and an
    /// address; anything else offers none.
    @Test func eachSourceIsOfferedOnlyWhenTheBuildSaysSo() {
        func offered(_ setting: String?, pass: String? = "letterspass", endpoint: URL? = URL(string: "https://cloud.example.com")) -> IdentitySourceKind? {
            var info: [String: Any] = [:]
            info[IdentitySignIn.settingKey] = setting
            info[StagingIdentityTokenSource.passKey] = pass
            return IdentitySignIn.offered(infoDictionary: info, endpoint: endpoint)?.kind
        }
        #expect(offered("apple") == .apple)
        #expect(offered(" apple ") == .apple)
        #expect(offered("apple", pass: nil, endpoint: nil) == .apple)
        #expect(offered("staging") == .staging)
        #expect(offered("staging", pass: nil) == nil)
        #expect(offered("staging", pass: "  ") == nil)
        #expect(offered("staging", pass: "$(PEBBLE_STAGING_SIGN_IN_PASS)") == nil)
        #expect(offered("staging", endpoint: nil) == nil)
        for none in [nil, "", "Apple", "fake", "$(PEBBLE_SIGN_IN)"] as [String?] {
            #expect(offered(none) == nil, "\(none ?? "nil")")
        }
        #expect(IdentitySignIn.offered(infoDictionary: nil, endpoint: nil) == nil)
    }

    /// The staging test sign-in asks at its path with exactly the nonce
    /// hash, as letters, and the pass, and reads the token from its answer.
    @Test func theStagingSourceAsksWithTheHashAndThePass() async throws {
        let source = try #require(StagingIdentityTokenSource(pass: " letterspass "))
        #expect(source.kind == .staging)
        let hex = try #require(AppleCloudAuth.sha256("made up nonce"))
        guard case .asks(let ask) = await source.identityToken(nonceSha256: hex) else {
            Issue.record("the staging source asks")
            return
        }
        #expect(ask.path == "v1/sign-in/dev-token")
        #expect(ask.fields.keys.sorted() == ["nonceSha256", "pass"])
        #expect(ask.fields["pass"] == "letterspass")
        let hash = try #require(ask.fields["nonceSha256"])
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { "abcdefghijklmnop".contains($0) })
        #expect(hash == AppleCloudAuth.letters(Array(SHA256Bytes.of("made up nonce"))))
        let token = FakeIdentityTokenSource().mint(hex)
        #expect(ask.read(try JSONEncoder().encode(["identityToken": String(decoding: token, as: UTF8.self)])) == token)
        #expect(ask.read(Data(#"{"session":"abc"}"#.utf8)) == nil)
        #expect(ask.read(Data(#"{"identityToken":""}"#.utf8)) == nil)
        guard case .refused = await source.identityToken(nonceSha256: "NOT HEX") else {
            Issue.record("a hash that isn't hex is refused")
            return
        }
    }

    #if canImport(AuthenticationServices)
    /// Without the entitlement, Apple's sheet answers with an unknown
    /// error, and the refusal says plainly that signing in with Apple isn't
    /// set up in this build yet. Closing the sheet and other failures each
    /// say their own line.
    @Test func appleSaysPlainlyWhenSignInIsNotSetUp() {
        func line(_ answer: IdentityTokenAnswer) -> String? {
            if case .refused(let line) = answer { line } else { nil }
        }
        #expect(line(AppleIdentityTokenSource.answer(for: ASAuthorizationError(.unknown))) == CloudWords.appleSignInNotSetUp)
        #expect(CloudWords.appleSignInNotSetUp.contains("isn't set up in this build yet"))
        #expect(line(AppleIdentityTokenSource.answer(for: ASAuthorizationError(.canceled))) == CloudWords.appleSignInCancelled)
        #expect(line(AppleIdentityTokenSource.answer(for: ASAuthorizationError(.failed))) == CloudWords.appleSignInFailed)
        #expect(line(AppleIdentityTokenSource.answer(for: URLError(.notConnectedToInternet))) == CloudWords.appleSignInFailed)
        #expect(AppleIdentityTokenSource().kind == .apple)
    }
    #endif
}

#if canImport(CryptoKit)
import CryptoKit

/// SHA-256 bytes, to check the hash the staging ask carries.
enum SHA256Bytes {
    static func of(_ text: String) -> [UInt8] { Array(SHA256.hash(data: Data(text.utf8))) }
}
#endif
