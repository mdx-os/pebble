import Foundation
import PebbleCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(Security)
import Security
#endif

/// Where sign-in keeps its two values. The app's is the Keychain, this
/// device only (`SystemCloudKeychain`); tests keep them in memory.
public protocol CloudKeychain: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// Sign in with Apple for the cloud, as `CloudPolicy` says: the sign-in hop
/// carries exactly two values, Apple's anonymous ID for the person with
/// this app and a random key made on this device, under the names in
/// `CloudPolicy.signInFields`. No email and no name: the Apple request asks
/// for no scopes (`appleIDRequest`), and only the credential's `user` is
/// ever read (`accept(_:)`).
///
/// Nothing here reaches the network. The hop is built while the preview is
/// built, shown with its values covered, and sent only by the person's yes
/// (`CloudModel`). Turning the cloud off and Forget everything call
/// `forget`, which removes both values from the Keychain and drops the
/// session.
///
/// Apple's ID goes as Apple gives it, digits, dots and hex, which the
/// redactor leaves as it is (`theHopPassesThePreviewChecks`). The key is
/// letters only (`letters(_:)`), so it can't look like a phone number, a
/// card or an address, and the sign-in is never refused for one.
public final class AppleCloudAuth: CloudAuth, @unchecked Sendable {
    /// Where the hop goes, under the configured address.
    public static let signInPath = "v1/sign-in"
    /// The header a message carries once signed in, its value covered on
    /// the card like every sign-in value.
    public static let sessionHeader = "Cloud-Session"

    /// The Keychain accounts the two values are kept under.
    package static let appleUserAccount = "cloud.appleUser"
    package static let deviceKeyAccount = "cloud.deviceKey"

    /// The longest Apple ID taken, the most a sign-in value may hold
    /// (`CloudSignIn.maxValueLength`).
    package static let maxAppleUserLength = CloudSignIn.maxValueLength

    private let keychain: any CloudKeychain
    private let makeKey: @Sendable () -> String?
    private let lock = NSLock()
    /// What the server answered the last sign-in with. Held in memory only,
    /// so every launch signs in again.
    private var session: String?

    public init(keychain: any CloudKeychain = SystemCloudKeychain(),
                makeKey: @escaping @Sendable () -> String? = AppleCloudAuth.randomKey) {
        self.keychain = keychain
        self.makeKey = makeKey
    }

    #if canImport(AuthenticationServices)
    /// The Apple sign-in request: no scopes, so Apple shares neither the
    /// person's email nor their name.
    public static func appleIDRequest() -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        return request
    }

    /// Keeps Apple's anonymous ID from `credential`, and nothing else from it.
    public func accept(_ credential: ASAuthorizationAppleIDCredential) throws {
        try accept(appleUser: credential.user)
    }
    #endif

    public enum Refused: Error, Equatable {
        /// An Apple ID that is empty, too long, or not plain printable ASCII.
        case appleUser
    }

    /// Keeps `appleUser`, Apple's anonymous ID, in the Keychain. A new one
    /// drops any session from the last.
    public func accept(appleUser: String) throws {
        guard !appleUser.isEmpty, appleUser.utf8.count <= Self.maxAppleUserLength,
              appleUser.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { throw Refused.appleUser }
        try lock.withLock {
            session = nil
            try keychain.write(appleUser, for: Self.appleUserAccount)
        }
    }

    /// Exactly the two values the hop sends, under `CloudPolicy`'s names, or
    /// nil when there is no Apple ID yet or no key can be kept. The key is
    /// made here the first time, on this device.
    package func signInFields() -> [String: String]? {
        lock.withLock {
            guard let user = try? keychain.read(Self.appleUserAccount), !user.isEmpty else { return nil }
            var key = try? keychain.read(Self.deviceKeyAccount)
            if key == nil || key?.isEmpty == true {
                guard let made = makeKey(), (try? keychain.write(made, for: Self.deviceKeyAccount)) != nil else { return nil }
                key = made
            }
            guard let key else { return nil }
            let names = CloudPolicy.current.signInFields
            return [names[0]: user, names[1]: key]
        }
    }

    public func headers(for url: URL) -> [String: String] {
        lock.withLock { session.map { [Self.sessionHeader: $0] } ?? [:] }
    }

    /// The hop, while signed in to Apple and not yet to the server.
    public func signIn(for endpoint: URL) -> CloudSignIn? {
        guard lock.withLock({ session == nil }), let fields = signInFields(),
              let body = try? CloudSignIn.encoded(fields) else { return nil }
        return CloudSignIn(path: Self.signInPath, body: body)
    }

    /// Keeps the server's `{"session": "..."}` in memory, when it is only
    /// letters, as `docs/CLOUD.md` asks of the server, so it can never read
    /// as a personal detail. Anything else is dropped, and the next message
    /// signs in again.
    public func signedIn(_ answer: Data) {
        guard let reply = try? JSONDecoder().decode([String: String].self, from: answer),
              let token = reply["session"], (16...CloudSignIn.maxValueLength).contains(token.count),
              token.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else { return }
        lock.withLock { session = token }
    }

    /// Removes the Apple ID and the key from the Keychain and drops the
    /// session. Each is tried even when another can't go.
    public func forget() {
        lock.withLock {
            session = nil
            try? keychain.remove(Self.appleUserAccount)
            try? keychain.remove(Self.deviceKeyAccount)
        }
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

    /// 32 random bytes from the system, in letters. Nil if the system can't
    /// give them, so no weak key is ever made.
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
