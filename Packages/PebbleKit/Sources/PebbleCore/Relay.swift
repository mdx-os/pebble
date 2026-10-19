import CryptoKit
import Foundation

// The messages of the relay protocol, as docs/RELAY.md writes them. A relay
// is a server the person may choose to hand a bigger task to. These types
// only read and write the messages: nothing here opens a connection.
//
// Decoding is strict where it matters and loose where it doesn't. An
// unknown state, kind, action, answer or receipt kind is refused, as is any
// field past its limit and any id that isn't plain letters and digits. Keys
// this version doesn't know are ignored, so a relay can add one without
// breaking an older app.

/// The protocol's version, its limits and its plain checks.
public enum Relay {
    public static let version = 1

    /// `runId`, `clientRunId`, `questionId` and a key's `id`.
    public static let maxIDLength = 64
    public static let maxBriefLength = 8_000
    public static let maxTools = 16
    public static let maxToolNameLength = 40
    public static let maxMinutes = 120
    public static let maxSteps = 200
    public static let maxStepWordsLength = 280
    public static let maxTargetIDLength = 200
    public static let maxSummaryLength = 500
    public static let maxResultTextLength = 20_000
    public static let maxSources = 20
    public static let maxSourceTitleLength = 200
    public static let maxURLLength = 2_000
    public static let maxArtifacts = 5
    public static let maxArtifactNameLength = 100
    /// One artifact's bytes, after base64 is undone.
    public static let maxArtifactBytes = 1_048_576
    /// All of a result's artifacts together, after base64 is undone.
    public static let maxArtifactsBytes = 4_194_304
    public static let maxReceipts = 1_000
    public static let maxRetryAfterSeconds = 3_600
    public static let maxKeys = 4
    /// A whole body as it arrives. Base64 makes the artifacts a third
    /// bigger, and the rest fits in what is left.
    public static let maxBodyBytes = 8_388_608

    /// 1 to 64 ASCII letters and digits, and nothing else.
    public static func isPlainID(_ text: String) -> Bool {
        (1...maxIDLength).contains(text.utf8.count) && text.utf8.allSatisfy(isLetterOrDigit)
    }

    /// A tool's name: 1 to 40 of lowercase ASCII letters, digits, `.` and
    /// `_`, starting with a letter, such as `web.search`.
    public static func isToolName(_ text: String) -> Bool {
        guard let first = text.utf8.first, (97...122).contains(first),
              text.utf8.count <= maxToolNameLength else { return false }
        return text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 }
    }

    /// A time as `YYYY-MM-DDTHH:MM:SSZ`, in UTC with whole seconds, and a
    /// real date. Kept as written, so a receipt hashes the same bytes on
    /// both ends.
    public static func date(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        let shape = Array("0000-00-00T00:00:00Z".utf8)
        guard bytes.count == shape.count else { return nil }
        for (byte, want) in zip(bytes, shape) {
            if want == 48 { if !(48...57).contains(byte) { return nil } } else if byte != want { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    /// Reads a body, refusing one past `maxBodyBytes` before parsing it.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxBodyBytes else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "the body is over \(maxBodyBytes) bytes"))
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Writes a body with its keys in order.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// 64 lowercase hex digits.
    static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Text in one line: 1 to `limit` code points, no control or direction
    /// characters, no line breaks, and no space at either end.
    static func isLine(_ text: String, limit: Int) -> Bool {
        let scalars = text.unicodeScalars
        guard (1...limit).contains(scalars.count),
              let first = scalars.first, let last = scalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace else { return false }
        return scalars.allSatisfy { !isControl($0) && $0 != "\u{2028}" && $0 != "\u{2029}" }
    }

    /// Text over several lines: up to `limit` code points, and no control
    /// or direction characters but line breaks and tabs.
    static func isText(_ text: String, limit: Int) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count <= limit && scalars.allSatisfy { $0 == "\n" || $0 == "\t" || !isControl($0) }
    }

    /// Control characters, and the ones that turn text around so it reads
    /// differently from how it is stored.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// Lowercase hex for some bytes.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes of lowercase hex, or nil.
    static func bytes(hex text: String) -> Data? {
        guard text.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var high: UInt8?
        for byte in text.utf8 {
            let value: UInt8
            switch byte {
            case 48...57: value = byte - 48
            case 97...102: value = byte - 87
            default: return nil
            }
            if let first = high { data.append(first << 4 | value); high = nil } else { high = value }
        }
        return data
    }
}

/// The error a message throws when it refuses what it read.
private func refused(_ reason: String, _ decoder: Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: reason))
}

// MARK: Starting a run

/// What sort of task the run is.
public enum RelayRunKind: String, Codable, Sendable, CaseIterable {
    /// Reading across many pages to answer a question.
    case research
    /// Several steps with tools.
    case steps
    /// Making something, such as a file.
    case build
}

/// How far the relay may go before it stops on its own.
public struct RelayLimits: Codable, Sendable, Equatable {
    /// 1 to `Relay.maxMinutes`.
    public let maxMinutes: Int
    /// 1 to `Relay.maxSteps`.
    public let maxSteps: Int

    public init(maxMinutes: Int, maxSteps: Int) {
        self.maxMinutes = maxMinutes
        self.maxSteps = maxSteps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxMinutes = try container.decode(Int.self, forKey: .maxMinutes)
        maxSteps = try container.decode(Int.self, forKey: .maxSteps)
        guard (1...Relay.maxMinutes).contains(maxMinutes) else { throw refused("maxMinutes is out of range", decoder) }
        guard (1...Relay.maxSteps).contains(maxSteps) else { throw refused("maxSteps is out of range", decoder) }
    }
}

/// `POST v1/runs`. `brief` is the exact text the person saw in the
/// preview, already through `Redactor`.
public struct RelayRunRequest: Codable, Sendable, Equatable {
    /// Made on the device. The same id twice starts one run.
    public let clientRunId: String
    public let kind: RelayRunKind
    public let brief: String
    /// The tools the run may use, each named once.
    public let tools: [String]
    public let limits: RelayLimits
    public let version: Int

    public init(clientRunId: String, kind: RelayRunKind, brief: String, tools: [String], limits: RelayLimits) {
        self.clientRunId = clientRunId
        self.kind = kind
        self.brief = brief
        self.tools = tools
        self.limits = limits
        version = Relay.version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientRunId = try container.decode(String.self, forKey: .clientRunId)
        kind = try container.decode(RelayRunKind.self, forKey: .kind)
        brief = try container.decode(String.self, forKey: .brief)
        tools = try container.decode([String].self, forKey: .tools)
        limits = try container.decode(RelayLimits.self, forKey: .limits)
        version = try container.decode(Int.self, forKey: .version)
        guard Relay.isPlainID(clientRunId) else { throw refused("clientRunId isn't plain letters and digits", decoder) }
        guard !brief.isEmpty, Relay.isText(brief, limit: Relay.maxBriefLength) else {
            throw refused("brief is empty, too long or has control characters", decoder)
        }
        guard tools.count <= Relay.maxTools, Set(tools).count == tools.count, tools.allSatisfy(Relay.isToolName) else {
            throw refused("tools has too many, a repeat or a name that isn't a tool's", decoder)
        }
        guard version == Relay.version else { throw refused("version \(version) isn't \(Relay.version)", decoder) }
    }
}

// MARK: A run as the relay tells it

public enum RelayRunState: String, Codable, Sendable, CaseIterable {
    case queued, working, needsYou, done, failed, stopped

    /// Done, failed or stopped: nothing more will happen.
    public var isFinished: Bool { [.done, .failed, .stopped].contains(self) }
}

public enum RelayStepState: String, Codable, Sendable, CaseIterable {
    case waiting, working, done, failed, skipped
}

/// One line of the run's progress, as the person reads it.
public struct RelayStep: Codable, Sendable, Equatable {
    public let words: String
    public let state: RelayStepState

    public init(words: String, state: RelayStepState) {
        self.words = words
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decode(String.self, forKey: .words)
        state = try container.decode(RelayStepState.self, forKey: .state)
        guard Relay.isLine(words, limit: Relay.maxStepWordsLength) else { throw refused("words isn't one short line", decoder) }
    }
}

/// Who a question's action goes to. It must read back exactly as a
/// `Recipient` would show it, so the approval sheet shows what was sent.
public struct RelayTarget: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let handle: String

    public init(id: String, name: String, handle: String) {
        self.id = id
        self.name = name
        self.handle = handle
    }

    /// What the device's own approval sheet is built from.
    public var recipient: Recipient { Recipient(id: id, displayName: name, handle: handle) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        handle = try container.decode(String.self, forKey: .handle)
        guard Relay.isLine(id, limit: Relay.maxTargetIDLength) else { throw refused("target id isn't one short line", decoder) }
        guard name.unicodeScalars.count <= 40 else { throw refused("target name is too long", decoder) }
        guard handle.unicodeScalars.count <= 254 else { throw refused("target handle is too long", decoder) }
        let recipient = recipient
        guard recipient.displayName == name else { throw refused("target name wouldn't be shown as written", decoder) }
        guard recipient.handle == handle else { throw refused("target handle wouldn't be shown as written", decoder) }
    }
}

/// Exact money on the wire, in the currency's smallest unit.
public struct RelayPrice: Codable, Sendable, Equatable {
    public let minorUnits: Int
    public let currency: String

    public init(minorUnits: Int, currency: String) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// The same amount the device's approval sheet asks about.
    public var price: Price? {
        guard currency.utf8.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }),
              Locale.commonISOCurrencyCodes.contains(currency) else { return nil }
        return Price(minorUnits: minorUnits, currency: currency)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minorUnits = try container.decode(Int.self, forKey: .minorUnits)
        currency = try container.decode(String.self, forKey: .currency)
        guard price != nil else { throw refused("price isn't positive money in an ISO 4217 currency", decoder) }
    }
}

/// A question the run waits on. The device asks it with its own approval
/// sheet; the relay never answers for the person.
public struct RelayQuestion: Codable, Sendable, Equatable {
    public let questionId: String
    public let price: RelayPrice?
    public let action: ConsequentialAction
    public let target: RelayTarget
    public let summary: String
    /// `YYYY-MM-DDTHH:MM:SSZ`. After it the relay takes the answer as no.
    public let expiresAt: String

    public init(questionId: String, action: ConsequentialAction, target: RelayTarget, summary: String, expiresAt: String, price: RelayPrice? = nil) {
        self.questionId = questionId
        self.price = price
        self.action = action
        self.target = target
        self.summary = summary
        self.expiresAt = expiresAt
    }

    public var proposedAction: ProposedAction {
        ProposedAction(kind: action, recipient: target.recipient, details: summary, price: price?.price)
    }

    public var expires: Date? { Relay.date(expiresAt) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questionId = try container.decode(String.self, forKey: .questionId)
        action = try container.decode(ConsequentialAction.self, forKey: .action)
        price = try container.decodeIfPresent(RelayPrice.self, forKey: .price)
        guard action != .purchase || price != nil else { throw refused("a purchase needs a price", decoder) }
        guard action == .purchase || price == nil else { throw refused("only a purchase may have a price", decoder) }
        target = try container.decode(RelayTarget.self, forKey: .target)
        summary = try container.decode(String.self, forKey: .summary)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        guard Relay.isPlainID(questionId) else { throw refused("questionId isn't plain letters and digits", decoder) }
        guard Relay.isLine(summary, limit: Relay.maxSummaryLength) else { throw refused("summary isn't one line in limit", decoder) }
        guard Relay.date(expiresAt) != nil else { throw refused("expiresAt isn't a UTC time in whole seconds", decoder) }
    }
}

/// A page the result drew on.
public struct RelaySource: Codable, Sendable, Equatable {
    public let title: String
    /// An https address with a host.
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        guard Relay.isLine(title, limit: Relay.maxSourceTitleLength) else { throw refused("title isn't one line in limit", decoder) }
        guard url.utf8.count <= Relay.maxURLLength, url.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),
              let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.isEmpty == false else {
            throw refused("url isn't an https address in limit", decoder)
        }
    }
}

public enum RelayArtifactKind: String, Codable, Sendable, CaseIterable {
    case text, markdown, csv, json, png, pdf
}

/// A file the run made. Its bytes must hash to `sha256`.
public struct RelayArtifact: Codable, Sendable, Equatable {
    /// A plain file name: no folders, and not hidden.
    public let name: String
    public let kind: RelayArtifactKind
    public let sha256: String
    public let bytesBase64: String

    public init(name: String, kind: RelayArtifactKind, bytes: Data) {
        self.name = name
        self.kind = kind
        sha256 = Relay.hex(SHA256.hash(data: bytes))
        bytesBase64 = bytes.base64EncodedString()
    }

    public var bytes: Data { Data(base64Encoded: bytesBase64) ?? Data() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(RelayArtifactKind.self, forKey: .kind)
        sha256 = try container.decode(String.self, forKey: .sha256)
        bytesBase64 = try container.decode(String.self, forKey: .bytesBase64)
        guard Relay.isLine(name, limit: Relay.maxArtifactNameLength), name.unicodeScalars.first != ".",
              !name.unicodeScalars.contains(where: { "/\\:".unicodeScalars.contains($0) }) else {
            throw refused("name isn't a plain file name", decoder)
        }
        guard Relay.isHash(sha256) else { throw refused("sha256 isn't 64 lowercase hex digits", decoder) }
        guard bytesBase64.utf8.count <= (Relay.maxArtifactBytes + 2) / 3 * 4,
              let bytes = Data(base64Encoded: bytesBase64), bytes.count <= Relay.maxArtifactBytes else {
            throw refused("bytesBase64 isn't base64 in limit", decoder)
        }
        guard Relay.hex(SHA256.hash(data: bytes)) == sha256 else { throw refused("the bytes don't hash to sha256", decoder) }
    }
}

/// What a finished run made.
public struct RelayResult: Codable, Sendable, Equatable {
    public let text: String
    public let sources: [RelaySource]
    public let artifacts: [RelayArtifact]

    public init(text: String, sources: [RelaySource], artifacts: [RelayArtifact]) {
        self.text = text
        self.sources = sources
        self.artifacts = artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sources = try container.decode([RelaySource].self, forKey: .sources)
        artifacts = try container.decode([RelayArtifact].self, forKey: .artifacts)
        guard Relay.isText(text, limit: Relay.maxResultTextLength) else { throw refused("text is too long or has control characters", decoder) }
        guard sources.count <= Relay.maxSources else { throw refused("too many sources", decoder) }
        guard artifacts.count <= Relay.maxArtifacts else { throw refused("too many artifacts", decoder) }
        guard artifacts.reduce(0, { $0 + $1.bytes.count }) <= Relay.maxArtifactsBytes else {
            throw refused("the artifacts together are too big", decoder)
        }
    }
}

/// `GET v1/runs/{runId}`, and the answer to every call that changes a run.
public struct RelayRun: Codable, Sendable, Equatable {
    public let runId: String
    public let state: RelayRunState
    public let steps: [RelayStep]
    /// Present exactly when `state` is `needsYou`.
    public let needsYou: RelayQuestion?
    /// Present exactly when `state` is `done`.
    public let result: RelayResult?
    public let receipts: [RelayReceipt]
    /// When to ask again, if the relay says.
    public let retryAfterSeconds: Int?

    public init(runId: String, state: RelayRunState, steps: [RelayStep], needsYou: RelayQuestion? = nil,
                result: RelayResult? = nil, receipts: [RelayReceipt], retryAfterSeconds: Int? = nil) {
        self.runId = runId
        self.state = state
        self.steps = steps
        self.needsYou = needsYou
        self.result = result
        self.receipts = receipts
        self.retryAfterSeconds = retryAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decode(String.self, forKey: .runId)
        state = try container.decode(RelayRunState.self, forKey: .state)
        steps = try container.decode([RelayStep].self, forKey: .steps)
        needsYou = try container.decodeIfPresent(RelayQuestion.self, forKey: .needsYou)
        result = try container.decodeIfPresent(RelayResult.self, forKey: .result)
        receipts = try container.decode([RelayReceipt].self, forKey: .receipts)
        retryAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        guard Relay.isPlainID(runId) else { throw refused("runId isn't plain letters and digits", decoder) }
        guard steps.count <= Relay.maxSteps else { throw refused("too many steps", decoder) }
        guard (state == .needsYou) == (needsYou != nil) else { throw refused("needsYou must come with its state, and only then", decoder) }
        guard (state == .done) == (result != nil) else { throw refused("result must come with done, and only then", decoder) }
        guard receipts.count <= Relay.maxReceipts else { throw refused("too many receipts", decoder) }
        try checkRetry(retryAfterSeconds, decoder)
    }
}

private func checkRetry(_ seconds: Int?, _ decoder: Decoder) throws {
    if let seconds, !(1...Relay.maxRetryAfterSeconds).contains(seconds) {
        throw refused("retryAfterSeconds is out of range", decoder)
    }
}

// MARK: Answering

public enum RelayAnswerChoice: String, Codable, Sendable, CaseIterable {
    case yes, no
}

/// `POST v1/runs/{runId}/answers`: the person's own answer from the
/// device's approval sheet.
public struct RelayAnswer: Codable, Sendable, Equatable {
    public let questionId: String
    public let answer: RelayAnswerChoice

    public init(questionId: String, answer: RelayAnswerChoice) {
        self.questionId = questionId
        self.answer = answer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questionId = try container.decode(String.self, forKey: .questionId)
        answer = try container.decode(RelayAnswerChoice.self, forKey: .answer)
        guard Relay.isPlainID(questionId) else { throw refused("questionId isn't plain letters and digits", decoder) }
    }
}

// MARK: Keys and errors

/// `GET v1/keys`: the keys the relay signs receipts with. More than one
/// lets it change keys without a gap.
public struct RelayKeys: Codable, Sendable, Equatable {
    public let keys: [RelayKey]

    public init(keys: [RelayKey]) { self.keys = keys }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decode([RelayKey].self, forKey: .keys)
        guard (1...Relay.maxKeys).contains(keys.count) else { throw refused("keys must hold 1 to \(Relay.maxKeys)", decoder) }
    }
}

public struct RelayKey: Codable, Sendable, Equatable {
    public let id: String
    /// The 32 bytes of an Ed25519 public key, in base64.
    public let ed25519: String

    public init(id: String, publicKey: Curve25519.Signing.PublicKey) {
        self.id = id
        ed25519 = publicKey.rawRepresentation.base64EncodedString()
    }

    /// Nil when the bytes aren't a key CryptoKit takes.
    public var publicKey: Curve25519.Signing.PublicKey? {
        Data(base64Encoded: ed25519).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ed25519 = try container.decode(String.self, forKey: .ed25519)
        guard Relay.isPlainID(id) else { throw refused("key id isn't plain letters and digits", decoder) }
        guard Data(base64Encoded: ed25519)?.count == 32 else { throw refused("ed25519 isn't 32 bytes in base64", decoder) }
    }
}

/// Every code a relay may answer with. Anything else is refused.
public enum RelayErrorCode: String, Codable, Sendable, CaseIterable {
    /// The body isn't a message this version knows.
    case badRequest
    /// `version` is one the relay doesn't speak.
    case versionUnsupported
    /// No session, or one that has ended. Sign in again.
    case signInNeeded
    case runNotFound
    case questionNotFound
    /// The question's time ran out; the relay took it as no.
    case questionExpired
    /// The run is done, failed or stopped, so it can't take this.
    case runFinished
    /// A tool the relay doesn't offer.
    case toolNotOffered
    /// A limit past what the relay allows.
    case limitTooHigh
    case tooLarge
    /// Too many runs at once for this device.
    case tooManyRuns
    /// Too many calls; wait `retryAfterSeconds`.
    case slowDown
    /// The relay can't take work now; try later.
    case unavailable
}

/// The body of every answer that isn't a success.
public struct RelayError: Codable, Sendable, Equatable, Error {
    public let error: RelayErrorCode
    public let retryAfterSeconds: Int?

    public init(error: RelayErrorCode, retryAfterSeconds: Int? = nil) {
        self.error = error
        self.retryAfterSeconds = retryAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(RelayErrorCode.self, forKey: .error)
        retryAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        try checkRetry(retryAfterSeconds, decoder)
    }
}

// MARK: Receipts

/// What a receipt records. None of them carries any words.
public enum RelayReceiptKind: String, Codable, Sendable, CaseIterable {
    case runStarted = "run.started"
    case stepDone = "step.done"
    case toolUsed = "tool.used"
    case needsYouAsked = "needsYou.asked"
    case needsYouAnswered = "needsYou.answered"
    case runDone = "run.done"
    case runFailed = "run.failed"
    case runStopped = "run.stopped"

    /// The last receipt of a run, which carries the signature.
    public var isFinal: Bool { [.runDone, .runFailed, .runStopped].contains(self) }
}

/// One link of a run's receipt chain. Content free: a kind, a time, maybe
/// a tool's name and a hash, and the hashes that chain it.
public struct RelayReceipt: Codable, Sendable, Equatable {
    public let runId: String
    public let clientRunId: String
    /// 1 for the first receipt, then one more each time.
    public let seq: Int
    public let kind: RelayReceiptKind
    /// `YYYY-MM-DDTHH:MM:SSZ`.
    public let at: String
    /// On `tool.used` only, and always there.
    public let tool: String?
    /// The SHA-256 of what this link is about, such as a page the run read,
    /// so the relay can show later what it had without the device keeping it.
    public let contentSha256: String?
    public let prevHash: String
    public let hash: String
    /// On the final receipt only, and always there: base64 of the 64 byte
    /// Ed25519 signature over the 32 bytes of `hash`.
    public let signature: String?

    public init(runId: String, clientRunId: String, seq: Int, kind: RelayReceiptKind, at: String, tool: String? = nil, contentSha256: String? = nil,
                prevHash: String, hash: String, signature: String? = nil) {
        self.runId = runId
        self.clientRunId = clientRunId
        self.seq = seq
        self.kind = kind
        self.at = at
        self.tool = tool
        self.contentSha256 = contentSha256
        self.prevHash = prevHash
        self.hash = hash
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decode(String.self, forKey: .runId)
        clientRunId = try container.decode(String.self, forKey: .clientRunId)
        guard Relay.isPlainID(runId), Relay.isPlainID(clientRunId) else { throw refused("receipt run identity isn't plain letters and digits", decoder) }
        seq = try container.decode(Int.self, forKey: .seq)
        kind = try container.decode(RelayReceiptKind.self, forKey: .kind)
        at = try container.decode(String.self, forKey: .at)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        contentSha256 = try container.decodeIfPresent(String.self, forKey: .contentSha256)
        prevHash = try container.decode(String.self, forKey: .prevHash)
        hash = try container.decode(String.self, forKey: .hash)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        guard (1...Relay.maxReceipts).contains(seq) else { throw refused("seq is out of range", decoder) }
        guard Relay.date(at) != nil else { throw refused("at isn't a UTC time in whole seconds", decoder) }
        guard (kind == .toolUsed) == (tool != nil) else { throw refused("tool must come with tool.used, and only then", decoder) }
        if let tool, !Relay.isToolName(tool) { throw refused("tool isn't a tool's name", decoder) }
        if let contentSha256, !Relay.isHash(contentSha256) { throw refused("contentSha256 isn't 64 lowercase hex digits", decoder) }
        guard Relay.isHash(prevHash), Relay.isHash(hash) else { throw refused("a hash isn't 64 lowercase hex digits", decoder) }
        guard kind.isFinal == (signature != nil) else { throw refused("signature must come with the final receipt, and only then", decoder) }
        if let signature, Data(base64Encoded: signature)?.count != 64 {
            throw refused("signature isn't 64 bytes in base64", decoder)
        }
    }
}

/// Checks a run's receipt chain, as docs/RELAY.md defines it.
public enum RelayReceipts {
    /// The first receipt's `prevHash`.
    public static let firstPrevHash = String(repeating: "0", count: 64)

    public enum Problem: Error, Equatable {
        case empty
        /// The first receipt isn't `run.started`.
        case notStarted
        /// The receipt at this place in the list.
        case seq(index: Int)
        case kind(index: Int)
        case prevHash(index: Int)
        case hash(index: Int)
        case identity(index: Int)
        case terminalState
        case notFinished
        case signature
    }

    /// The bytes a receipt's hash is taken over: nine lines, each ending
    /// in a line feed, in UTF-8. An absent `tool` or `contentSha256` is
    /// written as nothing after its colon.
    public static func canonical(runId: String, clientRunId: String, seq: Int, kind: RelayReceiptKind, at: String, tool: String?,
                                 contentSha256: String?, prevHash: String) -> Data {
        let lines = [
            "relay-receipt/1",
            "runId:\(runId)",
            "clientRunId:\(clientRunId)",
            "seq:\(seq)",
            "kind:\(kind.rawValue)",
            "at:\(at)",
            "tool:\(tool ?? "")",
            "contentSha256:\(contentSha256 ?? "")",
            "prevHash:\(prevHash)",
        ]
        return Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    /// The lowercase hex SHA-256 of a receipt's canonical form.
    public static func hash(runId: String, clientRunId: String, seq: Int, kind: RelayReceiptKind, at: String, tool: String?,
                            contentSha256: String?, prevHash: String) -> String {
        let form = canonical(runId: runId, clientRunId: clientRunId, seq: seq, kind: kind, at: at, tool: tool, contentSha256: contentSha256, prevHash: prevHash)
        return Relay.hex(SHA256.hash(data: form))
    }

    /// The links of a chain, finished or not: it starts with `run.started`,
    /// `seq` counts up from 1, each `prevHash` is the hash before it, each
    /// `hash` is its own, and nothing comes after a final receipt.
    /// This does not authenticate a chain or detect truncation.
    public static func checkLinks(_ receipts: [RelayReceipt]) throws(Problem) {
        guard let first = receipts.first else { throw .empty }
        guard first.kind == .runStarted else { throw .notStarted }
        var prevHash = firstPrevHash
        for (index, receipt) in receipts.enumerated() {
            guard receipt.seq == index + 1 else { throw .seq(index: index) }
            if index > 0, receipt.kind == .runStarted { throw .kind(index: index) }
            if receipt.kind.isFinal, index != receipts.count - 1 { throw .kind(index: index) }
            guard receipt.prevHash == prevHash else { throw .prevHash(index: index) }
            let own = hash(runId: receipt.runId, clientRunId: receipt.clientRunId, seq: receipt.seq, kind: receipt.kind, at: receipt.at, tool: receipt.tool,
                           contentSha256: receipt.contentSha256, prevHash: receipt.prevHash)
            guard receipt.hash == own else { throw .hash(index: index) }
            prevHash = own
        }
    }

    /// Verify a finished run using its own identity and state. The client ID
    /// must come from the device's original request, not from the receipts.
    /// The caller must also match run.runId to the requested run when polling.
    public static func verify(_ run: RelayRun, clientRunId: String,
                              publicKey: Curve25519.Signing.PublicKey) throws(Problem) {
        try verify(run.receipts, runId: run.runId, clientRunId: clientRunId,
                   terminalState: run.state, publicKey: publicKey)
    }

    /// A finished chain: its links, a final receipt at the end, and that
    /// receipt's signature over its hash with `publicKey`.
    public static func verify(_ receipts: [RelayReceipt], runId: String, clientRunId: String, terminalState: RelayRunState,
                              publicKey: Curve25519.Signing.PublicKey) throws(Problem) {
        try checkLinks(receipts)
        guard let last = receipts.last, last.kind.isFinal else { throw .notFinished }
        for (index, receipt) in receipts.enumerated() {
            guard Relay.isPlainID(runId), Relay.isPlainID(clientRunId),
                  receipt.runId == runId, receipt.clientRunId == clientRunId else { throw .identity(index: index) }
        }
        let expectedKind: RelayReceiptKind
        switch terminalState {
        case .done: expectedKind = .runDone
        case .failed: expectedKind = .runFailed
        case .stopped: expectedKind = .runStopped
        default: throw .terminalState
        }
        guard last.kind == expectedKind else { throw .terminalState }
        guard let signature = last.signature.flatMap({ Data(base64Encoded: $0) }),
              let signed = Relay.bytes(hex: last.hash),
              publicKey.isValidSignature(signature, for: signed) else { throw .signature }
    }
}
