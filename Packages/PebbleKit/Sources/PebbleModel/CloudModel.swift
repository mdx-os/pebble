import Foundation
import PebbleCore

/// One request to the cloud model, exactly as it leaves the device.
public struct CloudRequest: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The body as the person reads it in the preview. It is the same bytes
    /// that are sent, read as text.
    public var text: String { String(decoding: body, as: UTF8.self) }
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

/// Adds sign-in headers to a request. There are no keys or tokens in this
/// code; the default adds nothing.
public protocol CloudAuth: Sendable {
    func headers(for url: URL) async -> [String: String]
}

/// Adds nothing.
public struct NoCloudAuth: CloudAuth {
    public init() {}
    public func headers(for url: URL) async -> [String: String] { [:] }
}

public enum CloudModelError: Error, Equatable, Sendable {
    /// The setting is off, or there is no address. Nothing was sent.
    case off
    /// The person chose not to send. Nothing was sent.
    case notSent
    /// Words of crisis are answered on this device and never sent.
    case staysHere
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
/// way every time. Every `text` has been through `Redactor`. The answer is
/// `{"reply": "..."}`.
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
/// 2. Personal details are taken out on this device by `Redactor`.
/// 3. The person sees the exact request and chooses to send it or not.
/// 4. Only then do those same bytes go to the transport, once.
public struct CloudModel: ModelClient {
    /// Where requests go, under the configured address.
    public static let path = "v1/reply"

    public let endpoint: URL
    private let transport: any CloudTransport
    private let reviewer: any CloudReviewing
    private let auth: any CloudAuth
    private let redactor: @Sendable () -> Redactor
    private let isOn: @Sendable () -> Bool

    /// `redactor` is asked for each reply, so newly saved notes and private
    /// words count right away. `isOn` is checked before building a request
    /// and again before sending, so turning the setting off stops a reply
    /// already waiting in the preview.
    public init(
        endpoint: URL,
        transport: any CloudTransport,
        reviewer: any CloudReviewing,
        auth: any CloudAuth = NoCloudAuth(),
        redactor: @escaping @Sendable () -> Redactor = { Redactor() },
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
        let preview = try Self.preview(
            for: transcript, endpoint: endpoint, redactor: redactor(),
            headers: await auth.headers(for: Self.url(for: endpoint))
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
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        return CloudPreview(request: CloudRequest(url: url(for: endpoint), headers: allHeaders, body: body),
                            hidden: hidden)
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
        guard settings.isOn, let endpoint else { return local }
        return cloud(endpoint)
    }
}

/// Sends requests with URLSession: one POST, no cookies, no cache. Only
/// made once the person has turned the cloud on.
public struct URLSessionCloudTransport: CloudTransport {
    public init() {}

    public func send(_ request: CloudRequest) async throws -> Data {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = request.body
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
