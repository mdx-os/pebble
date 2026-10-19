import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

/// A server that takes a message only with its session: it answers the
/// sign-in hop with a session, or with none, and refuses any message that
/// doesn't carry the very session it handed out. Never touches the network.
final class SessionServer: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [CloudRequest] = []
    /// What the sign-in answer carries, made at run time. Nil for an
    /// answer with no session in it.
    let session: String?

    init(givesSession: Bool = true) {
        session = givesSession ? AppleCloudAuth.letters(UUID().uuidString) : nil
    }

    var sent: [CloudRequest] { lock.withLock { _sent } }

    func send(_ request: CloudRequest) async throws -> Data {
        lock.withLock { _sent.append(request) }
        if request.url.path.hasSuffix("/" + AppleCloudAuth.signInPath) {
            return try JSONEncoder().encode(session.map { ["session": $0] } ?? ["reply": "signed in"])
        }
        guard let session, request.headers[AppleCloudAuth.sessionHeader] == session else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONEncoder().encode(["reply": "Here's a short note you can send."])
    }
}

/// A Keychain whose removal can be made to fail, as a locked or damaged
/// Keychain's might. Reading and writing always work.
final class StuckKeychain: CloudKeychain, @unchecked Sendable {
    struct Stuck: Error {}
    let kept = InMemoryCloudKeychain()
    private let lock = NSLock()
    private var _removeFails = false

    var removeFails: Bool {
        get { lock.withLock { _removeFails } }
        set { lock.withLock { _removeFails = newValue } }
    }

    func read(_ account: String) throws -> String? { try kept.read(account) }
    func write(_ value: String, for account: String) throws { try kept.write(value, for: account) }
    func remove(_ account: String) throws {
        if removeFails { throw Stuck() }
        try kept.remove(account)
    }
}

/// Asks for a sign-in hop that names no session header, and is never
/// signed in by its answer.
struct StaysSignedOutAuth: CloudAuth {
    func headers(for url: URL) -> [String: String] { [:] }
    func signIn(for endpoint: URL) -> CloudSignIn? {
        CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8))
    }
    func forget() -> Bool { true }
}

/// The message after a sign-in carries the session the sign-in brought
/// back, as the preview showed; no session means no message; and with no
/// session and no sign-in nothing goes at all.
struct CloudSessionTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let token = MadeUpToken.make(header: #"{"alg":"RS256"}"#, payload: #"{"sub":"001234"}"#,
                                 signature: MadeUpToken.base64url("signature"))
    let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Plan my week")]

    func signInToApple(_ auth: AppleCloudAuth) throws {
        _ = try #require(auth.startAppleSignIn())
        try auth.accept(identityToken: Data(token.utf8))
    }

    func fields(_ body: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: body)
    }

    /// The first message after the sign-in goes with the session the
    /// sign-in answer brought, to a server that refuses it otherwise. The
    /// one preview showed that session line on the message, empty, which
    /// the card covers, and the session is the only thing added to it.
    @Test func theFirstMessageAfterSignInCarriesItsSession() async throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        try signInToApple(auth)
        let server = SessionServer()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: server, reviewer: reviewer, auth: auth)
        let reply = try await cloud.reply(to: turns)
        #expect(reply == "Here's a short note you can send.")
        let preview = try #require(reviewer.seen.first)
        let session = try #require(server.session)
        #expect(preview.sessionHeader == AppleCloudAuth.sessionHeader)
        #expect(preview.request.headers[AppleCloudAuth.sessionHeader] == "")
        #expect(server.sent.count == 2)
        #expect(server.sent.first == preview.signIn)
        let message = try #require(server.sent.last)
        #expect(message == preview.message(carrying: session))
        var shown = preview.request.headers
        shown[AppleCloudAuth.sessionHeader] = session
        #expect(message.headers == shown)
        #expect(message.body == preview.request.body)
        #expect(message.url == preview.request.url)
        // The next message has no hop, and its preview already carries
        // the session, exactly as it goes.
        let again = try await cloud.reply(to: turns + [ChatTurn(id: UUID(), speaker: .agent, text: reply),
                                                       ChatTurn(id: UUID(), speaker: .person, text: "And Friday?")])
        #expect(!again.isEmpty)
        let second = try #require(reviewer.seen.last)
        #expect(second.signIn == nil)
        #expect(second.sessionHeader == nil)
        #expect(second.request.headers[AppleCloudAuth.sessionHeader] == session)
        #expect(server.sent.count == 3)
        #expect(server.sent.last == second.request)
    }

    /// A sign-in answer that brings no session stops the reply: nothing
    /// more is sent, and the message stays on the device.
    @Test func aSignInAnswerWithNoSessionSendsNothingMore() async throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        try signInToApple(auth)
        let server = SessionServer(givesSession: false)
        let cloud = CloudModel(endpoint: endpoint, transport: server, reviewer: RecordingReviewer(answer: .send), auth: auth)
        await #expect(throws: CloudModelError.noSession) { try await cloud.reply(to: turns) }
        #expect(server.sent.count == 1, "only the sign-in went")
        #expect(server.sent.first?.url.path.hasSuffix(AppleCloudAuth.signInPath) == true)
        #expect(!auth.isSignedIn(to: endpoint))
        // A sign-in that says it is signed in but hands over no session
        // value for the line the card showed is stopped the same way.
        let hop = CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8), sessionHeader: "X-Session")
        let saysSignedIn = SampleAuth(signIn: hop)
        let recording = RecordingTransport()
        let other = CloudModel(endpoint: endpoint, transport: recording, reviewer: RecordingReviewer(answer: .send),
                               auth: saysSignedIn)
        await #expect(throws: CloudModelError.noSession) { try await other.reply(to: turns) }
        #expect(recording.sent.count == 1, "only the sign-in went")
        // A hop that names no session header, whose answer still leaves
        // the device signed out, is stopped too.
        let unanswered = RecordingTransport()
        let signedOut = CloudModel(endpoint: endpoint, transport: unanswered, reviewer: RecordingReviewer(answer: .send),
                                   auth: StaysSignedOutAuth())
        await #expect(throws: CloudModelError.noSession) { try await signedOut.reply(to: turns) }
        #expect(unanswered.sent.count == 1, "only the sign-in went")
    }

    /// With the current policy, which needs sign-in, a message with no
    /// session and no sign-in hop is never shown or sent.
    @Test func noSessionAndNoSignInSendsNothing() async throws {
        #expect(CloudPolicy.current.needsSignIn)
        for auth in [AppleCloudAuth(keychain: InMemoryCloudKeychain()) as any CloudAuth, NoCloudAuth()] {
            let transport = RecordingTransport()
            let reviewer = RecordingReviewer(answer: .send)
            let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth)
            await #expect(throws: CloudModelError.needsSignIn) { try await cloud.reply(to: turns) }
            #expect(transport.sent.isEmpty)
            #expect(reviewer.seen.isEmpty, "nothing was shown either")
        }
        // The app's model takes the current policy.
        #expect(CloudModel(endpoint: endpoint, transport: RecordingTransport(),
                           reviewer: RecordingReviewer(answer: .send)).policy == .current)
    }

    /// A key the Keychain wouldn't remove is never sent again: forget says
    /// it stayed, the next sign-in tries the removal again and, while it
    /// still fails, refuses with nothing shown or sent. Once it goes, the
    /// next sign-in makes a new key.
    @Test func aKeyTheKeychainKeptIsNeverSentAgain() async throws {
        let keychain = StuckKeychain()
        let auth = AppleCloudAuth(keychain: keychain)
        try signInToApple(auth)
        let first = try #require(try auth.signIn(for: endpoint))
        let old = try #require(try fields(first.body)["deviceKey"])
        keychain.removeFails = true
        #expect(!auth.forget())
        #expect(keychain.kept.all[AppleCloudAuth.deviceKeyAccount] == old, "the Keychain kept it")
        try signInToApple(auth)
        #expect(throws: CloudModelError.oldKeyStayed) { try auth.signIn(for: endpoint) }
        #expect(!auth.holdsTokenOrNonce, "the token is let go all the same")
        // Through the model: a plain refusal, nothing shown, nothing sent.
        try signInToApple(auth)
        let server = SessionServer()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: server, reviewer: reviewer, auth: auth)
        await #expect(throws: CloudModelError.oldKeyStayed) { try await cloud.reply(to: turns) }
        #expect(server.sent.isEmpty)
        #expect(reviewer.seen.isEmpty)
        // A leftover the Keychain keeps is owed the same way.
        keychain.removeFails = false
        #expect(auth.forget())
        try keychain.write(old, for: AppleCloudAuth.deviceKeyAccount)
        keychain.removeFails = true
        #expect(!auth.forgetLeftovers())
        try signInToApple(auth)
        #expect(throws: CloudModelError.oldKeyStayed) { try auth.signIn(for: endpoint) }
        // Once the Keychain lets go, the old key goes and a new one is made.
        keychain.removeFails = false
        try signInToApple(auth)
        let next = try #require(try auth.signIn(for: endpoint))
        let fresh = try #require(try fields(next.body)["deviceKey"])
        #expect(fresh != old)
        #expect(keychain.kept.all[AppleCloudAuth.deviceKeyAccount] == fresh)
    }
}
