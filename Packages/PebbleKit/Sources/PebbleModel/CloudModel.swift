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
    /// The headers include the Host and Content-Length the system adds.
    public var shownText: String {
        Self.shownText(method: method, url: url, headers: headers, body: body)
    }

    /// Every header line the preview shows, in name order: `headers`, and
    /// the Host and Content-Length URLSession adds from the address and the
    /// body. `CloudHeaders` refuses both from anywhere else, so these are
    /// the only values they can have.
    public static func shownHeaders(url: URL, headers: [String: String], body: Data) -> [(name: String, value: String)] {
        var all = headers
        all["Host"] = hostLine(for: url)
        all["Content-Length"] = String(body.count)
        return all.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { (name: $0.key, value: $0.value) }
    }

    /// The Host header as URLSession writes it: an IPv6 address in
    /// brackets, and the port only when it isn't the scheme's own.
    /// `CloudEndpoint` takes only ASCII addresses, so the host is never
    /// encoded on the way out.
    public static func hostLine(for url: URL) -> String {
        let host = url.host ?? ""
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let ownPort = url.scheme?.lowercased() == "http" ? 80 : 443
        guard let port = url.port, port != ownPort else { return shown }
        return shown + ":\(port)"
    }

    /// The same layout for any request, so a test can hold what the
    /// transport received up against what the person saw.
    public static func shownText(method: String, url: URL, headers: [String: String], body: Data) -> String {
        let lines = shownHeaders(url: url, headers: headers, body: body).map { "\($0.name): \($0.value)" }
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
/// fixed values say nothing about the person, the device or the app. The
/// User-Agent is a plain word, not the product's name, so a renamed build
/// can't be picked out by it either.
public enum CloudHeaders {
    public static let fixed: [String: String] = [
        "Accept": "application/json",
        "Accept-Encoding": "identity",
        "Accept-Language": "en",
        "Content-Type": "application/json",
        "User-Agent": "agent",
    ]

    /// Names URLSession reserves: it sets them itself, or may drop or
    /// overwrite them, so what went could differ from what was shown. The
    /// host comes from the address and the length from the body, and the
    /// preview shows both (`CloudRequest.shownHeaders`). Sign-in can't use
    /// any of them, the authorization headers included; it needs a header
    /// of its own name. A cookie is refused too: the transport keeps none
    /// and sets none, so a sign-in token goes only as a header the preview
    /// shows.
    public static let reserved: Set<String> = [
        "authorization", "proxy-authorization", "proxy-authenticate", "www-authenticate",
        "host", "content-length", "connection", "transfer-encoding", "cookie",
    ]

    /// `auth`'s headers with the fixed ones on top. A sign-in header can't
    /// replace a fixed one, in any letter case, and a reserved name is
    /// refused outright, so nothing is sent.
    public static func merged(with auth: [String: String]) throws -> [String: String] {
        if let name = auth.keys.sorted().first(where: { reserved.contains($0.lowercased()) }) {
            throw CloudTransportError.reservedHeader(name)
        }
        let fixedNames = Set(fixed.keys.map { $0.lowercased() })
        var all = auth.filter { !fixedNames.contains($0.key.lowercased()) }
        all.merge(fixed) { _, fixed in fixed }
        return all
    }
}

/// What the person sees before anything is sent: the exact request, and
/// what was taken out of it on this device first.
///
/// When the cloud needs a sign-in first, that hop is part of the same
/// preview, shown above the message, and the one yes sends both, sign-in
/// first. No header of ours goes that isn't on this screen; URLSession adds
/// only its own connection handling, which carries nothing of the person:
/// its session keeps no cookie, cache or saved password and adds none
/// (`URLSessionCloudTransport.makeSession`), so a cookie set by a sign-in
/// answer never rides on the message.
public struct CloudPreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The sign-in hop that goes first, if the cloud needs one.
    public let signIn: CloudRequest?
    public let request: CloudRequest
    public let hidden: [Redaction.Kind: Int]

    public init(id: UUID = UUID(), signIn: CloudRequest? = nil, request: CloudRequest, hidden: [Redaction.Kind: Int]) {
        self.id = id
        self.signIn = signIn
        self.request = request
        self.hidden = hidden
    }

    /// Every request the yes sends, in order.
    public var hops: [CloudRequest] { [signIn, request].compactMap { $0 } }

    /// Everything the yes sends, as the preview shows it: the sign-in hop
    /// first when there is one, then the message.
    public var shownText: String {
        guard let signIn else { return request.shownText }
        return CloudWords.previewSignInFirst + "\n" + signIn.shownText + "\n\n"
            + CloudWords.previewThenMessage + "\n" + request.shownText
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

/// A sign-in the cloud needs before a message: a hop of its own, sent to
/// a path under the same address, shown in the preview and sent only by
/// its yes, through the same transport as the message.
public struct CloudSignIn: Sendable, Equatable {
    /// Under the configured address: plain segments of letters, digits and
    /// `-._~` only, none empty, `.` or `..`. Anything else is refused
    /// (`CloudTransportError.signInPathRefused`), so the hop keeps the
    /// address's https, host, port and path prefix, and URLSession has
    /// nothing to read differently from the preview.
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(path: String, headers: [String: String] = [:], body: Data) {
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// The longest value a sign-in body may hold, in characters.
    public static let maxValueLength = 512

    /// The body's values as text, when it is a flat JSON object whose
    /// values are each a string or a number of at most `maxValueLength`
    /// characters. Nil for anything else: a nested object or list, a true
    /// or false, a null, or a body that isn't a JSON object at all. Only
    /// such a body is sent; a sign-in carries a credential or a device
    /// token, never a document.
    public var plainValues: [String]? {
        guard let object = try? JSONDecoder().decode([String: PlainValue].self, from: body) else { return nil }
        let values = object.keys.sorted().compactMap { object[$0]?.text }
        return values.allSatisfy({ $0.count <= Self.maxValueLength }) ? values : nil
    }

    /// One value of a sign-in body: a string, or a number as text. Anything
    /// else fails to decode, so the whole body is refused.
    private struct PlainValue: Decodable {
        let text: String

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) {
                text = string
            } else if let whole = try? value.decode(Int64.self) {
                text = String(whole)
            } else {
                text = String(try value.decode(Double.self))
            }
        }
    }

    /// The hop's address under `endpoint`, or nil when `path` isn't plain.
    public func url(under endpoint: URL) -> URL? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard !segments.isEmpty, segments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".." && segment.allSatisfy { plain.contains($0) }
        }) else { return nil }
        return endpoint.appendingPathComponent(path)
    }
}

/// Sign-in for the cloud model. There are no keys or tokens in this code,
/// and the default does nothing.
///
/// Nothing here can reach the network. Every method is synchronous and
/// only reads or keeps what is on this device, such as a token in the
/// Keychain. A sign-in that needs the network says so with `signIn(for:)`,
/// and `CloudModel` makes it a hop in the preview: the person sees where it
/// goes and the name of each value it carries, and only their yes sends it.
///
/// Sign-in values are covered on the card and never spoken, since they are
/// secrets, so the person can't read them. That is why they may carry only
/// credentials or a device token, never anything from a chat, the notes or
/// the private words (`CloudWords.askPoints` promises it). `CloudModel`
/// holds every implementation to it: a value the current `Redactor` would
/// change, or a sign-in body that isn't a flat object of short values
/// (`CloudSignIn.plainValues`), is refused before anything is shown or sent.
public protocol CloudAuth: Sendable {
    /// Headers for a message, asked while its preview is built. Every one
    /// is shown in the preview, its value covered. A reserved name
    /// (`CloudHeaders.reserved`) is refused. Only credentials or a device
    /// token, never chat, notes or private words.
    func headers(for url: URL) -> [String: String]

    /// The sign-in to send before the next message, or nil when none is
    /// needed. Asked while the preview is built, like `headers(for:)`.
    /// Its headers and body carry only credentials or a device token,
    /// never chat, notes or private words.
    func signIn(for endpoint: URL) -> CloudSignIn?

    /// The answer to a sign-in hop, after the person's yes sent it. Kept on
    /// this device for the next message's headers, which that message's own
    /// preview shows. A header learned here never changes the message the
    /// same yes sends, since that message was shown before it was learned.
    /// Only handed over while the chat is still open and the cloud still on,
    /// checked under the chat's lock (`CloudChatSession.handOver`), so a
    /// switch off or Forget everything that ends the chat is never followed
    /// by a late hand over that `forget()` would miss.
    func signedIn(_ answer: Data)

    /// Lets go of everything `signedIn` kept, such as a token. Called when
    /// the cloud is turned off and by Forget everything.
    func forget()
}

extension CloudAuth {
    public func signIn(for endpoint: URL) -> CloudSignIn? { nil }
    public func signedIn(_ answer: Data) {}
    public func forget() {}
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
    /// Forget everything ended this chat. Nothing more goes from it.
    case ended
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
///    gets less private: see `CloudChatSession`.
/// 3. The person sees the exact request, and any sign-in hop before it,
///    and chooses to send them or not.
/// 4. Only then do those same bytes go to the transport, once each.
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
    package let session: CloudChatSession

    /// `redactor` is asked for each reply, so newly saved notes and private
    /// words count right away; it throws when they can't be read. `isOn` is
    /// checked before building a request and again before each hop is sent,
    /// so turning the setting off stops a reply already waiting in the
    /// preview. It throws when the setting can't be read, which is not the
    /// same as off: nothing is sent, and the chat says it couldn't read them.
    /// `session` is this chat's, so whoever made it can end the chat.
    public init(
        endpoint: URL,
        transport: any CloudTransport,
        reviewer: any CloudReviewing,
        auth: any CloudAuth = NoCloudAuth(),
        redactor: @escaping @Sendable () throws -> Redactor = { Redactor() },
        isOn: @escaping @Sendable () throws -> Bool = { true },
        session: CloudChatSession = CloudChatSession()
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.reviewer = reviewer
        self.auth = auth
        self.redactor = redactor
        self.isOn = isOn
        self.session = session
    }

    /// Words in a cloud chat leave the device, so no line read from this
    /// model promises the device. `ModelChoice` hands out the same value
    /// before a cloud chat exists.
    public static let place = PrivacyPlace.mayLeaveDevice

    public var runsOnDevice: Bool { Self.place.staysOnDevice }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        try session.checkOpen()
        try checkOn()
        let current: Redactor
        do {
            current = try self.redactor()
        } catch {
            // Without the notes and private words it isn't known what to
            // take out, so nothing goes.
            throw CloudModelError.notesUnreadable
        }
        let preview = try Self.preview(
            for: transcript, endpoint: endpoint, redactor: try session.widened(by: current),
            headers: auth.headers(for: Self.url(for: endpoint)), signIn: auth.signIn(for: endpoint)
        )
        guard await reviewer.review(preview) == .send else { throw CloudModelError.notSent }
        // Each hop is the very request the person saw, unchanged, and each
        // is checked again just before it goes.
        if let signIn = preview.signIn {
            try readyToSend()
            let answer = try await session.send(signIn, through: transport)
            // Forget everything or a switch off may have come while it was
            // on the wire; then nothing it brought back is kept. Checked
            // and handed over under the chat's lock, so neither can land
            // between the check and the hand over.
            try session.handOver {
                try checkOn()
                auth.signedIn(answer)
            }
        }
        try readyToSend()
        let data = try await session.send(preview.request, through: transport)
        guard let reply = try? JSONDecoder().decode(CloudPayload.Reply.self, from: data) else {
            throw CloudModelError.unreadableReply
        }
        return reply.reply
    }

    /// Still asked for, still on, and the chat still open.
    private func readyToSend() throws {
        try Task.checkCancellation()
        try checkOn()
        try session.checkOpen()
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

    /// Builds the request for `transcript`, redacted, without sending it,
    /// and the `signIn` hop before it when there is one. Throws `staysHere`
    /// for anything touched by words of crisis, and refuses a reserved
    /// header name in either. Refuses sign-in that may carry more than a
    /// credential: a body that isn't a flat object of short values
    /// (`signInBodyRefused`), or any sign-in value, in a header or the
    /// body, that `redactor` would change (`signInCarriesPersonalDetails`).
    /// Those values are covered on the card, so a name or private word in
    /// one would go unseen.
    public static func preview(
        for transcript: [ChatTurn],
        endpoint: URL,
        redactor: Redactor,
        headers: [String: String] = [:],
        signIn: CloudSignIn? = nil
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
        var signInValues = Array(headers.values)
        let signInRequest = try signIn.map {
            guard let url = $0.url(under: endpoint) else { throw CloudTransportError.signInPathRefused($0.path) }
            guard let values = $0.plainValues else { throw CloudTransportError.signInBodyRefused }
            signInValues += values + $0.headers.values
            return CloudRequest(url: url, headers: try CloudHeaders.merged(with: $0.headers), body: $0.body)
        }
        if signInValues.contains(where: { !redactor.redact($0).isUnchanged }) {
            throw CloudTransportError.signInCarriesPersonalDetails
        }
        return CloudPreview(
            signIn: signInRequest,
            request: CloudRequest(url: url(for: endpoint), headers: try CloudHeaders.merged(with: headers), body: body),
            hidden: hidden
        )
    }
}

/// One cloud chat on this device: every name and private word it has
/// hidden so far, the sends it has on the wire, and whether Forget
/// everything ended it.
///
/// Each request re-sends the earlier turns, redacted again with the notes
/// and private words as they are now. If the person then asks for more
/// privacy, by removing a private word or deleting a note, a plain
/// re-redaction would send those earlier turns with "Sam" or "lemon cake"
/// back in the clear. So each request is redacted with the union of
/// everything this chat has hidden before and everything the current list
/// hides: a privacy action never makes a later request in an open chat
/// less private. A new chat starts from the current list alone.
///
/// The union is held in memory only, for as long as the chat is open. It is
/// never written anywhere and never sent; it is only used to hide words.
///
/// Forget everything ends the chat (`end`): the union is dropped, any send
/// still on the wire is cancelled, and nothing more goes from it. So once
/// Forget everything says the private words are erased, no copy of them is
/// left in any chat, which is what `CloudWords.privateDetail` promises.
/// Turning the cloud off ends it the same way (`end(because: .off)`), so a
/// sign-in answer still on the wire is never handed over after sign-in was
/// told to forget.
public final class CloudChatSession: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden = Redactor()
    /// Why the chat ended, which every later send throws. Nil while open.
    private var endedBy: CloudModelError?
    private var ended: Bool { endedBy != nil }
    private var onTheWire: [UUID: Task<Data, Error>] = [:]
    private let handingOver: @Sendable () -> Void

    /// `handingOver` is told just before each request is handed to the
    /// transport, so the owner knows something may have left this session.
    public init(handingOver: @escaping @Sendable () -> Void = {}) {
        self.handingOver = handingOver
    }

    /// Everything this chat has hidden so far.
    package var hiddenSoFar: Redactor { lock.withLock { hidden } }

    public var hasEnded: Bool { lock.withLock { ended } }

    /// How many requests are on the wire now.
    package var sendsOnTheWire: Int { lock.withLock { onTheWire.count } }

    /// True once the chat has hidden anything or has a send on the wire,
    /// so ending it would let go of something.
    public var holdsAnything: Bool {
        lock.withLock { !hidden.names.isEmpty || !hidden.privateWords.isEmpty || !onTheWire.isEmpty }
    }

    func checkOpen() throws {
        if let endedBy = lock.withLock({ endedBy }) { throw endedBy }
    }

    /// Runs `handOver` under the chat's lock, unless the chat has ended, so
    /// `end` can't come between what it checks and what it hands over.
    func handOver(_ handOver: () throws -> Void) throws {
        try lock.withLock {
            if let endedBy { throw endedBy }
            try handOver()
        }
    }

    /// Adds `current` to what has been hidden so far and returns the whole.
    func widened(by current: Redactor) throws -> Redactor {
        try lock.withLock {
            if let endedBy { throw endedBy }
            hidden = hidden.union(current)
            return hidden
        }
    }

    /// Hands `request` to `transport`, unless the chat has ended. Ending it
    /// cancels the send, as stopping the reply does.
    func send(_ request: CloudRequest, through transport: any CloudTransport) async throws -> Data {
        let id = UUID()
        let task: Task<Data, Error> = try lock.withLock {
            if let endedBy { throw endedBy }
            handingOver()
            let task = Task { try await transport.send(request) }
            onTheWire[id] = task
            return task
        }
        defer { lock.withLock { onTheWire[id] = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ends the chat for good: drops what it has hidden so far, cancels any
    /// send on the wire, and refuses every later one with `reason`: `ended`
    /// for Forget everything, `off` for a switch off. A chat ended both
    /// ways says `ended`.
    public func end(because reason: CloudModelError = .ended) {
        let sends: [Task<Data, Error>] = lock.withLock {
            if endedBy == nil || reason == .ended { endedBy = reason }
            hidden = Redactor()
            let sends = Array(onTheWire.values)
            onTheWire = [:]
            return sends
        }
        for send in sends { send.cancel() }
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
        settings.isOn(for: endpoint)
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

    /// The real session, with `protocols` answering in place of the
    /// network, one session for every send, so a test can see what the
    /// system itself adds from one request to the next.
    package init(answeringWith protocols: [AnyClass]) {
        let session = Self.makeSession(protocols: protocols)
        self.init(load: { request in try await session.data(for: request, delegate: RefusesRedirects()) })
    }

    public func send(_ request: CloudRequest) async throws -> Data {
        // Without the fixed User-Agent and Accept-Language the system would
        // add its own, which name the device and the person's languages and
        // were never shown. Such a request is refused, not quietly fixed, so
        // what goes is always exactly what was shown.
        if let name = request.headers.keys.sorted().first(where: { CloudHeaders.reserved.contains($0.lowercased()) }) {
            throw CloudTransportError.reservedHeader(name)
        }
        guard request.headers == (try? CloudHeaders.merged(with: request.headers)) else {
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
        makeSession(protocols: [])
    }

    /// `protocols` go ahead of the system's own, for tests only.
    static func makeSession(protocols: [AnyClass]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = nil
        if !protocols.isEmpty {
            configuration.protocolClasses = protocols + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }

    private static let live: Load = { request in
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request, delegate: RefusesRedirects())
    }
}

public enum CloudTransportError: Error, Equatable, Sendable {
    /// The request lacked the fixed headers. Nothing was sent.
    case headersNotShown
    /// The request carried a name URLSession reserves
    /// (`CloudHeaders.reserved`), which could go differently from how it was
    /// shown. Nothing was sent.
    case reservedHeader(String)
    /// A sign-in path that wasn't plain segments under the address
    /// (`CloudSignIn.path`). Nothing was shown or sent.
    case signInPathRefused(String)
    /// A sign-in body that wasn't a flat object of short values
    /// (`CloudSignIn.plainValues`). Nothing was shown or sent.
    case signInBodyRefused
    /// A sign-in value the redactor would change: it holds a name, a
    /// private word or another personal detail. Nothing was shown or sent.
    case signInCarriesPersonalDetails
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
