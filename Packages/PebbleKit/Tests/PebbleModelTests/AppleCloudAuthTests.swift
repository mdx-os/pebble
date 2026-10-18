import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import PebbleCore
@testable import PebbleModel
import Testing

/// Sign in with Apple, held to `CloudPolicy`: exactly two values, no
/// scopes, nothing sent without the yes, and nothing kept after a switch
/// off or Forget everything.
struct AppleCloudAuthTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    /// Shaped like Apple's: digits, a dot, hex, a dot, digits. Read plain,
    /// its digit runs could look like a phone number.
    let appleUser = "001234.4f1a2b3c4d5e6f708192a3b4c5d6e7f8.0123"

    func signedInToApple(_ keychain: InMemoryCloudKeychain = InMemoryCloudKeychain()) throws -> AppleCloudAuth {
        let auth = AppleCloudAuth(keychain: keychain)
        try auth.accept(appleUser: appleUser)
        return auth
    }

    static func fields(_ body: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: body)
    }

    /// The hop carries exactly Apple's ID and the device key, under the
    /// policy's names, with no headers of its own. Any other field, an
    /// email or a name among them, fails here.
    @Test func theSignInHopCarriesExactlyTheTwoValues() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = try signedInToApple(keychain)
        let hop = try #require(auth.signIn(for: endpoint))
        #expect(hop.path == "v1/sign-in")
        #expect(hop.headers.isEmpty)
        let fields = try Self.fields(hop.body)
        #expect(fields.keys.sorted() == ["appleUser", "deviceKey"])
        #expect(Set(fields.keys) == Set(CloudPolicy.current.signInFields))
        #expect(fields["appleUser"] == appleUser)
        let key = try #require(keychain.all[AppleCloudAuth.deviceKeyAccount])
        #expect(fields["deviceKey"] == key)
        // Only the two values are kept, under their two accounts.
        #expect(Set(keychain.all.keys) == [AppleCloudAuth.appleUserAccount, AppleCloudAuth.deviceKeyAccount])
        // The same key each time, until it is forgotten.
        #expect(try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"] == key)
        // The key is letters only, so nothing in it reads as a detail.
        #expect(key.allSatisfy { ("a"..."p").contains($0) })
    }

    /// The preview takes the hop: its values pass every check, even with
    /// names in the notes and private words, so the sign-in is never
    /// refused for looking like a personal detail. The card and what goes
    /// are the same two fields.
    @Test func theHopPassesThePreviewChecks() throws {
        let redactor = Redactor(memory: [MemoryNote(text: "Sam's birthday is May 14.", source: .toldMe)],
                                privateWords: ["lemon cake"])
        let transcript = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
        // Apple's shape, with digit runs that could pass for a phone number
        // anywhere else, and a fresh random key each time.
        let shapes = [appleUser, "000123.4155550199abcdef0123456789abcd.0456", "001234.0207946095ab.0123",
                      "000000.12345678901234567890123456789012.0000", "000999.a4165550199b.9999"]
        for _ in 0..<8 {
            for user in shapes {
                let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
                try auth.accept(appleUser: user)
                let preview = try CloudModel.preview(for: transcript, endpoint: endpoint, redactor: redactor,
                                                     headers: auth.headers(for: CloudModel.url(for: endpoint)),
                                                     signIn: auth.signIn(for: endpoint))
                let hop = try #require(preview.signIn)
                #expect(hop.url.absoluteString == "https://cloud.example.com/v1/sign-in")
                let fields = try Self.fields(hop.body)
                #expect(fields.keys.sorted() == ["appleUser", "deviceKey"])
                #expect(fields["appleUser"] == user)
            }
        }
    }

    /// Without Apple's ID there is no hop and no key is made.
    @Test func noAppleIDMeansNoHopAndNoKey() {
        let keychain = InMemoryCloudKeychain()
        let auth = AppleCloudAuth(keychain: keychain)
        #expect(auth.signIn(for: endpoint) == nil)
        #expect(auth.headers(for: endpoint).isEmpty)
        #expect(keychain.all.isEmpty)
        // A key that can't be made means no hop, never a weak key.
        let noKey = AppleCloudAuth(keychain: InMemoryCloudKeychain([AppleCloudAuth.appleUserAccount: appleUser]),
                                   makeKey: { nil })
        #expect(noKey.signIn(for: endpoint) == nil)
    }

    /// Only a plain Apple ID is kept.
    @Test func anOddAppleIDIsRefused() {
        let auth = AppleCloudAuth(keychain: InMemoryCloudKeychain())
        for odd in ["", "has space", "line\nbreak", "caf\u{E9}", String(repeating: "a", count: AppleCloudAuth.maxAppleUserLength + 1)] {
            #expect(throws: AppleCloudAuth.Refused.appleUser) { try auth.accept(appleUser: odd) }
        }
        #expect(throws: Never.self) { try auth.accept(appleUser: String(repeating: "a", count: AppleCloudAuth.maxAppleUserLength)) }
    }

    /// Forget removes Apple's ID and the device key from the Keychain and
    /// drops the session, so nothing signs in until Apple is asked again,
    /// and then with a new key.
    @Test func forgetRemovesTheDeviceKey() throws {
        let keychain = InMemoryCloudKeychain()
        let auth = try signedInToApple(keychain)
        let first = try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"]
        auth.signedIn(Data(#"{"session":"abcdefghijklmnopqrstuvwxyz"}"#.utf8))
        #expect(!auth.headers(for: endpoint).isEmpty)
        auth.forget()
        #expect(keychain.all.isEmpty)
        #expect(auth.headers(for: endpoint).isEmpty)
        #expect(auth.signIn(for: endpoint) == nil)
        try auth.accept(appleUser: appleUser)
        let second = try Self.fields(try #require(auth.signIn(for: endpoint)).body)["deviceKey"]
        #expect(first != second)
    }

    /// A letters only session is kept in memory and rides later messages
    /// as one covered header; anything else is dropped.
    @Test func theSessionIsKeptOnlyWhenItIsLetters() throws {
        let auth = try signedInToApple()
        for bad in [#"{"session":"short"}"#, #"{"session":"abcdefghijklmnop1234"}"#,
                    #"{"session":"abcdefghijklmnop sam"}"#, #"{"token":"abcdefghijklmnopqrstu"}"#, "nope"] {
            auth.signedIn(Data(bad.utf8))
            #expect(auth.headers(for: endpoint).isEmpty, "\(bad)")
            #expect(auth.signIn(for: endpoint) != nil, "\(bad)")
        }
        auth.signedIn(Data(#"{"session":"abcdefghijklmnopQRSTUV"}"#.utf8))
        #expect(auth.headers(for: endpoint) == ["Cloud-Session": "abcdefghijklmnopQRSTUV"])
        #expect(auth.signIn(for: endpoint) == nil, "signed in, so no hop")
    }

    /// Nothing leaves without the yes: the hop is only in the preview until
    /// then, and with the yes it goes first, then the message.
    @Test func nothingIsSentWithoutTheYes() async throws {
        let notes: [MemoryNote] = []
        for answer in [CloudConsent.cancel, .send] {
            let keychain = InMemoryCloudKeychain()
            let auth = try signedInToApple(keychain)
            let transport = RecordingTransport()
            let reviewer = RecordingReviewer(answer: answer)
            let model = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth,
                                   redactor: { Redactor(memory: notes) })
            let transcript = [ChatTurn(id: UUID(), speaker: .person, text: "Hi there")]
            let reply = try? await model.reply(to: transcript)
            let shown = try #require(reviewer.seen.first?.signIn)
            #expect(try Self.fields(shown.body).keys.sorted() == ["appleUser", "deviceKey"])
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
    /// The Apple request asks for no scopes, so neither email nor name.
    @Test func theAppleRequestAsksForNoScopes() {
        #expect((AppleCloudAuth.appleIDRequest().requestedScopes ?? []).isEmpty)
    }
    #endif

    /// The code reads nothing from Apple but the anonymous ID: no email,
    /// name, token or code, and asks for no scope.
    @Test func theCodeReadsOnlyTheAppleID() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PebbleModel/AppleCloudAuth.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for word in [".email", ".fullName", "identityToken", "authorizationCode", "realUserStatus", "requestedScopes = [."] {
            #expect(!code.contains(word), "\(word)")
        }
        #expect(code.contains("request.requestedScopes = []"))
        #expect(code.contains("try accept(appleUser: credential.user)"))
    }
}
