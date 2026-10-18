import Foundation
import PebbleCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Where sign-in keeps the device key. The app's is the Keychain, this
/// device only (`SystemCloudKeychain`); tests keep it in memory.
public protocol CloudKeychain: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// Sign in with Apple for the cloud, as `CloudPolicy` says: the sign-in hop
/// carries exactly three values, under the names in
/// `CloudPolicy.signInFields`: Apple's identity token, the nonce made for
/// that one sign-in, and a random key made on this device. No email and no
/// name: the Apple request asks for no scopes (`appleIDRequest`), and only
/// the credential's identity token is ever read (`accept(_:)`).
///
/// Each Apple sign-in gets a fresh random nonce (`startAppleSignIn`). Apple
/// is given its SHA-256 and puts that in the token; the server is sent the
/// nonce itself, once, and checks the two match and that the nonce was
/// never used before. The server also checks Apple's signature, the
/// issuer, that the audience is this app, and that the token hasn't
/// expired, then keeps only Apple's anonymous ID and the device key.
///
/// The token and the nonce are held in memory only, never in the Keychain,
/// a file or the log, and only until the next preview is built: building
/// the hop takes them (`signIn(for:)`), so from then on only that hop holds
/// them, and it goes at most once. Whatever happens to it, sent, refused or
/// not sent, nothing here holds them after. Apple's sign-in ending without
/// a token (`appleSignInEnded`), turning the cloud off and Forget
/// everything (`forget`) drop them too.
///
/// Nothing here reaches the network. The hop is shown with its values
/// covered, and sent only by the person's yes (`CloudModel`).
///
/// Every value goes as letters only (`letters(_:)`): the token's bytes two
/// letters each, and a nonce and key made as letters. So nothing in them
/// can look like a phone number, a card or an address, and the sign-in is
/// never refused for one.
public final class AppleCloudAuth: CloudAuth, @unchecked Sendable {
    /// Where the hop goes, under the configured address.
    public static let signInPath = "v1/sign-in"
    /// The header a message carries once signed in, its value covered on
    /// the card like every sign-in value.
    public static let sessionHeader = "Cloud-Session"

    /// The one Keychain account sign-in keeps anything under.
    package static let deviceKeyAccount = "cloud.deviceKey"

    /// The longest identity token taken, in bytes. It goes as two letters a
    /// byte, so it fits the most a sign-in value may hold
    /// (`CloudSignIn.maxValueLength`).
    package static let maxTokenLength = CloudSignIn.maxValueLength / 2

    private let keychain: any CloudKeychain
    private let makeKey: @Sendable () -> String?
    private let makeNonce: @Sendable () -> String?
    private let lock = NSLock()
    /// What the server answered the last sign-in with. Held in memory only,
    /// so every launch signs in again.
    private var session: String?
    /// The nonce of the Apple sign-in under way, until Apple answers.
    private var waitingNonce: String?
    /// Apple's token and its nonce, from Apple's answer until the next
    /// preview takes them for its hop.
    private var unsent: (token: String, nonce: String)?

    public init(keychain: any CloudKeychain = SystemCloudKeychain(),
                makeKey: @escaping @Sendable () -> String? = AppleCloudAuth.randomKey,
                makeNonce: @escaping @Sendable () -> String? = AppleCloudAuth.randomKey) {
        self.keychain = keychain
        self.makeKey = makeKey
        self.makeNonce = makeNonce
    }

    /// Starts one Apple sign-in: makes a fresh nonce, held in memory, and
    /// gives back its SHA-256 for Apple's request. Any token not yet sent,
    /// and any nonce of an earlier sign-in, is dropped, so a nonce is used
    /// for one sign-in only. Nil, with nothing held, when no nonce can be
    /// made.
    public func startAppleSignIn() -> String? {
        let nonce = makeNonce()
        let hashed = nonce.flatMap(Self.sha256)
        lock.withLock {
            waitingNonce = hashed == nil ? nil : nonce
            unsent = nil
        }
        CloudLog.note(hashed == nil ? "Apple sign-in not started" : "Apple sign-in started")
        return hashed
    }

    #if canImport(AuthenticationServices)
    /// The Apple sign-in request: no scopes, so Apple shares neither the
    /// person's email nor their name, and the SHA-256 of a fresh nonce. Nil
    /// when no nonce can be made.
    public func appleIDRequest() -> ASAuthorizationAppleIDRequest? {
        guard let hashed = startAppleSignIn() else { return nil }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = hashed
        return request
    }

    /// Takes Apple's identity token from `credential`, and nothing else
    /// from it.
    public func accept(_ credential: ASAuthorizationAppleIDCredential) throws {
        try accept(identityToken: credential.identityToken ?? Data())
    }
    #endif

    public enum Refused: Error, Equatable {
        /// No Apple sign-in was under way, so there is no nonce for it.
        case noSignInUnderWay
        /// A token that is empty, too long, or not three plain parts.
        case identityToken
    }

    /// Holds `identityToken`, with the nonce of the sign-in under way, for
    /// the next preview's hop. The nonce is used up either way, so a token
    /// can't be paired with it twice. A new token drops any session from
    /// the last.
    public func accept(identityToken: Data) throws {
        let token = String(decoding: identityToken, as: UTF8.self)
        let refused: Refused? = lock.withLock {
            guard let nonce = waitingNonce else { return .noSignInUnderWay }
            waitingNonce = nil
            guard Self.isPlainToken(identityToken) else { return .identityToken }
            session = nil
            unsent = (token, nonce)
            return nil
        }
        if let refused {
            CloudLog.note("Apple sign-in token refused")
            throw refused
        }
        CloudLog.note("Apple sign-in token held for the next preview")
    }

    /// Apple's sign-in ended without a token, cancelled or failed: its
    /// nonce is dropped.
    public func appleSignInEnded() {
        lock.withLock { waitingNonce = nil }
        CloudLog.note("Apple sign-in ended without a token")
    }

    /// A token as Apple writes one: three parts of letters, digits, `-` and
    /// `_`, joined by dots, at most `maxTokenLength` bytes.
    static func isPlainToken(_ token: Data) -> Bool {
        guard (1...maxTokenLength).contains(token.count) else { return false }
        let parts = token.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
            }
        }
    }

    /// Exactly the three values the hop sends, under `CloudPolicy`'s names,
    /// or nil when there is no token yet or no key can be kept. Takes the
    /// token and its nonce, so nothing here holds them after, even when no
    /// hop can be made. The key is made here the first time, on this device.
    package func takeSignInFields() -> [String: String]? {
        lock.withLock {
            guard let held = unsent else { return nil }
            unsent = nil
            var key = try? keychain.read(Self.deviceKeyAccount)
            if key == nil || key?.isEmpty == true {
                guard let made = makeKey(), (try? keychain.write(made, for: Self.deviceKeyAccount)) != nil else { return nil }
                key = made
            }
            guard let key else { return nil }
            let names = CloudPolicy.current.signInFields
            return [names[0]: Self.letters(held.token), names[1]: held.nonce, names[2]: key]
        }
    }

    /// True while a token or a nonce is held here: from the start of an
    /// Apple sign-in until the next preview takes them.
    package var holdsTokenOrNonce: Bool {
        lock.withLock { waitingNonce != nil || unsent != nil }
    }

    public func headers(for url: URL) -> [String: String] {
        lock.withLock { session.map { [Self.sessionHeader: $0] } ?? [:] }
    }

    /// The hop, once Apple has given a token and while not yet signed in to
    /// the server. Takes the token either way.
    public func signIn(for endpoint: URL) -> CloudSignIn? {
        let signedIn = lock.withLock { session != nil }
        guard let fields = takeSignInFields(), !signedIn,
              let body = try? CloudSignIn.encoded(fields) else { return nil }
        CloudLog.note("sign-in hop made for the preview")
        return CloudSignIn(path: Self.signInPath, body: body)
    }

    /// Keeps the server's `{"session": "..."}` in memory, when it is only
    /// letters, as `docs/CLOUD.md` asks of the server, so it can never read
    /// as a personal detail. Anything else is dropped, and the next message
    /// needs a new Apple sign-in.
    public func signedIn(_ answer: Data) {
        guard let reply = try? JSONDecoder().decode([String: String].self, from: answer),
              let token = reply["session"], (16...CloudSignIn.maxValueLength).contains(token.count),
              token.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else {
            CloudLog.note("sign-in answer dropped")
            return
        }
        lock.withLock { session = token }
        CloudLog.note("signed in to the cloud")
    }

    /// Removes the key from the Keychain, and drops the session and any
    /// token or nonce. Each is let go even when the key can't be.
    public func forget() {
        lock.withLock {
            session = nil
            waitingNonce = nil
            unsent = nil
            try? keychain.remove(Self.deviceKeyAccount)
        }
        CloudLog.note("sign-in forgotten")
    }

    /// The SHA-256 of `nonce`'s bytes as lowercase hex, as Apple's request
    /// takes it. Nil where there is no CryptoKit, so no sign-in starts.
    public static func sha256(_ nonce: String) -> String? {
        #if canImport(CryptoKit)
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        nil
        #endif
    }

    /// `text`'s bytes, each as two letters from a to p, high half first.
    public static func letters(_ text: String) -> String {
        letters(Array(text.utf8))
    }

    /// `bytes`, each as two letters from a to p, high half first.
    static func letters(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return String(bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 0x0F)]] })
    }

    /// 32 random bytes from the system, in letters: a device key, or a
    /// nonce. Nil if the system can't give them, so no weak key or nonce is
    /// ever made.
    public static let randomKey: @Sendable () -> String? = {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        #endif
        return letters(bytes)
    }
}

#if canImport(Security)
/// The Keychain, for this device only: never synced, never restored to
/// another device from a backup, and readable only while it is unlocked.
public struct SystemCloudKeychain: CloudKeychain {
    /// No product or brand name in it, so a renamed build keeps its items.
    package static let service = "pebble.cloud"

    public init() {}

    /// What every item is found by.
    package static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// What every item is written with: this device only, while unlocked.
    package static func attributes(for account: String, value: String) -> [String: Any] {
        query(for: account).merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]) { $1 }
    }

    public struct Failed: Error, Equatable {
        public let status: OSStatus
    }

    public func read(_ account: String) throws -> String? {
        var query = Self.query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failed(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces any item there was, so it always has this device's
    /// protection, never one an older item was written with.
    public func write(_ value: String, for account: String) throws {
        try remove(account)
        let status = SecItemAdd(Self.attributes(for: account, value: value) as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failed(status: status) }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(Self.query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failed(status: status) }
    }
}
#endif

/// Keeps sign-in's values in memory, for tests and screenshots.
public final class InMemoryCloudKeychain: CloudKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]

    public init(_ items: [String: String] = [:]) {
        self.items = items
    }

    /// Every account and value kept, for tests.
    public var all: [String: String] { lock.withLock { items } }

    public func read(_ account: String) throws -> String? { lock.withLock { items[account] } }
    public func write(_ value: String, for account: String) throws { lock.withLock { items[account] = value } }
    public func remove(_ account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }
}
