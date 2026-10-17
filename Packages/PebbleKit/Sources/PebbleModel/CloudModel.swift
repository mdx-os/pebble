import Foundation
import PebbleCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One request to the cloud model, exactly as it leaves the device: the
/// method, the full address, every header and the body.
public struct CloudRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(method: String = "POST", url: URL, headers: [String: String], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The body as the person reads it in the preview. It is the same bytes
    /// that are sent, read as text.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The whole request as the preview shows it: the method and full
    /// address, one line per header in name order, a blank line, the body.
    public var shownText: String {
        Self.shownText(method: method, url: url, headers: headers, body: body)
    }

    /// The same layout for any request, so a test can hold what the
    /// transport received up against what the person saw.
    public static func shownText(method: String, url: URL, headers: [String: String], body: Data) -> String {
        let lines = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key): \($0.value)" }
        return ([method + " " + url.absoluteString] + lines).joined(separator: "\n")
            + "\n\n" + String(decoding: body, as: UTF8.self)
    }

    /// The URLRequest that carries exactly this and nothing more: no
    /// cookies, no cache, and only these headers.
    public var urlRequest: URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = headers
        request.httpBody = body
        return request
    }
}

/// The headers every request carries, set here so the system never adds
/// its own. The system's User-Agent names the app, its build and the OS
/// version, and its Accept-Language names the person's languages; these
/// fixed values say nothing about the person or the device.
public enum CloudHeaders {
    public static let fixed: [String: String] = [
        "Accept": "application/json",
        "Accept-Encoding": "identity",
        "Accept-Language": "en",
        "Content-Type": "application/json",
        "User-Agent": "pebble",
    ]

    /// Headers the system sets from the request itself: the host comes
    /// from the address and the length from the body.
    static let system: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]

    /// `auth`'s headers with the fixed ones on top. A sign-in header can't
    /// replace a fixed one or one the system sets, in any letter case.
    public static func merged(with auth: [String: String]) -> [String: String] {
        let fixedNames = Set(fixed.keys.map { $0.lowercased() })
        var all = auth.filter { !fixedNames.contains($0.key.lowercased()) && !system.contains($0.key.lowercased()) }
        all.merge(fixed) { _, fixed in fixed }
        return all
    }
}

/// What the person sees before anything is sent: the exact request, and
/// what was taken out of it on this device first.
public struct CloudPreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: CloudRequest
    public let hidden: [Redaction.Kind: Int]

    public init(id: UUID = UUID(), request: CloudRequest, hidden: [Redaction.Kind: Int]) {
        self.id = id
        self.request = request
        self.hidden = hidden
    }
}

/// The person's answer to a preview.
public enum CloudConsent: Sendable, Equatable {
    case send
    case cancel
}

/// Shows the person a preview and waits for their answer. Nothing is sent
/// unless this says `.send`.
public protocol CloudReviewing: Sendable {
    func review(_ preview: CloudPreview) async -> CloudConsent
}

/// Carries a request to the cloud model and brings back the answer's bytes.
/// Tests use a fake that records requests; nothing in tests or CI touches
/// the network.
public protocol CloudTransport: Sendable {
    func send(_ request: CloudRequest) async throws -> Data
}

/// Sign-in for the cloud model. There are no keys or tokens in this code,
/// and the default does nothing.
///
/// `headers(for:)` is asked while the preview is being built, before the
/// person has said yes to sending, so it must only read what is already on
/// this device, such as a token in the Keychain. It must never touch the
/// network; it is not async so it can't wait on a fetch. Every header it
/// returns is shown in the preview.
///
/// `signIn()` is the only place sign-in may use the network. It runs once,
/// right after the person says yes to turning the cloud on, and never
/// before.
public protocol CloudAuth: Sendable {
    func headers(for url: URL) -> [String: String]
    func signIn() async
}

extension CloudAuth {
    public func signIn() async {}
}

/// Adds nothing and signs in to nothing.
public struct NoCloudAuth: CloudAuth {
    public init() {}
    public func headers(for url: URL) -> [String: String] { [:] }
}

public enum CloudModelError: Error, Equatable, Sendable {
    /// The setting is off, or there is no address. Nothing was sent.
    case off
    /// The person chose not to send. Nothing was sent.
    case notSent
    /// Words of crisis are answered on this device and never sent, and a
    /// chat that holds them is never sent again.
    case staysHere
    /// The notes or private words couldn't be read, so it isn't known what
    /// to take out. Nothing was sent.
    case notesUnreadable
    /// The answer came back in a shape this version can't read.
    case unreadableReply
}

/// The body sent to the cloud model.
///
/// ```json
/// {
///   "messages" : [
///     { "role" : "agent", "text" : "Hi, I'm Pip. ..." },
///     { "role" : "person", "text" : "Write to [name] at [email]." }
///   ],
///   "version" : 1
/// }
/// ```
///
/// Keys are sorted and the JSON is indented, so the preview reads the same
/// way every time. Every `text` has been through `Redactor`. The agent's
/// own name, which the person chose, is in its first line and is sent. The
/// answer is `{"reply": "..."}`.
public struct CloudPayload: Codable, Sendable, Equatable {
    public struct Message: Codable, Sendable, Equatable {
        public let role: String
        public let text: String
    }

    public static let currentVersion = 1

    public let messages: [Message]
    public let version: Int

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    struct Reply: Decodable { let reply: String }
}

/// A model that runs on a computer somewhere else, reached at a configured
/// address.
///
/// It is off unless the person turned it on (`ModelChoice`). Every reply
/// goes the same way:
/// 1. Words of crisis stop here. `Conversation` answers them with care, and
///    this checks again before and after redaction, so they are never sent.
/// 2. Personal details are taken out on this device by `Redactor`. If the
///    notes or private words can't be read, nothing is sent.
/// 3. The person sees the exact request and chooses to send it or not.
/// 4. Only then do those same bytes go to the transport, once.
public struct CloudModel: ModelClient {
    /// Where requests go, under the configured address.
    public static let path = "v1/reply"

    public let endpoint: URL
    private let transport: any CloudTransport
    private let reviewer: any CloudReviewing
    private let auth: any CloudAuth
    private let redactor: @Sendable () throws -> Redactor
    private let isOn: @Sendable () -> Bool

    /// `redactor` is asked for each reply, so newly saved notes and private
    /// words count right away; it throws when they can't be read. `isOn` is
    /// checked before building a request and again before sending, so
    /// turning the setting off stops a reply already waiting in the preview.
    public init(
        endpoint: URL,
        transport: any CloudTransport,
        reviewer: any CloudReviewing,
        auth: any CloudAuth = NoCloudAuth(),
        redactor: @escaping @Sendable () throws -> Redactor = { Redactor() },
        isOn: @escaping @Sendable () -> Bool = { true }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.reviewer = reviewer
        self.auth = auth
        self.redactor = redactor
        self.isOn = isOn
    }

    public var runsOnDevice: Bool { false }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard isOn() else { throw CloudModelError.off }
        let redactor: Redactor
        do {
            redactor = try self.redactor()
        } catch {
            // Without the notes and private words it isn't known what to
            // take out, so nothing goes.
            throw CloudModelError.notesUnreadable
        }
        let preview = try Self.preview(
            for: transcript, endpoint: endpoint, redactor: redactor,
            headers: auth.headers(for: Self.url(for: endpoint))
        )
        guard await reviewer.review(preview) == .send else { throw CloudModelError.notSent }
        try Task.checkCancellation()
        guard isOn() else { throw CloudModelError.off }
        // The very request the person saw, unchanged.
        let data = try await transport.send(preview.request)
        guard let reply = try? JSONDecoder().decode(CloudPayload.Reply.self, from: data) else {
            throw CloudModelError.unreadableReply
        }
        return reply.reply
    }

    public static func url(for endpoint: URL) -> URL {
        endpoint.appendingPathComponent(path)
    }

    /// Builds the request for `transcript`, redacted, without sending it.
    /// Throws `staysHere` for anything touched by words of crisis.
    public static func preview(
        for transcript: [ChatTurn],
        endpoint: URL,
        redactor: Redactor,
        headers: [String: String] = [:]
    ) throws -> CloudPreview {
        // Before redaction: the same decision Conversation makes.
        if CareCheck.answersWithCare(transcript) { throw CloudModelError.staysHere }
        let kept = CareCheck.redacted(transcript)
        if kept.contains(where: { $0.speaker == .person && CareCheck.needsCare($0.text) }) {
            throw CloudModelError.staysHere
        }
        guard kept.contains(where: { $0.speaker == .person }) else { throw ModelClientError.noPersonTurn }
        var hidden: [Redaction.Kind: Int] = [:]
        let messages = kept.map { turn in
            let redaction = redactor.redact(turn.text)
            hidden.merge(redaction.hidden, uniquingKeysWith: +)
            return CloudPayload.Message(role: turn.speaker == .person ? "person" : "agent", text: redaction.text)
        }
        // After redaction: masks must never turn into words of crisis either.
        if messages.contains(where: { CareCheck.needsCare($0.text) }) { throw CloudModelError.staysHere }
        let body = try CloudPayload(messages: messages, version: CloudPayload.currentVersion).encoded()
        return CloudPreview(
            request: CloudRequest(url: url(for: endpoint), headers: CloudHeaders.merged(with: headers), body: body),
            hidden: hidden
        )
    }
}

/// Picks the model for a new chat. The on-device model unless the person
/// turned the cloud on and there is an address to reach. `cloud` is only
/// called then, so with the setting off no cloud code runs at all.
public enum ModelChoice {
    public static func model(
        settings: CloudHelpSettings,
        endpoint: URL?,
        local: any ModelClient,
        cloud: (URL) -> any ModelClient
    ) -> any ModelClient {
        guard usesCloud(settings: settings, endpoint: endpoint), let endpoint else { return local }
        return cloud(endpoint)
    }

    /// True when a new chat would use the cloud model.
    public static func usesCloud(settings: CloudHelpSettings, endpoint: URL?) -> Bool {
        settings.isOn && endpoint != nil
    }

    /// Whether the model `model(...)` picks runs on this device, without
    /// making it.
    public static func runsOnDevice(settings: CloudHelpSettings, endpoint: URL?, local: any ModelClient) -> Bool {
        usesCloud(settings: settings, endpoint: endpoint) ? false : local.runsOnDevice
    }
}

/// Sends requests with URLSession: one POST, no cookies, no cache, no
/// redirects, and only the headers the preview showed. Only made once the
/// person has turned the cloud on.
public struct URLSessionCloudTransport: CloudTransport {
    public typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let load: Load

    public init() {
        self.init(load: Self.live)
    }

    /// Tests pass a fake `load` that records the URLRequest.
    package init(load: @escaping Load) {
        self.load = load
    }

    public func send(_ request: CloudRequest) async throws -> Data {
        // Without the fixed User-Agent and Accept-Language the system would
        // add its own, which name the device and the person's languages and
        // were never shown. Such a request is refused, not quietly fixed, so
        // what goes is always exactly what was shown.
        guard request.headers == CloudHeaders.merged(with: request.headers) else {
            throw CloudTransportError.headersNotShown
        }
        let (data, response) = try await load(request.urlRequest)
        // A redirect is refused, so it arrives here as a 3xx and fails.
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// A session that keeps nothing and adds nothing: no cookies, cache or
    /// saved passwords, no extra headers, and every redirect refused, so
    /// the request can't end up anywhere but the address shown.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = nil
        return URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }

    private static let live: Load = { request in
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request, delegate: RefusesRedirects())
    }
}

public enum CloudTransportError: Error, Equatable, Sendable {
    /// The request lacked the fixed headers, or carried one the system sets.
    /// Nothing was sent.
    case headersNotShown
}

/// Says no to every redirect. A 307 or 308 would carry the same body to
/// another address, maybe another host or plain http, that the person
/// never saw.
public final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public override init() {}

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
