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

    /// Every header line the preview shows, in name order: `headers`, the
    /// Host and Content-Length URLSession adds from the address and the
    /// body, and the lines it adds to every request (`systemLines`).
    /// `CloudHeaders` refuses all of those names from anywhere else, so
    /// these are the only values they can have.
    public static func shownHeaders(url: URL, headers: [String: String], body: Data) -> [(name: String, value: String)] {
        var all = headers.merging(systemLines) { _, system in system }
        all["Host"] = hostLine(for: url)
        all["Content-Length"] = String(body.count)
        return all.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { (name: $0.key, value: $0.value) }
    }

    /// The lines URLSession adds to every request whatever it is given, as
    /// a listener on this Mac's loopback address sees them over HTTP/1.1
    /// (`theWireCarriesExactlyTheHeaderLinesTheCardShows`): no-cache, from
    /// the request's cache policy, and keep-alive. Neither says anything
    /// of the person or the device, and both are shown. That test speaks
    /// HTTP/1.1 only, so it is over HTTP/1.1 that the card is shown to hold
    /// every line that goes. Over HTTP/2 the connection line is left out,
    /// and a newer system may add lines of its own, such as `priority`,
    /// that the card doesn't show; there it holds every header we set, and
    /// no test covers the rest.
    public static let systemLines: [String: String] = [
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
    ]

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
        "host", "content-length", "connection", "transfer-encoding", "cookie", "cache-control",
    ]

    /// `auth`'s headers with the fixed ones on top. A sign-in header can't
    /// replace a fixed one, in any letter case, and a reserved name is
    /// refused outright, so nothing is sent. So is a header URLSession
    /// could send differently from how the card draws it
    /// (`signInHeaderRefused`): a name that isn't a short token
    /// (`CloudSignIn.isToken`), two names that differ only in letter case,
    /// which would show as two lines and go as one, or a value with a line
    /// break in it, which the system drops or refuses.
    public static func merged(with auth: [String: String]) throws -> [String: String] {
        if let name = auth.keys.sorted().first(where: { reserved.contains($0.lowercased()) }) {
            throw CloudTransportError.reservedHeader(name)
        }
        if let name = auth.keys.sorted().first(where: { !CloudSignIn.isToken($0) }) {
            throw CloudTransportError.signInHeaderRefused(name)
        }
        var seen: Set<String> = []
        for name in auth.keys.sorted() where !seen.insert(name.lowercased()).inserted {
            throw CloudTransportError.signInHeaderRefused(name)
        }
        if let name = auth.keys.sorted().first(where: { name in
            auth[name]?.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } == true
        }) {
            throw CloudTransportError.signInHeaderRefused(name)
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
/// first. Every header we set is on this screen, and so are the lines
/// URLSession adds itself over HTTP/1.1 (`CloudRequest.systemLines`),
/// which carry nothing of the person; over HTTP/2 the system may add a
/// line the card doesn't show. Its session keeps no cookie, cache or saved
/// password and adds none
/// (`URLSessionCloudTransport.makeSession`), so a cookie set by a sign-in
/// answer never rides on the message.
public struct CloudPreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The sign-in hop that goes first, if the cloud needs one.
    public let signIn: CloudRequest?
    public let request: CloudRequest
    public let hidden: [Redaction.Kind: Int]
    /// Asked by a summary's work, not by a chat. Set by the code that built
    /// the request, never read from its words, so nothing a person types
    /// in a chat can make it look like a summary's.
    public let forSummary: Bool
    /// The summary's run that asked, so each run's preview is its own on
    /// Today's gate (`CloudYes.run`). Nil for a chat.
    public let run: String?

    public init(id: UUID = UUID(), signIn: CloudRequest? = nil, request: CloudRequest, hidden: [Redaction.Kind: Int],
                forSummary: Bool = false, run: String? = nil) {
        self.id = id
        self.signIn = signIn
        self.request = request
        self.hidden = hidden
        self.forSummary = forSummary
        self.run = run
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
/// Tests use a fake that records requests. No test or CI run reaches
/// anything off the machine it runs on: the one test that sends for real
/// (`theWireCarriesExactlyTheHeaderLinesTheCardShows`) sends only to a
/// listener on that machine's loopback address.
public protocol CloudTransport: Sendable {
    /// Hands `request` over before it returns, and gives back the wait for
    /// its answer. Cancelling the wait stops the send. Whatever the caller
    /// holds while calling this covers the hand over itself: `CloudModel`
    /// calls it under `PrivacyChanges`, after its last check, so a private
    /// word saved once the lock is let go was saved after the request had
    /// gone. Nothing of the request may wait to be handed over later, as
    /// in a task that hasn't run yet.
    func start(_ request: CloudRequest) -> Task<Data, Error>
}

extension CloudTransport {
    /// Starts `request` and waits for its answer. Cancelling the wait
    /// stops the send.
    public func send(_ request: CloudRequest) async throws -> Data {
        let call = start(request)
        return try await withTaskCancellationHandler {
            try await call.value
        } onCancel: {
            call.cancel()
        }
    }
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

    /// The longest value a sign-in body may hold, in characters. Only a
    /// bound on shape: a value this long with no name in it passes the
    /// redactor, so what keeps it to a credential is `CloudAuth`'s
    /// contract.
    public static let maxValueLength = 512

    /// The body part that carries Apple's identity token, the one value
    /// allowed past `maxValueLength`. Sign in with Apple's token is a
    /// signed JWT, usually well over 512 characters, and the server checks
    /// it once and keeps only the anonymous user ID it names. Every other
    /// part keeps the short limit, and the token is held to the same
    /// checks as any value: the redactor must leave it unchanged, so a
    /// token that by chance looks like a phone number is refused, not sent.
    public static let identityTokenField = "identityToken"

    /// The longest identity token, in characters: room for Apple's token
    /// with its header and signature, and no more.
    public static let maxIdentityTokenLength = 4096

    /// The longest value the part named `name` may hold.
    public static func maxLength(of name: String) -> Int {
        name == identityTokenField ? maxIdentityTokenLength : maxValueLength
    }

    /// The longest name a sign-in body part or header may have.
    public static let maxNameLength = 64

    /// True for a name a sign-in may use, as a body part or a header: one
    /// to `maxNameLength` ASCII letters, digits, `-` or `_`. Nothing else,
    /// so a name can't hold a sentence, and can't draw a line of its own
    /// on the card.
    public static func isToken(_ name: String) -> Bool {
        (1...maxNameLength).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The body as it is checked, shown and sent: each part's name and its
    /// value, when the body is a flat JSON object whose names are tokens
    /// (`isToken`) and whose values are each a string of at most
    /// `maxLength(of:)` characters: `maxValueLength`, or
    /// `maxIdentityTokenLength` for `identityTokenField` alone. Nil for
    /// anything else: a number, a
    /// nested object or list, a true or false, a null, or a body that
    /// isn't a JSON object at all. A sign-in carries a credential or a
    /// device token, never a document. A number is refused rather than
    /// sent as text, so a server that reads a number never gets a string
    /// in its place; sign-in writes it as a string itself.
    ///
    /// `body` itself is never sent. What goes is `encoded(fields)`, built
    /// from these very values, so a duplicate name can't send anything
    /// that wasn't checked.
    public var fields: [String: String]? {
        guard let fields = try? JSONDecoder().decode([String: String].self, from: body) else { return nil }
        guard fields.keys.allSatisfy(Self.isToken),
              fields.allSatisfy({ $0.value.count <= Self.maxLength(of: $0.key) }) else { return nil }
        return fields
    }

    /// `fields` as the bytes that go: a flat JSON object of strings, its
    /// names in order.
    public static func encoded(_ fields: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
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
/// holds every implementation to it as far as it can see: a value or a
/// name the current `Redactor` would change, a name that isn't a short
/// token, or a sign-in body that isn't a flat object of short values
/// (`CloudSignIn.fields`), is refused before anything is shown or sent.
///
/// Those checks catch what the redactor knows, not everything. A value of
/// up to `CloudSignIn.maxLength(of:)` characters with no known name,
/// private word or detail in it passes, and so does another spelling of a
/// private word. That a value is only ever a credential or a device token
/// is this protocol's contract, kept by the first-party code that
/// implements it.
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
    /// Only handed over while the cloud is still on and the chat still
    /// open, the second checked under the chat's lock
    /// (`CloudChatSession.handOver`). A switch off and Forget everything
    /// each end the chat before `forget()`, so neither is ever followed by
    /// a late hand over that `forget()` would miss. Called with the chat's
    /// lock held, so it must not reach back into the chat.
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
    /// Forget everything ended this chat. Nothing more goes from it.
    case ended
    /// A switch off ended this chat, and the cloud has been turned on again
    /// since. Nothing more goes from it; a new chat can use the cloud.
    case endedByOff
    /// That something was handed to the cloud couldn't be noted on this
    /// device, so a later Forget everything couldn't say a copy left.
    /// Nothing was sent.
    case notRecorded
    /// A sign-in hop went to the cloud, and then the message didn't: it was
    /// not sent, withdrawn, switched off, or couldn't be checked or noted.
    /// Only the sign-in went, which carries no chat, notes or private words,
    /// so nothing here may say that nothing went.
    case stoppedAfterSignIn
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
/// 4. Only then do those same bytes go to the transport, once each. If
///    the notes or private words change before a hop goes, nothing more of
///    that preview goes, and a fresh one asks again.
public struct CloudModel: ModelClient {
    /// Where requests go, under the configured address.
    public static let path = "v1/reply"

    public let endpoint: URL
    private let transport: any CloudTransport
    private let reviewer: any CloudReviewing
    private let auth: any CloudAuth
    private let redactor: @Sendable () throws -> Redactor
    private let isOn: @Sendable () throws -> Bool
    /// Held while each hop is checked against the notes and private words
    /// and handed to the transport, so neither changes in between.
    private let privacyChanges: PrivacyChanges
    /// Shared by every copy of this model, so by the whole chat.
    package let session: CloudChatSession

    /// `redactor` is asked for each reply, so newly saved notes and private
    /// words count right away; it throws when they can't be read. `isOn` is
    /// checked before building a request, as its preview goes on screen,
    /// again before each hop is sent and before a sign-in answer is handed
    /// over, so turning the setting off stops a reply already waiting in the
    /// preview or still on its way there. It is never called with the
    /// chat's lock held, so it may read files or reach into the chat. It
    /// throws when the setting can't be read, which is not the same as off:
    /// nothing is sent, and the chat says it couldn't read them.
    /// `privacyChanges` is the one every writer of the notes and private
    /// words takes (`MemoryStore.privacyChanges`), so a word saved just
    /// before a hop goes waits until it has gone, or stops it.
    /// `session` is this chat's, so whoever made it can end the chat.
    public init(
        endpoint: URL,
        transport: any CloudTransport,
        reviewer: any CloudReviewing,
        auth: any CloudAuth = NoCloudAuth(),
        redactor: @escaping @Sendable () throws -> Redactor = { Redactor() },
        isOn: @escaping @Sendable () throws -> Bool = { true },
        privacyChanges: PrivacyChanges = PrivacyChanges(),
        session: CloudChatSession = CloudChatSession()
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.reviewer = reviewer
        self.auth = auth
        self.redactor = redactor
        self.isOn = isOn
        self.privacyChanges = privacyChanges
        self.session = session
    }

    /// Words in a cloud chat leave the device, so no line read from this
    /// model promises the device. `ModelChoice` hands out the same value
    /// before a cloud chat exists.
    public static let place = PrivacyPlace.mayLeaveDevice

    public var runsOnDevice: Bool { Self.place.staysOnDevice }

    /// Each pass shows a preview and, on its yes, sends its hops. A pass
    /// that finds the notes or private words changed before a hop goes
    /// drops every hop not yet sent, and the next pass redacts afresh and
    /// asks for a new yes. Each pass waits on the person, so they bound it.
    ///
    /// A chat a switch off ended says so once the cloud is on again
    /// (`endedByOff`), never that the cloud is off while it reads on.
    ///
    /// Once a sign-in hop has gone, in this pass or an earlier one, a
    /// message that then doesn't go says so (`stoppedAfterSignIn`), never
    /// that nothing went. That covers a refusal by the transport or the
    /// preview, such as a sign-in value that now holds a private word
    /// saved while the hop was on the wire, and a stop, as both read as
    /// nothing having left.
    public func reply(to transcript: [ChatTurn]) async throws -> String {
        var signInWent = false
        do {
            while true {
                if let reply = try await replyOnce(to: transcript, signInWent: &signInWent) { return reply }
            }
        } catch let error as CloudModelError where signInWent && Self.saysNothingWent(error) {
            throw CloudModelError.stoppedAfterSignIn
        } catch is CloudTransportError where signInWent {
            throw CloudModelError.stoppedAfterSignIn
        } catch is CancellationError where signInWent {
            throw CloudModelError.stoppedAfterSignIn
        } catch CloudModelError.off where session.endedBySwitchOff && (try? isOn()) == true {
            throw CloudModelError.endedByOff
        }
    }

    /// The reasons a message didn't go whose words say that nothing did.
    static func saysNothingWent(_ error: CloudModelError) -> Bool {
        switch error {
        case .notSent, .withdrawn, .off, .endedByOff, .notesUnreadable, .notRecorded: true
        case .staysHere, .unreadableReply, .ended, .stoppedAfterSignIn: false
        }
    }

    /// One preview and its hops. Nil when the privacy inputs changed after
    /// the preview was redacted, before everything was sent: nothing more
    /// of it goes. `signInWent` is set once a sign-in hop is handed over.
    private func replyOnce(to transcript: [ChatTurn], signInWent: inout Bool) async throws -> String? {
        try session.checkOpen()
        try checkOn()
        // The version of the privacy inputs this preview is redacted with:
        // the notes' names and the private words as they are now, read and
        // added to what the chat has hidden under `privacyChanges`, so
        // Forget everything, which ends the chat under the same lock, can't
        // land between the two and leave erased words in the chat.
        let (current, widened) = try privacyChanges.handOver {
            let current = try readRedactor()
            return (current, try session.widened(by: current))
        }
        let preview = try Self.preview(
            for: transcript, endpoint: endpoint, redactor: widened,
            headers: auth.headers(for: Self.url(for: endpoint)), signIn: auth.signIn(for: endpoint),
            forSummary: CloudAsk.forSummary,
            run: CloudAsk.forSummary ? CloudYes.run : nil
        )
        // Checked again where the preview goes on screen: the setting may
        // have been switched off since the check above. Unreadable counts as
        // off there, so nothing shows that couldn't be sent.
        let isOn = self.isOn
        // A chat ended by a switch off stays ended when the cloud is turned
        // on again, so its preview never shows only to have Send refused.
        let chat = session
        switch await reviewer.review(preview, whileOn: { !chat.hasEnded && (try? isOn()) == true }) {
        case .send: break
        case .cancel: throw CloudModelError.notSent
        case .withdrawn: throw CloudModelError.withdrawn
        }
        try readyToSend()
        // Past the yes: a summary's work notes that what it read may go, or
        // refuses a yes that went stale, as for a summary stopped since.
        if let heard = CloudYes.heard, !heard() { throw CancellationError() }
        // Under way from the yes until the reply is back, so Forget
        // everything ends this chat even between sends, when nothing is on
        // the wire and nothing may be hidden yet.
        return try await session.replying {
            // Each hop is the very request the person saw, unchanged, and
            // each is checked again just before it goes.
            if let signIn = preview.signIn {
                try readyToSend()
                guard let handed = try handOver(signIn, ifStill: current) else { return nil }
                signInWent = true
                let answer = try await session.finish(handed)
                // A switch off or Forget everything may have come while it
                // was on the wire; then nothing it brought back is kept.
                // `isOn` is read first, off the chat's lock, so it may take
                // its time or touch the chat. Either one ends the chat
                // before sign-in forgets, and the hand over checks that
                // under the lock, so neither can land between the two.
                try checkOn()
                try session.handOver { auth.signedIn(answer) }
            }
            try readyToSend()
            // A private word added or a note saved while sign-in was on the
            // wire isn't hidden in this message, so it never goes.
            guard let handed = try handOver(preview.request, ifStill: current) else { return nil }
            let data = try await session.finish(handed)
            guard let reply = try? JSONDecoder().decode(CloudPayload.Reply.self, from: data) else {
                throw CloudModelError.unreadableReply
            }
            return reply.reply
        }
    }

    /// Hands `request` to the transport while the notes and private words
    /// still make `current`. The check and the hand over both run under
    /// `privacyChanges`, so nothing saved between the two can miss the
    /// check. Nil, with nothing handed over, once they have changed.
    private func handOver(_ request: CloudRequest, ifStill current: Redactor) throws -> CloudChatSession.Handed? {
        try privacyChanges.handOver {
            guard try readRedactor() == current else { return nil }
            return try session.handOff(request, through: transport)
        }
    }

    /// The redactor for the notes and private words as they are now.
    private func readRedactor() throws -> Redactor {
        do {
            return try redactor()
        } catch {
            // Without the notes and private words it isn't known what to
            // take out, so nothing goes.
            throw CloudModelError.notesUnreadable
        }
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
    /// header name in either, or a sign-in header that could go other than
    /// it is drawn (`CloudHeaders.merged`). Refuses sign-in that may carry
    /// more than a credential: a body that isn't a flat object of short
    /// values (`signInBodyRefused`), or any sign-in name or value, in a
    /// header or the body, that `redactor` would change
    /// (`signInCarriesPersonalDetails`). The values are covered on the
    /// card, so a name or private word in one would go unseen.
    ///
    /// The hop's body is `CloudSignIn.encoded` of the checked fields, not
    /// the body sign-in handed over, so what is checked, what the card
    /// draws and what goes are one thing.
    public static func preview(
        for transcript: [ChatTurn],
        endpoint: URL,
        redactor: Redactor,
        headers: [String: String] = [:],
        signIn: CloudSignIn? = nil,
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
        let messageHeaders = try CloudHeaders.merged(with: headers)
        // Names as well as values: a name shows on the card, but it still
        // goes, so a private word can't ride in one either.
        var signInTexts = Array(headers.keys) + Array(headers.values)
        let signInRequest = try signIn.map {
            guard let url = $0.url(under: endpoint) else { throw CloudTransportError.signInPathRefused($0.path) }
            guard let fields = $0.fields else { throw CloudTransportError.signInBodyRefused }
            let hopHeaders = try CloudHeaders.merged(with: $0.headers)
            signInTexts += Array(fields.keys) + Array(fields.values) + Array($0.headers.keys) + Array($0.headers.values)
            return CloudRequest(url: url, headers: hopHeaders, body: try CloudSignIn.encoded(fields))
        }
        if signInTexts.contains(where: { !redactor.redact($0).isUnchanged }) {
            throw CloudTransportError.signInCarriesPersonalDetails
        }
        return CloudPreview(
            signIn: signInRequest,
            request: CloudRequest(url: url(for: endpoint), headers: messageHeaders, body: body),
            hidden: hidden,
            forSummary: forSummary,
            run: run
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
    private let handingOver: @Sendable () throws -> Void

    /// `handingOver` is told just before each request is handed to the
    /// transport, so the owner knows something may have left this session.
    /// When it throws, nothing is handed over and the send fails with
    /// `CloudModelError.notRecorded`, so nothing goes that the owner
    /// couldn't note. It runs under the session's lock, so it must not
    /// touch the session.
    public init(handingOver: @escaping @Sendable () throws -> Void = {}) {
        self.handingOver = handingOver
    }

    /// Everything this chat has hidden so far.
    package var hiddenSoFar: Redactor { lock.withLock { hidden } }

    public var hasEnded: Bool { lock.withLock { ended } }

    /// True when a switch off ended the chat, and Forget everything didn't.
    package var endedBySwitchOff: Bool { lock.withLock { endedBy == .off } }

    /// How many requests are on the wire now.
    package var sendsOnTheWire: Int { lock.withLock { onTheWire.count } }

    /// True once the chat has hidden anything, or while a reply is under
    /// way past its yes (`replying`), on the wire or between sends, so
    /// ending it would let go of something.
    public var holdsAnything: Bool {
        lock.withLock { !hidden.names.isEmpty || !hidden.privateWords.isEmpty || !onTheWire.isEmpty || replies > 0 }
    }

    /// Replies under way past their yes.
    private var replies = 0

    /// Runs `work`, a reply's sends and hand over, counted as under way
    /// the whole time (`holdsAnything`).
    package func replying<T>(_ work: () async throws -> T) async rethrows -> T {
        lock.withLock { replies += 1 }
        defer { lock.withLock { replies -= 1 } }
        return try await work()
    }

    func checkOpen() throws {
        if let endedBy = lock.withLock({ endedBy }) { throw endedBy }
    }

    /// Runs `handOver` under the chat's lock, unless the chat has ended, so
    /// `end` can't come between the check and the hand over. `handOver`
    /// runs with the lock held, so it must not touch this chat.
    package func handOver(_ handOver: () throws -> Void) throws {
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

    /// A request `handOff` handed to its transport, until `finish`.
    package struct Handed {
        fileprivate let id: UUID
        fileprivate let task: Task<Data, Error>
    }

    /// Hands `request` to `transport`, unless the chat has ended, and waits
    /// for the answer. Ending it cancels the send, as stopping the reply
    /// does.
    package func send(_ request: CloudRequest, through transport: any CloudTransport) async throws -> Data {
        try await finish(try handOff(request, through: transport))
    }

    /// The part of `send` that hands `request` over, with no wait, so a
    /// caller can do it under a lock of its own (`PrivacyChanges`). The
    /// transport has the request by the time this returns
    /// (`CloudTransport.start`), so that lock covers the hand over itself,
    /// not only a task that would hand it over later. The `handingOver`
    /// callback given at init runs under the session's lock, just before
    /// the request is handed over, so it must not touch the session; the
    /// transport's `start` runs there too. A reply stopped by then hands
    /// nothing over. Always followed by `finish`.
    package func handOff(_ request: CloudRequest, through transport: any CloudTransport) throws -> Handed {
        let id = UUID()
        let task: Task<Data, Error> = try lock.withLock {
            if let endedBy { throw endedBy }
            if Task.isCancelled { throw CancellationError() }
            do { try handingOver() } catch { throw CloudModelError.notRecorded }
            let task = transport.start(request)
            onTheWire[id] = task
            return task
        }
        return Handed(id: id, task: task)
    }

    /// Waits for what `handOff` handed over.
    package func finish(_ handed: Handed) async throws -> Data {
        defer { lock.withLock { onTheWire[handed.id] = nil } }
        let task = handed.task
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
    /// Hands a URLRequest over before it returns, and gives back the wait
    /// for its answer.
    private typealias Begin = @Sendable (URLRequest) -> Task<(Data, URLResponse), Error>
    private let begin: Begin
    /// Plain http to this Mac's own loopback address, for a test's local
    /// listener. Only the test-only init below sets it.
    private let allowsLoopbackHTTP: Bool
    /// This Mac's own IPv4 loopback address. It is written in two parts
    /// because the private check takes any address under Packages/ for a
    /// real one.
    package static let loopbackHost = "127.0" + ".0.1"

    public init() {
        begin = { request in
            let session = Self.makeSession()
            // Let go once the one request it was made for is done.
            defer { session.finishTasksAndInvalidate() }
            return Self.started(request, on: session)
        }
        allowsLoopbackHTTP = false
    }

    /// Tests pass a fake `load` that records the URLRequest. It runs in a
    /// task of its own, so it sees the request just after `start`, not
    /// within it.
    package init(load: @escaping Load) {
        begin = { request in Task { try await load(request) } }
        allowsLoopbackHTTP = false
    }

    #if DEBUG
    /// The real session, one for every send, so a test can see what the
    /// system itself adds from one request to the next. Takes plain http
    /// to `loopbackHost` too, which a test's local listener needs and
    /// nothing else ever gets. Debug only, so no shipped build has it.
    package init(loopbackForTests: Void) {
        let session = Self.makeSession()
        begin = { request in Self.started(request, on: session) }
        allowsLoopbackHTTP = true
    }
    #endif

    /// Hands `request` to `session` before it returns, so the system has
    /// it by then, and gives back the wait for its answer. Cancelling the
    /// wait cancels the request.
    private static func started(_ request: URLRequest, on session: URLSession) -> Task<(Data, URLResponse), Error> {
        let answer = Answer()
        let task = session.dataTask(with: request) { data, response, error in answer.settle(data, response, error) }
        task.resume()
        return Task {
            try await withTaskCancellationHandler {
                try await answer.value()
            } onCancel: {
                task.cancel()
            }
        }
    }

    /// The answer to one started request, kept until it is waited for.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(Data, URLResponse), Error>?
        private var waiting: CheckedContinuation<(Data, URLResponse), Error>?

        func settle(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
            let settled: Result<(Data, URLResponse), Error>
            if let error {
                settled = .failure(error)
            } else if let response {
                settled = .success((data ?? Data(), response))
            } else {
                settled = .failure(URLError(.badServerResponse))
            }
            let waiter: CheckedContinuation<(Data, URLResponse), Error>? = lock.withLock {
                guard result == nil else { return nil }
                result = settled
                defer { waiting = nil }
                return waiting
            }
            waiter?.resume(with: settled)
        }

        func value() async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<(Data, URLResponse), Error>? = lock.withLock {
                    if let result { return result }
                    waiting = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }

    /// Only https leaves, whatever address a request was built for:
    /// `CloudEndpoint` takes no other, and this holds even if something
    /// skipped it.
    package func isSecure(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (allowsLoopbackHTTP && scheme == "http" && url.host == Self.loopbackHost)
    }

    /// Refuses a request that could go other than shown, with nothing
    /// handed over; anything else is handed to the system before this
    /// returns.
    public func start(_ request: CloudRequest) -> Task<Data, Error> {
        do {
            try check(request)
        } catch {
            return Task { throw error }
        }
        let call = begin(request.urlRequest)
        return Task {
            let (data, response) = try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
            // A redirect is refused, so it arrives here as a 3xx and fails.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    private func check(_ request: CloudRequest) throws {
        guard isSecure(request.url) else { throw CloudTransportError.notSecure }
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
    }

    /// A session that keeps nothing and adds nothing: no cookies, cache or
    /// saved passwords, no extra headers, every redirect refused, so the
    /// request can't end up anywhere but the address shown, and every
    /// sign-in challenge but the server's own certificate cancelled
    /// (`RefusesRedirects`), so the system never sends it again with a
    /// credential the card didn't show.
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
}

public enum CloudTransportError: Error, Equatable, Sendable {
    /// The request lacked the fixed headers. Nothing was sent.
    case headersNotShown
    /// The request's address wasn't https. Nothing was sent.
    case notSecure
    /// The request carried a name URLSession reserves
    /// (`CloudHeaders.reserved`), which could go differently from how it was
    /// shown. Nothing was sent.
    case reservedHeader(String)
    /// A sign-in path that wasn't plain segments under the address
    /// (`CloudSignIn.path`). Nothing was shown or sent.
    case signInPathRefused(String)
    /// A sign-in body that wasn't a flat object of short values with token
    /// names (`CloudSignIn.fields`). Nothing was shown or sent.
    case signInBodyRefused
    /// A sign-in header that could go other than the card draws it: a
    /// name that isn't a token, two names that differ only in letter case,
    /// or a value with a line break (`CloudHeaders.merged`). Nothing was
    /// shown or sent.
    case signInHeaderRefused(String)
    /// A sign-in value the redactor would change: it holds a name, a
    /// private word or another personal detail. Nothing was shown or sent.
    case signInCarriesPersonalDetails
}

/// Says no to every redirect. A 307 or 308 would carry the same body to
/// another address, maybe another host or plain http, that the person
/// never saw.
///
/// Says no to every sign-in challenge too, but for the check of the
/// server's own certificate, which the system makes as it always does.
/// Taking the default for a 401 or 407 could let the system's own sign-in,
/// such as single sign-on on a managed Mac, send the body again with an
/// Authorization line the card never showed. Cancelled, the request fails
/// and nothing more goes.
public final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public override init() {}

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    /// The default for the server's certificate, and cancel for any other
    /// way of signing in.
    static func disposition(for method: String) -> URLSession.AuthChallengeDisposition {
        method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
    }
}

extension ModelClient {
    /// The cloud chat's session, when this is the cloud model. Read here, in
    /// the cloud client's own file, so no other file names the client.
    package var cloudSession: CloudChatSession? { (self as? CloudModel)?.session }
}
