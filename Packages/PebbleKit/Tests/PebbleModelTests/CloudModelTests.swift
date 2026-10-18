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
        privateWords: [String] = [], isOn: @escaping @Sendable () throws -> Bool = { true }
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
        #expect(preview.request.method == "POST")
        #expect(preview.request.headers == CloudHeaders.fixed)
        #expect(preview.request.headers["User-Agent"] == "pebble")
        #expect(preview.request.headers["Accept-Language"] == "en")
    }

    @Test func theShownRequestHasTheMethodFullAddressEveryHeaderAndTheBody() throws {
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: ["X-Sample-Sign-In": "made-up"])
        let shown = preview.request.shownText
        #expect(shown.hasPrefix("""
        POST https://cloud.example.com/v1/reply
        Accept: application/json
        Accept-Encoding: identity
        Accept-Language: en
        Content-Type: application/json
        User-Agent: pebble
        X-Sample-Sign-In: made-up

        {
        """))
        #expect(shown.hasSuffix(preview.request.text))
    }

    /// The preview and the wire are the same: what the transport hands to
    /// URLSession is exactly the request the person read, headers included.
    @Test func theShownRequestIsTheURLRequestTheTransportReceives() async throws {
        let loader = RecordingLoader()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(
            endpoint: endpoint, transport: URLSessionCloudTransport(load: loader.load), reviewer: reviewer,
            auth: SampleAuth(headers: ["X-Sample-Sign-In": "made-up", "user-agent": "something else", "Host": "elsewhere"]),
            redactor: { Redactor(names: ["Sam"]) }
        )
        let next = try await cloudChat().sending("Call Sam", with: cloud)
        #expect(next.turns.last?.text == "Here's a short note you can send.")
        let preview = try #require(reviewer.seen.first)
        let wire = try #require(loader.requests.first)
        #expect(loader.requests.count == 1)
        #expect(wire.httpMethod == preview.request.method)
        #expect(wire.url == preview.request.url)
        #expect(wire.allHTTPHeaderFields == preview.request.headers)
        #expect(wire.httpBody == preview.request.body)
        #expect(wire.httpShouldHandleCookies == false)
        let fromWire = CloudRequest.shownText(method: try #require(wire.httpMethod), url: try #require(wire.url),
                                              headers: wire.allHTTPHeaderFields ?? [:], body: wire.httpBody ?? Data())
        #expect(fromWire == preview.request.shownText)
        // The sign-in header is shown and sent; it can't replace the fixed
        // User-Agent or set the host.
        #expect(wire.value(forHTTPHeaderField: "X-Sample-Sign-In") == "made-up")
        #expect(wire.value(forHTTPHeaderField: "User-Agent") == "pebble")
        #expect(wire.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(wire.value(forHTTPHeaderField: "Host") == nil)
    }

    // MARK: Redirects

    @Test func everyRedirectIsRefused() async throws {
        let session = URLSessionCloudTransport.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(session.delegate is RefusesRedirects)
        // Made but never started, so nothing touches the network.
        let task = session.dataTask(with: endpoint)
        let moved = try #require(HTTPURLResponse(url: endpoint, statusCode: 307, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Location": "http://elsewhere.example.org/"]))
        let elsewhere = URLRequest(url: try #require(URL(string: "http://elsewhere.example.org/")))
        let followed = await RefusesRedirects().urlSession(session, task: task, willPerformHTTPRedirection: moved,
                                                           newRequest: elsewhere)
        #expect(followed == nil)
    }

    @Test func aRefusedRedirectIsNotAReply() async {
        let loader = RecordingLoader(status: 308)
        let transport = URLSessionCloudTransport(load: loader.load)
        let request = CloudRequest(url: CloudModel.url(for: endpoint), headers: CloudHeaders.fixed, body: Data("{}".utf8))
        await #expect(throws: URLError.self) { try await transport.send(request) }
        #expect(loader.requests.count == 1)
    }

    /// The transport never lets the system fill in a User-Agent or
    /// Accept-Language the person didn't see.
    @Test(arguments: [
        [:],
        ["Content-Type": "application/json"],
        CloudHeaders.fixed.filter { $0.key != "User-Agent" },
        CloudHeaders.fixed.filter { $0.key != "Accept-Language" },
        CloudHeaders.fixed.merging(["Host": "elsewhere.example.org"]) { $1 },
    ])
    func aRequestWithoutTheFixedHeadersIsRefused(headers: [String: String]) async {
        let loader = RecordingLoader()
        let transport = URLSessionCloudTransport(load: loader.load)
        let request = CloudRequest(url: CloudModel.url(for: endpoint), headers: headers, body: Data("{}".utf8))
        await #expect(throws: CloudTransportError.headersNotShown) { try await transport.send(request) }
        #expect(loader.requests.isEmpty)
    }

    @Test func theSessionKeepsNothingAndAddsNothing() {
        let session = URLSessionCloudTransport.makeSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    // MARK: Sign-in

    @Test func signInHeadersAreShownAndNothingByDefault() throws {
        #expect(NoCloudAuth().headers(for: endpoint).isEmpty)
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: SampleAuth(headers: ["X-Sample-Sign-In": "made-up"]).headers(for: endpoint))
        #expect(preview.request.shownText.contains("X-Sample-Sign-In: made-up"))
    }

    // MARK: Notes that can't be read

    @Test func unreadableNotesSendNothingAndShowNothing() async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               redactor: { throw MemoryStore.Unavailable() })
        await #expect(throws: CloudModelError.notesUnreadable) {
            try await cloudChat().sending("Write to Sam", with: cloud)
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    // MARK: A chat never gets less private

    /// After Forget everything, or a private word taken off the list, the
    /// next request in the same chat still hides what earlier ones hid.
    @Test func whatOneRequestHidThePrivacyActionsAfterItNeverUnhide() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let forgotten = Flag(false)
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, redactor: {
            forgotten.value ? Redactor() : Redactor(names: ["Sam"], privateWords: ["lemon cake"])
        })
        let first = try await cloudChat().sending("Ask Sam to bring the lemon cake.", with: cloud)
        forgotten.value = true
        _ = try await first.sending("And remind Sam again tomorrow.", with: cloud)
        #expect(transport.sent.count == 2)
        for sent in transport.sent {
            #expect(!sent.text.contains("Sam"), "a name came back")
            #expect(!sent.text.contains("lemon cake"), "a private word came back")
        }
        #expect(transport.sent[1].text.contains("Ask [name] to bring the [private]."))
        #expect(transport.sent[1].text.contains("And remind [name] again tomorrow."))
        // A new chat starts from the list as it is now.
        let fresh = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, redactor: { Redactor() })
        _ = try await cloudChat().sending("Sam", with: fresh)
        #expect(transport.sent.last?.text.contains("\"Sam\"") == true)
    }

    @Test func aRedactorUnionHidesEverythingEitherHides() {
        let both = Redactor(names: ["Sam"], privateWords: ["lemon cake"])
            .union(Redactor(names: ["Priya", "sam"], privateWords: ["Riverside Clinic"]))
        #expect(both.names == ["Sam", "Priya"])
        #expect(both.privateWords == ["lemon cake", "Riverside Clinic"])
    }

    @Test func aTurnCanBeTakenBack() throws {
        let id = UUID()
        let chat = try cloudChat().appendingPerson("Don't send this", id: id)
        #expect(chat.removingTurn(id) == cloudChat())
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

    /// A setting that can't be read is not the same as off: nothing is
    /// shown or sent, and the chat says it couldn't read them.
    @Test func anUnreadableSettingIsNotReadAsOff() async {
        struct Locked: Error {}
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        await #expect(throws: CloudModelError.notesUnreadable) {
            try await cloudChat().sending("Plan my week", with: model(
                transport: transport, reviewer: reviewer, isOn: { throw Locked() }))
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

    /// The onboarding hello asks this on every redraw, so it must agree
    /// with the model a chat would get without making one.
    @Test(arguments: [false, true], [false, true])
    func knowingWhetherANewChatRunsOnDeviceMakesNoModel(isOn: Bool, hasAddress: Bool) {
        let settings = CloudHelpSettings(isOn: isOn)
        let address = hasAddress ? endpoint : nil
        let made = Flag(false)
        let runsHere = ModelChoice.runsOnDevice(settings: settings, endpoint: address, local: LocalStubModel())
        #expect(!made.value)
        let model = ModelChoice.model(settings: settings, endpoint: address, local: LocalStubModel()) { url in
            made.value = true
            return CloudModel(endpoint: url, transport: RecordingTransport(), reviewer: RecordingReviewer(answer: .cancel))
        }
        #expect(runsHere == model.runsOnDevice)
        #expect(ModelChoice.usesCloud(settings: settings, endpoint: address) == (isOn && hasAddress))
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

/// Stands in for URLSession: records each URLRequest and answers with a
/// fixed status. Never touches the network.
final class RecordingLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let status: Int

    init(status: Int = 200) { self.status = status }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    @Sendable func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requests.append(request) }
        let headers = (300..<400).contains(status) ? ["Location": "http://elsewhere.example.org/"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (try JSONEncoder().encode(["reply": "Here's a short note you can send."]), response)
    }
}

/// Sign-in that hands back made-up headers and counts sign-ins.
final class SampleAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private let fixed: [String: String]
    private var _signIns = 0

    init(headers: [String: String] = [:]) { fixed = headers }

    var signIns: Int {
        lock.lock(); defer { lock.unlock() }
        return _signIns
    }

    func headers(for url: URL) -> [String: String] { fixed }

    func signIn() async {
        lock.withLock { _signIns += 1 }
    }
}
