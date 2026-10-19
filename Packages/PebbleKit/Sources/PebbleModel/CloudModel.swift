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
    /// Asked by a summary's work, not by a chat. Set by the code that built
    /// the request, never read from its words, so nothing a person types
    /// in a chat can make it look like a summary's.
    public let forSummary: Bool
    /// The summary's run that asked, so each run's preview is its own on
    /// Today's gate (`CloudYes.run`). Nil for a chat.
    public let run: String?

    public init(id: UUID = UUID(), request: CloudRequest, hidden: [Redaction.Kind: Int], forSummary: Bool = false,
                run: String? = nil) {
        self.id = id
        self.request = request
        self.hidden = hidden
        self.forSummary = forSummary
        self.run = run
    }
}

/// The answer to a preview.
public enum CloudConsent: Sendable, Equatable {
    /// The person said send.
    case send
    /// The person said not to send.
    case cancel
    /// Taken away before the person answered, as when the cloud was turned
    /// off or the screen went away. Nothing is sent, and no one chose that.
    case withdrawn
}

/// Shows the person a preview and waits for their answer. Nothing is sent
/// unless this says `.send`.
public protocol CloudReviewing: Sendable {
    func review(_ preview: CloudPreview) async -> CloudConsent
    /// As `review`, but withdrawn unshown when `isOn` says the cloud is off
    /// as the preview would go on screen. A reviewer that shows previews
    /// on the actor the switch is turned off on asks there, so a switch off
    /// just after the check that let the request be built never leaves a
    /// preview up that nothing will withdraw.
    func review(_ preview: CloudPreview, whileOn isOn: @escaping @Sendable () -> Bool) async -> CloudConsent
}

extension CloudReviewing {
    public func review(_ preview: CloudPreview, whileOn isOn: @escaping @Sendable () -> Bool) async -> CloudConsent {
        guard isOn() else { return .withdrawn }
        return await review(preview)
    }
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

    /// Signs in, after the person's yes and before the first preview.
    ///
    /// This is the one hop to the network the preview doesn't show, so any
    /// implementation must keep to what the turn on question already says
    /// in `CloudWords.askPoints`: it runs only after the yes, and it never
    /// carries anything from a chat, the notes or the private words.
    ///
    /// An implementation that reaches the network must also ship with its
    /// own disclosure: a line added to `CloudWords.askPoints`, in plain
    /// words, saying where sign-in goes and what it sends, such as an
    /// account name or a device token. Without that line it must not be
    /// used.
    ///
    /// It runs in a task that is cancelled when the person turns the cloud
    /// off, or when Forget everything has to clear the cloud setting. An
    /// implementation must check for cancellation (`Task.isCancelled`, or a
    /// cancellable `URLSession` call) before each step that reaches the
    /// network or saves anything, and stop at once without saving a token,
    /// so a sign-in that was under way never finishes after the cloud is off.
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
    /// The preview was taken away before the person answered it. Nothing
    /// was sent.
    case withdrawn
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
///    notes or private words can't be read, nothing is sent. A chat never
///    gets less private: see `HiddenSoFar`.
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
    private let isOn: @Sendable () throws -> Bool
    /// Shared by every copy of this model, so by the whole chat.
    private let hiddenSoFar = HiddenSoFar()

    /// `redactor` is asked for each reply, so newly saved notes and private
    /// words count right away; it throws when they can't be read. `isOn` is
    /// checked before building a request, as its preview goes on screen and
    /// again before sending, so turning the setting off stops a reply already
    /// waiting in the preview or still on its way there.
    /// It throws when the setting can't be read, which is not the same as
    /// off: nothing is sent, and the chat says it couldn't read them.
    public init(
        endpoint: URL,
        transport: any CloudTransport,
        reviewer: any CloudReviewing,
        auth: any CloudAuth = NoCloudAuth(),
        redactor: @escaping @Sendable () throws -> Redactor = { Redactor() },
        isOn: @escaping @Sendable () throws -> Bool = { true }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.reviewer = reviewer
        self.auth = auth
        self.redactor = redactor
        self.isOn = isOn
    }

    /// Words in a cloud chat leave the device, so no line read from this
    /// model promises the device. `ModelChoice` hands out the same value
    /// before a cloud chat exists.
    public static let place = PrivacyPlace.mayLeaveDevice

    public var runsOnDevice: Bool { Self.place.staysOnDevice }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        try checkOn()
        let redactor: Redactor
        do {
            redactor = hiddenSoFar.widened(by: try self.redactor())
        } catch {
            // Without the notes and private words it isn't known what to
            // take out, so nothing goes.
            throw CloudModelError.notesUnreadable
        }
        let preview = try Self.preview(
            for: transcript, endpoint: endpoint, redactor: redactor,
            headers: auth.headers(for: Self.url(for: endpoint)),
            forSummary: CloudAsk.forSummary,
            run: CloudAsk.forSummary ? CloudYes.run : nil
        )
        // Checked again where the preview goes on screen: the setting may
        // have been switched off since the check above. Unreadable counts as
        // off there, so nothing shows that couldn't be sent.
        let isOn = self.isOn
        switch await reviewer.review(preview, whileOn: { (try? isOn()) == true }) {
        case .send: break
        case .cancel: throw CloudModelError.notSent
        case .withdrawn: throw CloudModelError.withdrawn
        }
        try Task.checkCancellation()
        try checkOn()
        // Past the yes: a summary's work notes that what it read may go, or
        // refuses a yes that went stale, as for a summary stopped since.
        if let heard = CloudYes.heard, !heard() { throw CancellationError() }
        // The very request the person saw, unchanged.
        let data = try await transport.send(preview.request)
        guard let reply = try? JSONDecoder().decode(CloudPayload.Reply.self, from: data) else {
            throw CloudModelError.unreadableReply
        }
        return reply.reply
    }

    /// Throws `off` when the setting is off, and `notesUnreadable` when it
    /// can't be read, so a damaged file never reads as turned off.
    private func checkOn() throws {
        let on: Bool
        do {
            on = try isOn()
        } catch {
            throw CloudModelError.notesUnreadable
        }
        guard on else { throw CloudModelError.off }
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
        headers: [String: String] = [:],
        forSummary: Bool = false,
        run: String? = nil
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
            hidden: hidden,
            forSummary: forSummary,
            run: run
        )
    }
}

/// Every name and private word one chat has hidden so far.
///
/// Each request re-sends the earlier turns, redacted again with the notes
/// and private words as they are now. If the person then asks for more
/// privacy, by Forget everything, removing a private word or deleting a
/// note, a plain re-redaction would send those earlier turns with "Sam" or
/// "lemon cake" back in the clear. So each request is redacted with the
/// union of everything this chat has hidden before and everything the
/// current list hides: a privacy action never makes a later request in an
/// open chat less private. A new chat starts from the current list alone.
///
/// The union is held in memory only, for as long as the chat is open. It is
/// never written anywhere and never sent; it is only used to hide words.
/// Closing the chat, or starting a new one, lets it go.
///
/// So after Forget everything, an open cloud chat still holds the erased
/// private words here, to keep them hidden. That is what
/// `CloudWords.privateDetail` means by "erases them too": they are gone
/// from every file, and this copy, only ever used to hide, goes with the
/// chat.
final class HiddenSoFar: @unchecked Sendable {
    private let lock = NSLock()
    private var redactor = Redactor()

    /// Adds `current` to what has been hidden so far and returns the whole.
    func widened(by current: Redactor) -> Redactor {
        lock.withLock {
            redactor = redactor.union(current)
            return redactor
        }
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

    /// The `privacyPlace` of the model `model(...)` would pick, without
    /// making it: `CloudModel.place` with the cloud on, else `local`'s.
    public static func privacyPlace(settings: CloudHelpSettings, endpoint: URL?, local: any ModelClient) -> PrivacyPlace {
        usesCloud(settings: settings, endpoint: endpoint) ? CloudModel.place : local.privacyPlace
    }

    /// Whether the model `model(...)` picks runs on this device, without
    /// making it.
    public static func runsOnDevice(settings: CloudHelpSettings, endpoint: URL?, local: any ModelClient) -> Bool {
        privacyPlace(settings: settings, endpoint: endpoint, local: local).staysOnDevice
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
    static func makeSession() -> URLSession {
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
