import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import PebbleCore
@testable import PebbleModel
import Testing

/// Sign in with Apple, held to `CloudPolicy`: exactly Apple's token, a
/// fresh nonce and the device key, no scopes, nothing sent without the
/// yes, and the token and nonce held nowhere once their one hop is made.
struct AppleCloudAuthTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    /// Shaped like Apple's: three base64url parts joined by dots. Read
    /// plain, its digit runs could look like a phone number or a card.
    static let token = MadeUpToken.make(header: #"{"kid":"W6WcOKB","alg":"RS256"}"#,
                                        payload: #"{"sub":"001234.4165550199"}"#, signature: "4111111111111111-x_9")

    /// Signed in to Apple: a sign-in started, and `token` given for it.
    /// Returns the SHA-256 the Apple request carried.
    @discardableResult
    func signInToApple(_ auth: AppleCloudAuth, token: String = Self.token) throws -> String {
        let hashed = try #require(auth.startAppleSignIn())
        try auth.accept(identityToken: Data(token.utf8))
        return hashed
    }

    static func fields(_ body: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: body)
    }

    /// Every value `auth` holds, as text, so a test can look for a token
    /// or a nonce in it without asking `auth` itself.
    static func held(by auth: AppleCloudAuth) -> String {
        Mirror(reflecting: auth).children.map { String(describing: $0.value) }.joined(separator: "\n")
    }

    /// The hop carries exactly Apple's token, the nonce and the device key,
    /// under the policy's names, with no headers of its own. Any other
    /// field, an email or a name among them, fails here.
    @Test func theSignInHopCarriesExactlyTheThreeValues() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = AppleCloudAuth(keychain: keychain)
        let hashed = try signInToApple(auth)
        let hop = try #require(auth.signIn(for: endpoint))
        #expect(hop.path == "v1/sign-in")
        #expect(hop.headers.isEmpty)
        let fields = try Self.fields(hop.body)
        #expect(fields.keys.sorted() == ["appleToken", "deviceKey", "nonce"])
        #expect(Set(fields.keys) == Set(CloudPolicy.current.signInFields))
        #expect(fields["appleToken"] == AppleCloudAuth.letters(Self.token))
        // The nonce itself, whose SHA-256 the Apple request carried.
        let nonce = try #require(fields["nonce"])
        #expect(AppleCloudAuth.sha256(nonce) == hashed)
        let key = try #require(keychain.all[AppleCloudAuth.deviceKeyAccount])
        #expect(fields["deviceKey"] == key)
        // Only the key is kept, under its one account.
        #expect(Set(keychain.all.keys) == [AppleCloudAuth.deviceKeyAccount])
        // Every value is letters only, so nothing in it reads as a detail.
        for value in fields.values {
            #expect(value.allSatisfy { ("a"..."p").contains($0) }, "\(value.prefix(16))")
        }
        // The same key on the next sign-in, until it is forgotten.
        try signInToApple(auth)
        #expect(try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"] == key)
    }

    /// The preview takes the hop: its values pass every check, even with
    /// names in the notes and private words and a token whose digits look
    /// like a phone number or a card, so the sign-in is never refused for
    /// looking like a personal detail.
    @Test func theHopPassesThePreviewChecks() throws {
        let redactor = Redactor(memory: [MemoryNote(text: "Sam's birthday is May 14.", source: .toldMe)],
                                privateWords: ["lemon cake"])
        let transcript = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
        let shapes = [Self.token, "a.4165550199.b", MadeUpToken.joined("eyJ", "4111-1111-1111-1111", "c"), "Sam.lemon-cake.sam_lee",
                      String(repeating: "A", count: AppleCloudAuth.maxTokenLength - 4) + ".b.c"]
        for _ in 0..<4 {
            for token in shapes {
                let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
                try signInToApple(auth, token: token)
                let preview = try CloudModel.preview(for: transcript, endpoint: endpoint, redactor: redactor,
                                                     headers: auth.headers(for: CloudModel.url(for: endpoint)),
                                                     signIn: auth.signIn(for: endpoint))
                let hop = try #require(preview.signIn)
                #expect(hop.url.absoluteString == "https://cloud.example.com/v1/sign-in")
                let fields = try Self.fields(hop.body)
                #expect(fields.keys.sorted() == ["appleToken", "deviceKey", "nonce"])
                #expect(fields["appleToken"] == AppleCloudAuth.letters(token))
            }
        }
    }

    /// Without a token there is no hop and no key is made, and a token
    /// with no sign-in under way is refused.
    @Test func noTokenMeansNoHopAndNoKey() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = AppleCloudAuth(keychain: keychain)
        #expect(auth.signIn(for: endpoint) == nil)
        #expect(auth.headers(for: endpoint).isEmpty)
        #expect(throws: AppleCloudAuth.Refused.noSignInUnderWay) { try auth.accept(identityToken: Data(Self.token.utf8)) }
        #expect(auth.signIn(for: endpoint) == nil)
        #expect(keychain.all.isEmpty)
        // A key that can't be made means no hop, never a weak key, and the
        // token is let go all the same.
        let noKey = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeKey: { nil })
        try signInToApple(noKey)
        #expect(noKey.signIn(for: endpoint) == nil)
        #expect(!noKey.holdsTokenOrNonce)
        // A nonce that can't be made means no sign-in starts.
        let noNonce = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nil })
        #expect(noNonce.startAppleSignIn() == nil)
        #expect(throws: AppleCloudAuth.Refused.noSignInUnderWay) { try noNonce.accept(identityToken: Data(Self.token.utf8)) }
    }

    /// Only a token shaped like Apple's is held, and a refused one uses up
    /// its nonce, so nothing is left behind.
    @Test func anOddTokenIsRefused() throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        for odd in ["", "a.b", "a..c", ".b.c", "a.b.c.d", "a b.c.d", "a.b.c\n", "caf\u{E9}.b.c", "a.b+c.d", "a.b/c.d",
                    String(repeating: "a", count: AppleCloudAuth.maxTokenLength - 3) + ".b.c"] {
            _ = try #require(auth.startAppleSignIn())
            #expect(throws: AppleCloudAuth.Refused.identityToken, "\(odd.prefix(12))") {
                try auth.accept(identityToken: Data(odd.utf8))
            }
            #expect(!auth.holdsTokenOrNonce)
            #expect(auth.signIn(for: endpoint) == nil)
        }
        _ = try #require(auth.startAppleSignIn())
        #expect(throws: Never.self) {
            try auth.accept(identityToken: Data((String(repeating: "a", count: AppleCloudAuth.maxTokenLength - 4) + ".b.c").utf8))
        }
    }

    /// A nonce is made fresh for every sign-in, from the system's random
    /// bytes, and is good for one token only: a second token for the same
    /// sign-in is refused, and a new sign-in drops a token not yet sent.
    @Test func aNonceIsNeverReused() throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        var hashes: Set<String> = []
        var nonces: Set<String> = []
        for _ in 0..<20 {
            let hashed = try signInToApple(auth)
            #expect(hashes.insert(hashed).inserted)
            #expect(throws: AppleCloudAuth.Refused.noSignInUnderWay) { try auth.accept(identityToken: Data(Self.token.utf8)) }
            let hop = try #require(auth.signIn(for: endpoint))
            let nonce = try #require(try Self.fields(hop.body)["nonce"])
            #expect(nonce.count == 64)
            #expect(nonces.insert(nonce).inserted)
            #expect(AppleCloudAuth.sha256(nonce) == hashed)
        }
        // A sign-in started again before the last token went drops it.
        try signInToApple(auth)
        _ = try #require(auth.startAppleSignIn())
        #expect(auth.signIn(for: endpoint) == nil)
        // The SHA-256 is the standard one, written as Apple takes it.
        #expect(AppleCloudAuth.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Making the hop takes the token and the nonce: the auth object holds
    /// neither after it, whatever happens to the hop, and neither after
    /// Apple's sign-in ends without a token, Forget everything or a switch
    /// off (both call `forget`).
    @Test func afterTheHopTheAuthHoldsNoTokenOrNonce() async throws {
        func holdsNothing(_ auth: AppleCloudAuth, nonce: String?, _ why: String) {
            #expect(!auth.holdsTokenOrNonce, "\(why)")
            let held = Self.held(by: auth)
            #expect(!held.contains(Self.token), "\(why)")
            #expect(!held.contains(AppleCloudAuth.letters(Self.token)), "\(why)")
            if let nonce { #expect(!held.contains(nonce), "\(why)") }
        }
        let nonce = AppleCloudAuth.letters("a nonce for this test only")
        func auth() throws -> AppleCloudAuth {
            let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nonce })
            try signInToApple(auth)
            #expect(auth.holdsTokenOrNonce)
            #expect(Self.held(by: auth).contains(Self.token), "the check can see a token")
            return auth
        }
        // The hop made, then sent, refused by the server, or not sent.
        for (why, transport, answer) in [("sent", RecordingTransport() as any CloudTransport, CloudConsent.send),
                                         ("refused", RefusingTransport(), .send),
                                         ("cancelled", RecordingTransport(), .cancel)] {
            let signedIn = try auth()
            let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: answer),
                                   auth: signedIn)
            _ = try? await model.reply(to: [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")])
            holdsNothing(signedIn, nonce: nonce, why)
        }
        // Refused by the preview: a private word that is the whole nonce.
        let refused = try auth()
        #expect(throws: CloudTransportError.signInCarriesPersonalDetails) {
            try CloudModel.preview(for: [ChatTurn(id: UUID(), speaker: .person, text: "Hi")], endpoint: endpoint,
                                   redactor: Redactor(privateWords: [nonce]), signIn: refused.signIn(for: endpoint))
        }
        holdsNothing(refused, nonce: nonce, "refused by the preview")
        // Forgotten before any hop, and before Apple even answered.
        let forgotten = try auth()
        forgotten.forget()
        holdsNothing(forgotten, nonce: nonce, "forgotten")
        let waiting = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nonce })
        _ = try #require(waiting.startAppleSignIn())
        #expect(Self.held(by: waiting).contains(nonce), "the check can see a nonce")
        waiting.forget()
        holdsNothing(waiting, nonce: nonce, "forgotten while Apple was asked")
        // Apple's sign-in ended without a token.
        let ended = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nonce })
        _ = try #require(ended.startAppleSignIn())
        ended.appleSignInEnded()
        holdsNothing(ended, nonce: nonce, "Apple's sign-in ended")
        #expect(throws: AppleCloudAuth.Refused.noSignInUnderWay) { try ended.accept(identityToken: Data(Self.token.utf8)) }
    }

    /// The token and the nonce are never kept on the device: after a
    /// sign-in that was sent, refused by the server, refused by the preview
    /// or not sent, neither is in any file of the app's folder, in
    /// UserDefaults, in the Keychain items sign-in owns, or in any line the
    /// cloud code wrote to the log.
    @Test func theTokenIsNeverKeptOrLogged() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("token-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = LogLines()
        let watching = CloudLog.watch { lines.add($0) }
        defer { CloudLog.stopWatching(watching) }
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", at: Date(), source: .toldMe)
        let store = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try store.save(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        var secrets: [String] = []
        // Code that breaks the promise leaves nothing in the test runner's
        // defaults once the test is done with it.
        defer {
            for (key, value) in UserDefaults.standard.dictionaryRepresentation()
            where secrets.contains(where: { String(describing: value).contains($0) }) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        for (transport, answer) in [(RecordingTransport() as any CloudTransport, CloudConsent.send),
                                    (RefusingTransport(), .send), (RecordingTransport(), .cancel)] {
            let keychain = InMemoryCloudKeychain()
            let nonce = try #require(AppleCloudAuth.randomKey())
            let token = "eyJ" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + ".eyJzdWIi.sig"
            let auth = AppleCloudAuth(keychain: keychain, makeNonce: { nonce })
            try signInToApple(auth, token: token)
            let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: answer),
                                   auth: auth, redactor: { Redactor(memory: memory.notes(), privateWords: try store.load().privateWords) },
                                   isOn: { [endpoint] in try store.load().isOn(for: endpoint) })
            _ = try? await model.reply(to: [ChatTurn(id: UUID(), speaker: .person, text: "Write to Sam about lemon cake")])
            #expect(!keychain.all.values.contains { $0.contains(token) || $0.contains(nonce) })
            secrets += [token, AppleCloudAuth.letters(token), nonce]
        }
        // Refused by the preview too.
        let nonce = try #require(AppleCloudAuth.randomKey())
        let refused = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nonce })
        try signInToApple(refused)
        _ = try? CloudModel.preview(for: [ChatTurn(id: UUID(), speaker: .person, text: "Hi")], endpoint: endpoint,
                                    redactor: Redactor(privateWords: [nonce]), signIn: refused.signIn(for: endpoint))
        secrets += [Self.token, AppleCloudAuth.letters(Self.token), nonce]

        var kept = ""
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            kept += String(decoding: (try? Data(contentsOf: folder.appendingPathComponent(path))) ?? Data(), as: UTF8.self)
        }
        #expect(!kept.isEmpty, "the scan reads the app's files")
        let defaults = String(describing: UserDefaults.standard.dictionaryRepresentation())
        let logged = lines.all.joined(separator: "\n")
        #expect(logged.contains("sign-in hop made for the preview"), "the scan reads the log")
        for secret in secrets {
            #expect(!kept.contains(secret))
            #expect(!defaults.contains(secret))
            #expect(!logged.contains(secret))
        }
    }

    /// Nothing in the cloud code prints or logs but through `CloudLog`,
    /// which takes only fixed words, so no token, nonce or key can be
    /// written to a log.
    @Test func nothingInTheCloudCodeLogsAValue() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = ["PebbleModel/AppleCloudAuth.swift", "PebbleModel/CloudModel.swift", "PebbleModel/CloudLog.swift",
                     "PebbleModel/Conversation.swift", "PebbleModel/ModelClient.swift", "PebbleCore/CloudHelp.swift",
                     "PebbleCore/CloudPolicy.swift", "PebbleCore/Redactor.swift", "PebbleUI/CloudHelpView.swift",
                     "PebbleUI/ChatView.swift"]
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for call in ["print(", "debugPrint(", "dump(", "NSLog(", "os_log(", "FileHandle.standardError", "fputs("] {
                #expect(!code.contains(call), "\(file): \(call)")
            }
            if file != "PebbleModel/CloudLog.swift" {
                #expect(!code.contains("Logger("), "\(file)")
                #expect(!code.contains(".info(") && !code.contains(".debug(") && !code.contains(".error("), "\(file)")
            }
        }
        let log = try String(contentsOf: sources.appendingPathComponent("PebbleModel/CloudLog.swift"), encoding: .utf8)
        #expect(log.contains("public static func note(_ event: StaticString) {"))
        #expect(log.contains("let line = event.description\n"))
        #expect(log.components(separatedBy: "logger.").count == 2)
        #expect(log.contains("logger.info(\"\\(line)\")"))
        // The token is only ever read from the credential, and only ever
        // handed to the hop.
        let auth = try String(contentsOf: sources.appendingPathComponent("PebbleModel/AppleCloudAuth.swift"), encoding: .utf8)
        #expect(auth.components(separatedBy: "keychain.write(").count == 2)
        #expect(auth.contains("keychain.write(made, for: Self.deviceKeyAccount)"))
    }

    /// Forget removes the device key from the Keychain and drops the
    /// session, so nothing signs in until Apple is asked again, and then
    /// with a new key.
    @Test func forgetRemovesTheDeviceKey() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = AppleCloudAuth(keychain: keychain)
        try signInToApple(auth)
        let first = try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"]
        // A token waiting for the next preview, and a session, both held.
        try signInToApple(auth)
        auth.signedIn(Data(#"{"session":"abcdefghijklmnopqrstuvwxyz"}"#.utf8))
        #expect(!auth.headers(for: endpoint).isEmpty)
        #expect(auth.holdsTokenOrNonce)
        auth.forget()
        #expect(!auth.holdsTokenOrNonce)
        #expect(keychain.all.isEmpty)
        #expect(auth.headers(for: endpoint).isEmpty)
        #expect(auth.signIn(for: endpoint) == nil)
        try signInToApple(auth)
        let second = try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"]
        #expect(first != second)
    }

    /// A letters only session is kept in memory and rides later messages
    /// as one covered header; anything else is dropped.
    @Test func theSessionIsKeptOnlyWhenItIsLetters() throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        for bad in [#"{"session":"short"}"#, #"{"session":"abcdefghijklmnop1234"}"#,
                    #"{"session":"abcdefghijklmnop sam"}"#, #"{"token":"abcdefghijklmnopqrstu"}"#, "nope"] {
            auth.signedIn(Data(bad.utf8))
            #expect(auth.headers(for: endpoint).isEmpty, "\(bad)")
            try signInToApple(auth)
            #expect(auth.signIn(for: endpoint) != nil, "\(bad)")
        }
        try signInToApple(auth)
        auth.signedIn(Data(#"{"session":"abcdefghijklmnopQRSTUV"}"#.utf8))
        #expect(auth.headers(for: endpoint) == ["Cloud-Session": "abcdefghijklmnopQRSTUV"])
        #expect(auth.signIn(for: endpoint) == nil, "signed in, so no hop")
        #expect(!auth.holdsTokenOrNonce, "and the token is let go")
    }

    /// Nothing leaves without the yes: the hop is only in the preview until
    /// then, and with the yes it goes first, then the message.
    @Test func nothingIsSentWithoutTheYes() async throws {
        let notes: [MemoryNote] = []
        for answer in [CloudConsent.cancel, .send] {
            let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
            try signInToApple(auth)
            let transport = RecordingTransport()
            let reviewer = RecordingReviewer(answer: answer)
            let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth,
                                   redactor: { Redactor(memory: notes) })
            let transcript = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
            let reply = try? await model.reply(to: transcript)
            let shown = try #require(reviewer.seen.first?.signIn)
            #expect(try Self.fields(shown.body).keys.sorted() == ["appleToken", "deviceKey", "nonce"])
            if answer == .cancel {
                #expect(reply == nil)
                #expect(transport.sent.isEmpty)
            } else {
                #expect(transport.sent.count == 2)
                #expect(transport.sent.first == shown)
                #expect(transport.sent.last?.url == CloudModel.url(for: endpoint))
            }
        }
    }

    /// The key is 32 random bytes as 64 letters, new each time.
    @Test func theDeviceKeyIsRandom() throws {
        let one = try #require(AppleCloudAuth.randomKey())
        let two = try #require(AppleCloudAuth.randomKey())
        #expect(one.count == 64)
        #expect(one.allSatisfy { ("a"..."p").contains($0) })
        #expect(one != two)
        #expect(AppleCloudAuth.letters("A0") == "ebda")
    }

    #if canImport(Security)
    /// Every Keychain item is this device's only: never synced, never
    /// restored to another device, readable only while it is unlocked.
    @Test func theKeyIsKeptForThisDeviceOnly() {
        let attributes = SystemCloudKeychain.attributes(for: "cloud.deviceKey", value: "abc")
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(attributes[kSecAttrService as String] as? String == "pebble.cloud")
        let query = SystemCloudKeychain.query(for: "cloud.deviceKey")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }
    #endif

    #if canImport(AuthenticationServices)
    /// The Apple request asks for no scopes, so neither email nor name, and
    /// carries the SHA-256 of a nonce made for it alone.
    @Test func theAppleRequestAsksForNoScopesAndCarriesTheNoncesHash() throws {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { "abc" })
        let request = try #require(auth.appleIDRequest())
        #expect((request.requestedScopes ?? []).isEmpty)
        #expect(request.nonce == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let fresh = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        let one = try #require(fresh.appleIDRequest()?.nonce)
        let two = try #require(fresh.appleIDRequest()?.nonce)
        #expect(one != two)
        #expect(AppleCloudAuth(keychain: InMemoryCloudKeychain(), makeNonce: { nil }).appleIDRequest() == nil)
    }
    #endif

    /// The code reads nothing from Apple but the identity token: no email,
    /// name, user, code or status, and asks for no scope.
    @Test func theCodeReadsOnlyTheIdentityToken() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PebbleModel/AppleCloudAuth.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for word in [".email", ".fullName", "credential.user", "authorizationCode", "realUserStatus", "requestedScopes = [."] {
            #expect(!code.contains(word), "\(word)")
        }
        #expect(code.contains("request.requestedScopes = []"))
        #expect(code.contains("request.nonce = hashed"))
        #expect(code.contains("try accept(identityToken: credential.identityToken ?? Data())"))
    }
}

/// Answers the sign-in hop with a refusal, as a server that won't take
/// the token would.
struct RefusingTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data {
        throw URLError(.userAuthenticationRequired)
    }
}

/// Every line the cloud code wrote while a test watched.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
