import Foundation
import PebbleCore
import PebbleModel
import Testing

/// Records every request and answers with a fixed reply. Never touches the network.
final class RecordingTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [CloudRequest] = []
    let reply: Data

    init(reply: String = "Here's a short note you can send.") {
        self.reply = try! JSONEncoder().encode(["reply": reply])
    }

    var sent: [CloudRequest] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    func send(_ request: CloudRequest) async throws -> Data {
        lock.withLock { _sent.append(request) }
        return reply
    }
}

/// Records every preview and gives a fixed answer.
final class RecordingReviewer: CloudReviewing, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [CloudPreview] = []
    let answer: CloudConsent

    init(answer: CloudConsent) { self.answer = answer }

    var seen: [CloudPreview] {
        lock.lock(); defer { lock.unlock() }
        return _seen
    }

    func review(_ preview: CloudPreview) async -> CloudConsent {
        lock.withLock { _seen.append(preview) }
        return answer
    }
}

struct CloudModelTests {
    let endpoint = URL(string: "https://cloud.example.com")!
    let notes = [MemoryNote(text: "Sam's birthday is May 14.", source: .toldMe)]

    func model(
        transport: RecordingTransport, reviewer: RecordingReviewer,
        privateWords: [String] = [], isOn: @escaping @Sendable () -> Bool = { true }
    ) -> CloudModel {
        let notes = notes
        return CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                          redactor: { Redactor(memory: notes, privateWords: privateWords) }, isOn: isOn)
    }

    func cloudChat() -> Conversation {
        Conversation.firstRun(named: "Pip", onDevice: false)
    }

    @Test func neverClaimsToRunOnDevice() {
        let cloud = model(transport: RecordingTransport(), reviewer: RecordingReviewer(answer: .send))
        #expect(cloud.runsOnDevice == false)
    }

    // MARK: Preview equals sent bytes

    @Test func sendsExactlyThePreviewedBytes() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let next = try await cloudChat().sending(
            "Write to Sam at sam.lee@example.com and call 416-555-0199. Skip the lemon cake.",
            with: model(transport: transport, reviewer: reviewer, privateWords: ["lemon cake"])
        )
        #expect(next.turns.last?.text == "Here's a short note you can send.")
        let preview = try #require(reviewer.seen.first)
        #expect(reviewer.seen.count == 1)
        #expect(transport.sent.count == 1)
        let sent = try #require(transport.sent.first)
        // Byte for byte, and the text the person read is those bytes.
        #expect(sent.body == preview.request.body)
        #expect(sent == preview.request)
        #expect(Data(preview.request.text.utf8) == sent.body)
        #expect(sent.url.absoluteString == "https://cloud.example.com/v1/reply")
        // Nothing personal is in what left.
        for secret in ["Sam", "sam.lee@example.com", "416-555-0199", "lemon cake"] {
            #expect(!sent.text.contains(secret), "\(secret) left the device")
        }
        #expect(preview.hidden == [.name: 1, .email: 1, .phone: 1, .privateWord: 1])
    }

    @Test func thePayloadHasAFixedShape() throws {
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Text Sam at 416-555-0199."))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(memory: notes))
        let opening = FirstConversation.opening(named: "Pip")
        #expect(preview.request.text == """
        {
          "messages" : [
            {
              "role" : "agent",
              "text" : "\(opening)"
            },
            {
              "role" : "person",
              "text" : "Text [name] at [phone number]."
            }
          ],
          "version" : 1
        }
        """)
        #expect(preview.request.headers == ["Content-Type": "application/json"])
    }

    @Test func authHeadersAreAddedAndNothingByDefault() async {
        #expect(await NoCloudAuth().headers(for: endpoint).isEmpty)
    }

    // MARK: Cancel sends nothing

    @Test func cancelSendsNothing() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .cancel)
        await #expect(throws: CloudModelError.notSent) {
            try await cloudChat().sending("Plan my week", with: model(transport: transport, reviewer: reviewer))
        }
        #expect(reviewer.seen.count == 1)
        #expect(transport.sent.isEmpty)
    }

    // MARK: Off sends nothing

    @Test func offSendsNothingAndShowsNothing() async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        await #expect(throws: CloudModelError.off) {
            try await cloudChat().sending("Plan my week", with: model(transport: transport, reviewer: reviewer, isOn: { false }))
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    @Test func turnedOffWhileThePreviewShowsSendsNothing() async {
        let transport = RecordingTransport()
        let flag = Flag(true)
        let reviewer = TurningOffReviewer(flag: flag)
        await #expect(throws: CloudModelError.off) {
            try await cloudChat().sending("Plan my week", with: CloudModel(
                endpoint: endpoint, transport: transport, reviewer: reviewer, isOn: { flag.value }))
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func offOrNoAddressPicksTheOnDeviceModelAndMakesNoCloud() {
        let made = Flag(false)
        let cloud: (URL) -> any ModelClient = { _ in
            made.value = true
            return LocalStubModel()
        }
        let offWithAddress = ModelChoice.model(settings: .off, endpoint: endpoint, local: LocalStubModel(), cloud: cloud)
        let onWithoutAddress = ModelChoice.model(settings: CloudHelpSettings(isOn: true), endpoint: CloudEndpoint.url(from: ""),
                                                 local: LocalStubModel(), cloud: cloud)
        #expect(offWithAddress.runsOnDevice)
        #expect(onWithoutAddress.runsOnDevice)
        #expect(!made.value)
        let on = ModelChoice.model(settings: CloudHelpSettings(isOn: true), endpoint: endpoint, local: LocalStubModel()) { url in
            CloudModel(endpoint: url, transport: RecordingTransport(), reviewer: RecordingReviewer(answer: .cancel))
        }
        #expect(!on.runsOnDevice)
    }

    // MARK: The on-device promise

    @Test func aConversationThatPromisedOnDeviceIsNeverSent() async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let promised = Conversation.firstRun(named: "Pip", onDevice: true)
        #expect(promised.turns.first?.text.contains("stays here") == true)
        await #expect(throws: ConversationError.leavesDevice) {
            try await promised.sending("Write to Sam", with: model(transport: transport, reviewer: reviewer))
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    @Test func aCloudChatNeverPromisesOnDevice() {
        let opening = Conversation.firstRun(named: "Pip", onDevice: false).turns.first?.text ?? ""
        #expect(!opening.contains("stays"))
    }

    // MARK: Care

    @Test(arguments: ["I want to kill myself", "I don't want to be here anymore", "thinking about suicide"])
    func wordsOfCrisisGetTheCareReplyAndAreNeverSent(line: String) async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = model(transport: transport, reviewer: reviewer)
        let cared = try await cloudChat().sending(line, with: cloud)
        #expect(cared.turns.last?.text == CareCheck.reply)
        // The next line stays with care too, and is not sent either.
        let followed = try await cared.sending("yes", with: cloud)
        #expect(followed.turns.last?.text == CareCheck.followUp)
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    @Test func careStaysOutOfLaterRequests() async throws {
        let transport = RecordingTransport()
        let cloud = model(transport: transport, reviewer: RecordingReviewer(answer: .send))
        var chat = try await cloudChat().sending("I want to end my life", with: cloud)
        chat = try await chat.sending("plan my morning", with: cloud)
        let sent = try #require(transport.sent.first)
        #expect(!sent.text.contains("end my life"))
        #expect(!sent.text.contains("988"))
    }

    @Test func careIsCheckedBeforeRedaction() {
        // Called directly, without Conversation, it still refuses.
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Sam, I want to die"))
        #expect(throws: CloudModelError.staysHere) {
            try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(memory: notes))
        }
    }

    @Test func aPrivateWordNeverHidesWordsOfCrisis() {
        // Hiding words still sends; hiding words of crisis never does.
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "I keep thinking about the bridge"))
        let redactor = Redactor(names: [], privateWords: ["the bridge"])
        #expect((try? CloudModel.preview(for: turns, endpoint: endpoint, redactor: redactor)) != nil)
        var crisis = cloudChat().turns
        crisis.append(ChatTurn(id: UUID(), speaker: .person, text: "I might overdose tonight"))
        #expect(throws: CloudModelError.staysHere) {
            try CloudModel.preview(for: crisis, endpoint: endpoint, redactor: Redactor(privateWords: ["overdose"]))
        }
    }

    @Test func anUnreadableAnswerIsNotShownAsAReply() async {
        let transport = BrokenTransport()
        await #expect(throws: CloudModelError.unreadableReply) {
            try await cloudChat().sending("Plan my week", with: CloudModel(
                endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send)))
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Says send, but turns the setting off first, as if the person switched
/// it off while the preview was showing.
struct TurningOffReviewer: CloudReviewing {
    let flag: Flag
    func review(_ preview: CloudPreview) async -> CloudConsent {
        flag.value = false
        return .send
    }
}

struct BrokenTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data { Data("not json".utf8) }
}
