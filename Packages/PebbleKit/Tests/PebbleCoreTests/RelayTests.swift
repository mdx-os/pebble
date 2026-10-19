import CryptoKit
import Foundation
import PebbleCore
import SourceScan
import Testing

/// The relay protocol's messages read and write as docs/RELAY.md says, and
/// refuse what it refuses. The files in Fixtures/relay are the conformance
/// vectors a relay can be checked against.
struct RelayFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/relay")

    /// Every fixture's name without `.json`, such as `run.valid.done`.
    static let all: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.hasSuffix(".json") }
        .map { String($0.dropLast(5)) }
        .sorted()
    static let valid = all.filter { $0.contains(".valid.") }
    static let invalid = all.filter { $0.contains(".invalid.") }
    static let messages = ["run-request", "run", "answer", "keys", "error", "receipts"]

    /// Why each broken chain fails, at the first link that breaks.
    static let brokenChains: [String: RelayReceipts.Problem] = [
        "receipts.invalid.changed-field": .hash(index: 2),
        "receipts.invalid.dropped": .seq(index: 2),
        "receipts.invalid.reordered": .seq(index: 1),
        "receipts.invalid.prev-hash": .prevHash(index: 1),
        "receipts.invalid.not-started": .notStarted,
    ]

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent(name + ".json"))
    }

    static func message(_ name: String) -> String { String(name.prefix { $0 != "." }) }

    /// Reads a fixture as its message, writes it back, and reads that again.
    /// The same value both times, and what it wrote.
    static func roundTrip(_ name: String) throws -> Data {
        let data = try data(name)
        switch message(name) {
        case "run-request": return try roundTrip(RelayRunRequest.self, data)
        case "run": return try roundTrip(RelayRun.self, data)
        case "answer": return try roundTrip(RelayAnswer.self, data)
        case "keys": return try roundTrip(RelayKeys.self, data)
        case "error": return try roundTrip(RelayError.self, data)
        case "receipts": return try roundTrip([RelayReceipt].self, data)
        default: throw CocoaError(.fileReadUnknown)
        }
    }

    static func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ data: Data) throws -> Data {
        let value = try Relay.decode(T.self, from: data)
        let written = try Relay.encode(value)
        #expect(try Relay.decode(T.self, from: written) == value)
        return written
    }

    static func object(_ data: Data) throws -> NSObject {
        try #require(JSONSerialization.jsonObject(with: data) as? NSObject)
    }

    @Test func thereAreFixturesForEveryMessage() {
        for message in Self.messages {
            #expect(Self.valid.contains { Self.message($0) == message }, "no valid fixture for \(message)")
            #expect(Self.invalid.contains { Self.message($0) == message }, "no invalid fixture for \(message)")
        }
        #expect(Set(Self.all.map(Self.message)).isSubset(of: Self.messages))
        #expect(Self.all.count == Self.valid.count + Self.invalid.count)
    }

    /// Valid fixtures read, and write back to the same JSON. Keys this
    /// version doesn't know are dropped, and the rest is the same.
    @Test(arguments: valid)
    func aValidFixtureReadsAndWritesBack(name: String) throws {
        let written = try Self.roundTrip(name)
        guard !name.hasSuffix(".extra-keys") else { return }
        #expect(try Self.object(written) == Self.object(Self.data(name)))
    }

    @Test func unknownKeysAreIgnored() throws {
        let plain = try Relay.decode(RelayRun.self, from: Self.data("run.valid.done"))
        let extra = try Relay.decode(RelayRun.self, from: Self.data("run.valid.extra-keys"))
        #expect(plain == extra)
    }

    @Test(arguments: invalid)
    func anInvalidFixtureIsRefused(name: String) throws {
        if let problem = Self.brokenChains[name] {
            // A broken chain reads as receipts, and fails when it's checked.
            let receipts = try Relay.decode([RelayReceipt].self, from: Self.data(name))
            #expect(throws: problem) { try RelayReceipts.checkLinks(receipts) }
        } else {
            #expect(throws: DecodingError.self) { try Self.roundTrip(name) }
        }
    }

    @Test func everyBrokenChainHasItsReason() {
        #expect(Set(Self.brokenChains.keys) == Set(Self.invalid.filter { Self.message($0) == "receipts" }))
    }

    /// The valid chain's hashes are the ones the canonical form gives, so a
    /// relay can check its hashing against them.
    @Test func theFixtureChainsLink() throws {
        try RelayReceipts.checkLinks(Relay.decode([RelayReceipt].self, from: Self.data("receipts.valid.done")))
        for name in Self.valid where Self.message(name) == "run" {
            let run = try Relay.decode(RelayRun.self, from: Self.data(name))
            if !run.receipts.isEmpty { try RelayReceipts.checkLinks(run.receipts) }
        }
    }

    /// docs/RELAY.md lists every fixture, and none that isn't there.
    @Test func theProtocolListsEveryFixture() throws {
        let doc = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("docs/RELAY.md"), encoding: .utf8)
        let listed = Set(doc.split(separator: "`").map(String.init).filter { $0.hasSuffix(".json") && !$0.contains("/") && !$0.contains("<") })
        #expect(listed == Set(Self.all.map { $0 + ".json" }))
    }

    /// A good answer made too big with spaces: only its size is wrong.
    @Test func aBodyPastTheLimitIsRefusedUnread() throws {
        let answer = try RelayFixtureTests.data("answer.valid.yes")
        let padded = answer + Data(repeating: 32, count: Relay.maxBodyBytes + 1 - answer.count)
        _ = try Relay.decode(RelayAnswer.self, from: padded.dropLast())
        #expect(throws: DecodingError.self) { try Relay.decode(RelayAnswer.self, from: padded) }
    }
}

struct RelayMessageTests {
    @Test(arguments: [
        ("a", true), ("Run42", true), (String(repeating: "z", count: 64), true),
        ("", false), (String(repeating: "z", count: 65), false), ("run-42", false), ("run_42", false),
        ("run 42", false), ("r\u{00E9}", false), ("\u{0661}", false), ("run/42", false),
    ])
    func idsArePlainLettersAndDigits(id: String, plain: Bool) {
        #expect(Relay.isPlainID(id) == plain)
    }

    @Test(arguments: [
        ("2026-10-18T09:00:00Z", true), ("2026-02-30T09:00:00Z", false), ("2026-10-18T09:00:00.5Z", false),
        ("2026-10-18T09:00:00+00:00", false), ("2026-10-18 09:00:00Z", false), ("2026-10-18T24:00:00Z", false),
    ])
    func timesAreUTCInWholeSeconds(text: String, valid: Bool) {
        #expect((Relay.date(text) != nil) == valid)
    }

    /// One line means one line: no breaks, no control characters, nothing
    /// that turns the text around, and no space at either end.
    @Test(arguments: ["Reading\nthe sources", "Reading\u{2028}the sources", "Reading \u{202E}secruos",
                      "Reading\u{0007}", " Reading", "Reading ", ""])
    func oneLineFieldsRefuseWhatIsNotOneLine(words: String) throws {
        let good = try Relay.encode(RelayStep(words: "Reading the sources", state: .working))
        _ = try Relay.decode(RelayStep.self, from: good)
        let bad = try Relay.encode(RelayStep(words: words, state: .working))
        #expect(throws: DecodingError.self) { try Relay.decode(RelayStep.self, from: bad) }
    }

    @Test func aTargetIsAskedAboutAsTheRecipientItNames() throws {
        let run = try Relay.decode(RelayRun.self, from: RelayFixtureTests.data("run.valid.needs-you"))
        let question = try #require(run.needsYou)
        #expect(question.action == .send)
        #expect(question.target.recipient == Recipient(id: "contact1", displayName: "Sam", handle: question.target.handle))
        #expect(question.target.recipient.handle == question.target.handle)
    }

    @Test func anArtifactCarriesItsBytesAndTheirHash() throws {
        let bytes = Data("made on the relay\n".utf8)
        let artifact = RelayArtifact(name: "notes.txt", kind: .text, bytes: bytes)
        let read = try Relay.decode(RelayArtifact.self, from: Relay.encode(artifact))
        #expect(read == artifact)
        #expect(read.bytes == bytes)
    }

    @Test func aRequestIsWrittenAtThisVersion() throws {
        let request = RelayRunRequest(clientRunId: "c1", kind: .steps, brief: "Plan my week", tools: ["calendar.read"],
                                      limits: RelayLimits(maxMinutes: 10, maxSteps: 10))
        #expect(request.version == Relay.version)
        #expect(try Relay.decode(RelayRunRequest.self, from: Relay.encode(request)) == request)
    }
}

/// `RelayReceipts.verify` takes a whole, signed chain and nothing less. The
/// keys are made here, for each test, and never written down.
struct RelayReceiptTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func time(_ offset: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: start.addingTimeInterval(TimeInterval(offset * 10)))
    }

    static func receipt(_ seq: Int, _ kind: RelayReceiptKind, at: String, tool: String?, content: String?,
                        prevHash: String, signature: String? = nil) -> RelayReceipt {
        let hash = RelayReceipts.hash(seq: seq, kind: kind, at: at, tool: tool, contentSha256: content, prevHash: prevHash)
        return RelayReceipt(seq: seq, kind: kind, at: at, tool: tool, contentSha256: content,
                            prevHash: prevHash, hash: hash, signature: signature)
    }

    /// A run that read a page, asked the person, heard back and finished,
    /// signed with `key`.
    static func chain(_ key: Curve25519.Signing.PrivateKey,
                      kinds: [RelayReceiptKind] = [.runStarted, .toolUsed, .stepDone, .needsYouAsked, .needsYouAnswered, .runDone])
    throws -> [RelayReceipt] {
        var receipts: [RelayReceipt] = []
        var prevHash = RelayReceipts.firstPrevHash
        for (index, kind) in kinds.enumerated() {
            let tool = kind == .toolUsed ? "web.read" : nil
            let content = kind == .toolUsed
                ? SHA256.hash(data: Data("page \(index)".utf8)).map { String(format: "%02x", $0) }.joined() : nil
            var next = receipt(index + 1, kind, at: time(index), tool: tool, content: content, prevHash: prevHash)
            if kind.isFinal {
                let signed = try key.signature(for: hexBytes(next.hash)).base64EncodedString()
                next = receipt(index + 1, kind, at: next.at, tool: tool, content: content, prevHash: prevHash, signature: signed)
            }
            receipts.append(next)
            prevHash = next.hash
        }
        return receipts
    }

    static func hexBytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The same receipt with a different time and its old hash.
    static func changedTime(_ receipt: RelayReceipt) -> RelayReceipt {
        RelayReceipt(seq: receipt.seq, kind: receipt.kind, at: time(99), tool: receipt.tool,
                     contentSha256: receipt.contentSha256, prevHash: receipt.prevHash, hash: receipt.hash,
                     signature: receipt.signature)
    }

    @Test func aWholeSignedChainVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let receipts = try Self.chain(key)
        try RelayReceipts.verify(receipts, publicKey: key.publicKey)
        // And reads back the same through the wire.
        let read = try Relay.decode([RelayReceipt].self, from: Relay.encode(receipts))
        try RelayReceipts.verify(read, publicKey: key.publicKey)
    }

    @Test func aChangedFieldFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        var receipts = try Self.chain(key)
        receipts[2] = Self.changedTime(receipts[2])
        #expect(throws: RelayReceipts.Problem.hash(index: 2)) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
    }

    /// Every hash made again after the change still fails: only the relay's
    /// key could sign the new last hash.
    @Test func aChangedFieldWithEveryHashRemadeFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = try Self.chain(key)
        var remade: [RelayReceipt] = []
        var prevHash = RelayReceipts.firstPrevHash
        for (index, old) in original.enumerated() {
            let at = index == 2 ? Self.time(99) : old.at
            let next = Self.receipt(old.seq, old.kind, at: at, tool: old.tool, content: old.contentSha256,
                                    prevHash: prevHash, signature: old.signature)
            remade.append(next)
            prevHash = next.hash
        }
        try RelayReceipts.checkLinks(remade)
        #expect(throws: RelayReceipts.Problem.signature) { try RelayReceipts.verify(remade, publicKey: key.publicKey) }
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func aDroppedReceiptFails(index: Int) throws {
        let key = Curve25519.Signing.PrivateKey()
        var receipts = try Self.chain(key)
        receipts.remove(at: index)
        #expect(throws: RelayReceipts.Problem.self) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func aReorderedPairFails(index: Int) throws {
        let key = Curve25519.Signing.PrivateKey()
        var receipts = try Self.chain(key)
        receipts.swapAt(index, index + 1)
        #expect(throws: RelayReceipts.Problem.self) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
    }

    /// A reordered pair with its seq numbers put back in order still fails
    /// on the links.
    @Test func aReorderedPairWithSeqRenumberedFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        var receipts = try Self.chain(key)
        receipts.swapAt(1, 2)
        receipts = receipts.enumerated().map { index, old in
            RelayReceipt(seq: index + 1, kind: old.kind, at: old.at, tool: old.tool, contentSha256: old.contentSha256,
                         prevHash: old.prevHash, hash: old.hash, signature: old.signature)
        }
        #expect(throws: RelayReceipts.Problem.prevHash(index: 1)) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
    }

    @Test func aWrongKeyFails() throws {
        let receipts = try Self.chain(Curve25519.Signing.PrivateKey())
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: RelayReceipts.Problem.signature) { try RelayReceipts.verify(receipts, publicKey: other.publicKey) }
    }

    @Test func anUnfinishedChainFailsButItsLinksHold() throws {
        let key = Curve25519.Signing.PrivateKey()
        let receipts = try Self.chain(key, kinds: [.runStarted, .toolUsed, .stepDone])
        try RelayReceipts.checkLinks(receipts)
        #expect(throws: RelayReceipts.Problem.notFinished) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
    }

    @Test func nothingComesAfterTheEnd() throws {
        let key = Curve25519.Signing.PrivateKey()
        let receipts = try Self.chain(key, kinds: [.runStarted, .runStopped, .stepDone])
        #expect(throws: RelayReceipts.Problem.kind(index: 1)) { try RelayReceipts.verify(receipts, publicKey: key.publicKey) }
        let twice = try Self.chain(key, kinds: [.runStarted, .stepDone, .runStarted, .runDone])
        #expect(throws: RelayReceipts.Problem.kind(index: 2)) { try RelayReceipts.verify(twice, publicKey: key.publicKey) }
    }

    @Test func anEmptyChainFails() {
        #expect(throws: RelayReceipts.Problem.empty) {
            try RelayReceipts.verify([], publicKey: Curve25519.Signing.PrivateKey().publicKey)
        }
    }

    /// The canonical form, byte for byte, as docs/RELAY.md writes it.
    @Test func theCanonicalFormIsSevenLines() {
        let form = RelayReceipts.canonical(seq: 2, kind: .toolUsed, at: "2026-10-18T09:00:05Z", tool: "web.search",
                                           contentSha256: nil, prevHash: RelayReceipts.firstPrevHash)
        let expected = "relay-receipt/1\nseq:2\nkind:tool.used\nat:2026-10-18T09:00:05Z\ntool:web.search\n"
            + "contentSha256:\nprevHash:" + RelayReceipts.firstPrevHash + "\n"
        #expect(String(decoding: form, as: UTF8.self) == expected)
    }

    /// The fixture keys file reads, and a key made here goes through it.
    @Test func keysReadBackAsKeys() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = RelayKeys(keys: [RelayKey(id: "k1", publicKey: key.publicKey)])
        let read = try Relay.decode(RelayKeys.self, from: Relay.encode(keys))
        let publicKey = try #require(read.keys.first?.publicKey)
        try RelayReceipts.verify(Self.chain(key), publicKey: publicKey)
    }
}
