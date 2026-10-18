import Foundation
#if canImport(Network)
import Network
#endif
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
        // A plain word, not the product's name or its codename.
        #expect(preview.request.headers["User-Agent"] == "agent")
        #expect(preview.request.headers["Accept-Language"] == "en")
    }

    /// The preview is the whole request: the Host and Content-Length the
    /// system adds are shown too, worked out from the address and the body.
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
        Content-Length: \(preview.request.body.count)
        Content-Type: application/json
        Host: cloud.example.com
        User-Agent: agent
        X-Sample-Sign-In: made-up

        {
        """))
        #expect(shown.hasSuffix(preview.request.text))
        // A port in the address is part of the host line, as it is on the wire.
        let ported = try CloudModel.preview(for: turns, endpoint: try #require(URL(string: "https://cloud.example.com:8443")),
                                            redactor: Redactor())
        #expect(ported.request.shownText.contains("\nHost: cloud.example.com:8443\n"))
    }

    /// The preview and the wire are the same: what the transport hands to
    /// URLSession is exactly the request the person read, headers included.
    @Test func theShownRequestIsTheURLRequestTheTransportReceives() async throws {
        let loader = RecordingLoader()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(
            endpoint: endpoint, transport: URLSessionCloudTransport(load: loader.load), reviewer: reviewer,
            auth: SampleAuth(headers: ["X-Sample-Sign-In": "made-up", "user-agent": "something else"]),
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
        // User-Agent. The host is the system's, from the address shown.
        #expect(wire.value(forHTTPHeaderField: "X-Sample-Sign-In") == "made-up")
        #expect(wire.value(forHTTPHeaderField: "User-Agent") == "agent")
        #expect(wire.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(wire.value(forHTTPHeaderField: "Host") == nil)
        #expect(preview.request.shownText.contains("\nHost: \(try #require(wire.url?.host))\n"))
        #expect(preview.request.shownText.contains("\nContent-Length: \(try #require(wire.httpBody).count)\n"))
    }

    // MARK: Names URLSession reserves

    static let reservedNames = ["Authorization", "Proxy-Authorization", "Host", "Content-Length", "Connection",
                                "Transfer-Encoding", "proxy-authenticate", "WWW-Authenticate", "AUTHORIZATION",
                                "Cookie", "cookie"]

    /// Sign-in can't use a name URLSession may set, drop or overwrite, so
    /// what goes always matches what was shown. Refused, not dropped.
    @Test(arguments: CloudModelTests.reservedNames)
    func theHeaderBuilderRefusesAReservedName(name: String) {
        #expect(throws: CloudTransportError.reservedHeader(name)) {
            try CloudHeaders.merged(with: [name: "made-up", "X-Sample-Sign-In": "made-up"])
        }
        #expect((try? CloudHeaders.merged(with: ["X-Sample-Sign-In": "made-up"])) != nil)
    }

    /// The transport refuses a request carrying one, before anything goes.
    @Test(arguments: CloudModelTests.reservedNames)
    func theTransportRefusesARequestWithAReservedName(name: String) async {
        let loader = RecordingLoader()
        let transport = URLSessionCloudTransport(load: loader.load)
        let request = CloudRequest(url: CloudModel.url(for: endpoint),
                                   headers: CloudHeaders.fixed.merging([name: "made-up"]) { $1 }, body: Data("{}".utf8))
        await #expect(throws: CloudTransportError.reservedHeader(name)) { try await transport.send(request) }
        #expect(loader.requests.isEmpty)
    }

    /// A sign-in that asks for one never gets as far as a preview.
    @Test func aReplyWithAReservedSignInHeaderShowsAndSendsNothing() async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               auth: SampleAuth(headers: ["Authorization": "Bearer made-up"]))
        await #expect(throws: CloudTransportError.reservedHeader("Authorization")) {
            try await cloudChat().sending("Plan my week", with: cloud)
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
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
        CloudHeaders.fixed.merging(["User-Agent": "something else"]) { $1 },
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
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    #if canImport(Network)
    /// A cookie the sign-in answer sets never rides on the message. The
    /// real session, one for both hops, talks to a listener on this Mac's
    /// loopback address only, which sets a cookie on the sign-in answer;
    /// the message reaches it with no Cookie header.
    @Test func aCookieFromTheSignInAnswerNeverRidesOnTheMessage() async throws {
        let server = try LoopbackServer()
        let port = await server.start()
        defer { server.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(
            endpoint: endpoint, transport: URLSessionCloudTransport(answeringWith: []), reviewer: reviewer,
            auth: SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)))
        )
        _ = try await cloudChat().sending("Plan my week", with: cloud)
        let seen = server.requests
        #expect(seen.map(\.path) == ["/v1/sign-in", "/v1/reply"])
        for request in seen {
            #expect(request.headers["cookie"] == nil, "\(request.path)")
        }
        // The Host line the preview shows is the one the wire carried.
        let message = try #require(reviewer.seen.first?.request)
        #expect(seen.last?.headers["host"] == CloudRequest.hostLine(for: message.url))
        #expect(seen.last?.headers["content-length"] == String(message.body.count))
    }
    #endif

    // MARK: Sign-in

    @Test func signInHeadersAreShownAndNothingByDefault() throws {
        #expect(NoCloudAuth().headers(for: endpoint).isEmpty)
        #expect(NoCloudAuth().signIn(for: endpoint) == nil)
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: SampleAuth(headers: ["X-Sample-Sign-In": "made-up"]).headers(for: endpoint))
        #expect(preview.request.shownText.contains("X-Sample-Sign-In: made-up"))
        #expect(preview.signIn == nil)
    }

    /// A sign-in the cloud needs is a hop in the same preview, above the
    /// message: where it goes, every header and its body.
    @Test func aSignInIsShownAsAHopInTheSamePreview() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .cancel)
        let auth = SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8)))
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth)
        _ = try? await cloudChat().sending("Plan my week", with: cloud)
        let preview = try #require(reviewer.seen.first)
        let signIn = try #require(preview.signIn)
        #expect(signIn.url.absoluteString == "https://cloud.example.com/v1/sign-in")
        #expect(signIn.headers == CloudHeaders.fixed)
        #expect(preview.hops == [signIn, preview.request])
        #expect(preview.shownText.hasPrefix(CloudWords.previewSignInFirst + "\n" + signIn.shownText + "\n\n"
                                            + CloudWords.previewThenMessage + "\n"))
        #expect(preview.shownText.hasSuffix(preview.request.shownText))
        #expect(preview.shownText.contains(#"{"device":"made-up"}"#))
    }

    /// Without a yes to the preview that shows it, sign-in never goes:
    /// not on Don't send, not with the setting off, not for words that stay
    /// here. Its answer is never asked for either.
    @Test func signInNeverGoesWithoutAYesToThePreviewThatShowsIt() async throws {
        let hop = CloudSignIn(path: "v1/sign-in", body: Data("{}".utf8))
        for (answer, isOn, line) in [(CloudConsent.cancel, true, "Plan my week"), (.send, false, "Plan my week"),
                                     (.send, true, "I want to kill myself")] {
            let transport = RecordingTransport()
            let reviewer = RecordingReviewer(answer: answer)
            let auth = SampleAuth(signIn: hop)
            let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth,
                                   isOn: { isOn })
            _ = try? await cloudChat().sending(line, with: cloud)
            #expect(transport.sent.isEmpty, "\(answer) \(isOn) \(line)")
            #expect(auth.answers.isEmpty)
            #expect(reviewer.seen.allSatisfy { $0.signIn != nil })
            // Don't send saw the preview with the hop in it; the others
            // stopped before any preview.
            #expect(reviewer.seen.count == (answer == .cancel ? 1 : 0), "\(answer) \(isOn) \(line)")
        }
    }

    // MARK: What sign-in may carry

    /// Sign-in values are covered on the card, so a name from the notes, a
    /// private word or another personal detail in one would go unseen.
    /// Any value the redactor would change, in the hop's body or headers or
    /// in the message's sign-in headers, is refused: nothing is shown and
    /// nothing reaches the transport.
    @Test(arguments: [
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"lemon cake"}"#.utf8))),
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"Sam"}"#.utf8))),
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"note":"Sam's birthday","id":7}"#.utf8))),
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"who":"sam.lee@example.com"}"#.utf8))),
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data(#"{"phone":4165550199}"#.utf8))),
        SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", headers: ["X-Sample-Device": "lemon-cake"],
                                       body: Data("{}".utf8))),
        SampleAuth(headers: ["X-Sample-Sign-In": "Sam"]),
    ])
    func aSignInValueWithAPersonalDetailIsRefusedAndNothingIsSent(auth: SampleAuth) async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let notes = notes
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth,
                               redactor: { Redactor(memory: notes, privateWords: ["lemon cake"]) })
        await #expect(throws: CloudTransportError.signInCarriesPersonalDetails) {
            try await cloudChat().sending("Plan my week", with: cloud)
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
        #expect(auth.answers.isEmpty)
    }

    /// The same values with nothing personal in them go as shown.
    @Test func aSignInWithOnlyATokenIsShownAndSent() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let notes = notes
        let auth = SampleAuth(headers: ["X-Sample-Sign-In": "made-up-token"],
                              signIn: CloudSignIn(path: "v1/sign-in", headers: ["X-Sample-Device": "made-up"],
                                                  body: Data(#"{"device":"made-up-device","build":7}"#.utf8)))
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth,
                               redactor: { Redactor(memory: notes, privateWords: ["lemon cake"]) })
        _ = try await cloudChat().sending("Plan my week", with: cloud)
        #expect(transport.sent == reviewer.seen.first?.hops)
        #expect(transport.sent.count == 2)
    }

    /// A sign-in body is a flat JSON object of short strings or numbers,
    /// as a credential or device token is. Anything else is refused before
    /// a preview, so the card never covers a document.
    @Test func aSignInBodyThatIsNotAFlatObjectOfShortValuesIsRefused() async throws {
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let longest = String(repeating: "a", count: CloudSignIn.maxValueLength)
        for body in [#"{"a":{"b":"c"}}"#, #"{"a":["b"]}"#, #"["a"]"#, "token=made-up", "", #"{"a":true}"#,
                     #"{"a":null}"#, #""a""#, "{\"a\":\"\(longest)a\"}"] {
            #expect(throws: CloudTransportError.signInBodyRefused, "\(body.prefix(40))") {
                try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                       signIn: CloudSignIn(path: "v1/sign-in", body: Data(body.utf8)))
            }
        }
        for body in ["{}", #"{"device":"made-up","build":7,"scale":1.5}"#, "{\"a\":\"\(longest)\"}"] {
            #expect(throws: Never.self, "\(body.prefix(40))") {
                try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                       signIn: CloudSignIn(path: "v1/sign-in", body: Data(body.utf8)))
            }
        }
        // Through a reply: nothing shown, nothing sent.
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               auth: SampleAuth(signIn: CloudSignIn(path: "v1/sign-in",
                                                                    body: Data(#"{"note":{"text":"x"}}"#.utf8))))
        await #expect(throws: CloudTransportError.signInBodyRefused) {
            try await cloudChat().sending("Plan my week", with: cloud)
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    /// With the yes, the sign-in hop goes first and then the message, each
    /// exactly as shown, and sign-in is handed its answer.
    @Test func theYesSendsTheSignInHopThenTheMessageExactlyAsShown() async throws {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let auth = SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", headers: ["X-Sample-Device": "made-up"],
                                                  body: Data(#"{"device":"made-up"}"#.utf8)))
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer, auth: auth)
        _ = try await cloudChat().sending("Plan my week", with: cloud)
        let preview = try #require(reviewer.seen.first)
        #expect(transport.sent == preview.hops)
        #expect(transport.sent.first?.url.path == "/v1/sign-in")
        #expect(auth.answers == [transport.reply])
    }

    /// A sign-in hop stays on the address shown: https, the same host and
    /// port, under the same path. A path that could leave any of those, or
    /// that URLSession might read differently from the preview, is refused
    /// before anything is shown or sent.
    @Test func aSignInHopStaysOnTheAddressShown() throws {
        var turns = cloudChat().turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let ported = try #require(URL(string: "https://cloud.example.com:8443/api"))
        for endpoint in [endpoint, ported] {
            for path in ["v1/sign-in", "sign-in", "v1/a.b_c~d"] {
                let hop = try #require(try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                                              signIn: CloudSignIn(path: path, body: Data("{}".utf8))).signIn)
                #expect(hop.url.scheme == "https", "\(path)")
                #expect(hop.url.host == endpoint.host, "\(path)")
                #expect(hop.url.port == endpoint.port, "\(path)")
                #expect(hop.url.path == endpoint.path + "/" + path, "\(path)")
                #expect(hop.url.query == nil && hop.url.fragment == nil, "\(path)")
            }
            for path in ["//elsewhere.example.org/x", "https://elsewhere.example.org/x", "http://cloud.example.com/x",
                         "https://cloud.example.com:80/x", "%2F%2Felsewhere.example.org/x", #"\\elsewhere.example.org/x"#,
                         "@elsewhere.example.org/x", "#frag", "?to=elsewhere", "../../x", "v1/../x", "./x",
                         "v1//x", "/x", "x/", "", "v1/sign in",
                         // Dot segments written encoded, which a URL can read as the real ones.
                         "%2e%2e/x", "v1/%2E%2E/x", "%2e/x"] {
                #expect(throws: CloudTransportError.signInPathRefused(path), "\(path)") {
                    try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                           signIn: CloudSignIn(path: path, body: Data("{}".utf8)))
                }
            }
        }
    }

    /// A refused sign-in path shows nothing and sends nothing.
    @Test func aReplyWithARefusedSignInPathShowsAndSendsNothing() async {
        let transport = RecordingTransport()
        let reviewer = RecordingReviewer(answer: .send)
        let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: reviewer,
                               auth: SampleAuth(signIn: CloudSignIn(path: "../x", body: Data())))
        await #expect(throws: CloudTransportError.signInPathRefused("../x")) {
            try await cloudChat().sending("Plan my week", with: cloud)
        }
        #expect(reviewer.seen.isEmpty)
        #expect(transport.sent.isEmpty)
    }

    /// Forget everything or a switch off can land while the sign-in hop is
    /// on the wire. Its answer then never reaches sign-in, and the message
    /// never goes.
    @Test func aSignInAnswerThatLandsAfterTheChatEndedIsNotKept() async throws {
        for ends in [true, false] {
            let session = CloudChatSession()
            let on = Flag(true)
            let transport = EndingTransport { ends ? session.end() : (on.value = false) }
            let auth = SampleAuth(signIn: CloudSignIn(path: "v1/sign-in", body: Data("{}".utf8)))
            let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send),
                                   auth: auth, isOn: { on.value }, session: session)
            await #expect(throws: ends ? CloudModelError.ended : CloudModelError.off) {
                try await cloudChat().sending("Plan my week", with: cloud)
            }
            #expect(transport.sends == 1, "only the hop went")
            #expect(auth.answers.isEmpty)
        }
    }

    /// Forget everything can start in the very window between the last
    /// check and the hand over. The chat is ended under the same lock as
    /// the hand over, so ending waits for it, and sign-in's `forget()`,
    /// which comes after the end, always comes after the answer too. No
    /// token outlives the forget.
    @Test func aSignInAnswerNeverOutlivesTheForgetThatEndsTheChat() async throws {
        let session = CloudChatSession()
        let auth = KeepingAuth()
        let answered = Flag(false)
        let forgetting = OnceInTheBackground()
        let transport = EndingTransport { answered.value = true }
        let cloud = CloudModel(
            endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send),
            auth: auth, redactor: { Redactor() },
            isOn: {
                // The hop has answered, so this is the check just before
                // the hand over. Forget everything starts on another
                // thread now, and is given time to finish if nothing holds
                // it back.
                if answered.value, forgetting.start({ session.end(); auth.forget() }) {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return true
            },
            session: session
        )
        // The message may or may not get out before the end lands; either
        // way is fine here. What matters is the order of the hand over and
        // the forget.
        _ = try? await cloudChat().sending("Plan my week", with: cloud)
        await forgetting.finished()
        #expect(auth.handedOver == 1, "the answer was handed over before the chat ended")
        #expect(auth.token == nil, "a token was kept after sign-in forgot")
    }

    /// The Host line is what URLSession writes: no port when it is the
    /// scheme's own, and an IPv6 address in brackets.
    @Test func theHostLineIsWrittenAsTheWireWritesIt() throws {
        for (address, host) in [("https://cloud.example.com", "cloud.example.com"),
                                ("https://cloud.example.com:443", "cloud.example.com"),
                                ("https://cloud.example.com:8443", "cloud.example.com:8443"),
                                ("https://[::1]", "[::1]"),
                                ("https://[::1]:8443", "[::1]:8443"),
                                ("https://[2001:db8::1]:443/v1", "[2001:db8::1]")] {
            let url = try #require(URL(string: address))
            #expect(CloudRequest.hostLine(for: url) == host, "\(address)")
            let shown = CloudRequest.shownText(method: "POST", url: url, headers: [:], body: Data())
            #expect(shown.contains("\nHost: \(host)\n"), "\(address)")
        }
    }

    // MARK: Ending a chat

    /// Forget everything ends a cloud chat: what it hid so far goes, a send
    /// on the wire is cancelled, and nothing more is sent from it.
    @Test func endingAChatDropsWhatItHidAndCancelsTheSendOnTheWire() async throws {
        let wire = HangingTransport()
        let session = CloudChatSession()
        let cloud = CloudModel(endpoint: endpoint, transport: wire, reviewer: RecordingReviewer(answer: .send),
                               redactor: { Redactor(names: ["Sam"], privateWords: ["lemon cake"]) }, session: session)
        let reply = Task { try await cloudChat().sending("Ask Sam about the lemon cake", with: cloud) }
        await wire.started()
        #expect(session.hiddenSoFar.privateWords == ["lemon cake"])
        #expect(session.sendsOnTheWire == 1)
        session.end()
        #expect(await finishes { await wire.whenCancelled() }, "the send on the wire was never cancelled")
        #expect(wire.cancelled)
        // Stopped here too, so the test never waits on a send left running.
        reply.cancel()
        await #expect(throws: (any Error).self) { try await reply.value }
        #expect(session.hiddenSoFar == Redactor())
        #expect(session.sendsOnTheWire == 0)
        #expect(session.hasEnded)
        await #expect(throws: CloudModelError.ended) {
            try await cloudChat().sending("Thanks", with: cloud)
        }
        #expect(wire.sends == 1)
    }

    /// The session tells its owner just before each request is handed over,
    /// so Forget everything can say honestly that a copy may have left.
    @Test func handingARequestOverIsToldFirst() async throws {
        let handed = Flag(false)
        let transport = RecordingTransport()
        let session = CloudChatSession(handingOver: { handed.value = true })
        let cancelled = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .cancel),
                                   session: session)
        _ = try? await cloudChat().sending("Plan my week", with: cancelled)
        #expect(!handed.value)
        // The transport notes the flag as each send reaches it: already set.
        let witness = WitnessTransport(flag: handed)
        let sent = CloudModel(endpoint: endpoint, transport: witness, reviewer: RecordingReviewer(answer: .send),
                              session: session)
        _ = try await cloudChat().sending("Plan my week", with: sent)
        #expect(witness.seen == [true])
        #expect(handed.value)
    }

    /// A sign-in hop that was handed over counts as sent, even when the
    /// message after it fails on the wire or never goes because the cloud
    /// was turned off: the hop alone may have left.
    @Test func aSignInHopHandedOverCountsAsSentWhateverHappensToTheMessage() async throws {
        let hop = CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8))
        for messageFails in [true, false] {
            let handed = Flag(false)
            let on = Flag(true)
            let session = CloudChatSession(handingOver: { handed.value = true })
            let transport = HopThenTransport(messageFails: messageFails) { on.value = false }
            let cloud = CloudModel(endpoint: endpoint, transport: transport, reviewer: RecordingReviewer(answer: .send),
                                   auth: SampleAuth(signIn: hop), isOn: { on.value }, session: session)
            await #expect(throws: (any Error).self) { try await cloudChat().sending("Plan my week", with: cloud) }
            #expect(handed.value, "messageFails: \(messageFails)")
            #expect(transport.paths.first == "/v1/sign-in")
            #expect(transport.paths.count == (messageFails ? 2 : 1))
        }
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
        let onWithoutAddress = ModelChoice.model(settings: CloudHelpSettings(isOn: true, for: endpoint), endpoint: CloudEndpoint.url(from: ""),
                                                 local: LocalStubModel(), cloud: cloud)
        #expect(offWithAddress.runsOnDevice)
        #expect(onWithoutAddress.runsOnDevice)
        #expect(!made.value)
        let on = ModelChoice.model(settings: CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, local: LocalStubModel()) { url in
            CloudModel(endpoint: url, transport: RecordingTransport(), reviewer: RecordingReviewer(answer: .cancel))
        }
        #expect(!on.runsOnDevice)
    }

    /// The onboarding hello asks this on every redraw, so it must agree
    /// with the model a chat would get without making one.
    @Test(arguments: [false, true], [false, true])
    func knowingWhetherANewChatRunsOnDeviceMakesNoModel(isOn: Bool, hasAddress: Bool) {
        let settings = CloudHelpSettings(isOn: isOn, for: endpoint)
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

/// True when `work` finishes within `limit`. A passing test never waits on
/// the limit; it only turns a wait that would never end, as when the code
/// under test is broken, into a plain failure.
func finishes(within limit: Duration = .seconds(20), _ work: @escaping @Sendable () async -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let first = FirstAnswer(continuation)
        // Stopped once the work is done, so no sleeper outlives the test.
        let limiter = Task {
            do {
                try await Task.sleep(for: limit)
                first.give(false)
            } catch {}
        }
        Task {
            await work()
            first.give(true)
            limiter.cancel()
        }
    }
}

/// Resumes a continuation with the first answer given, and ignores the rest.
final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func give(_ answer: Bool) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: answer)
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

/// Notes `flag`'s value as each send reaches it, then answers.
final class WitnessTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [Bool] = []
    let flag: Flag

    init(flag: Flag) { self.flag = flag }

    var seen: [Bool] { lock.withLock { _seen } }

    func send(_ request: CloudRequest) async throws -> Data {
        let now = flag.value
        lock.withLock { _seen.append(now) }
        return try JSONEncoder().encode(["reply": "Here's a short note you can send."])
    }
}

/// Runs `whileSending` during each send, as Forget everything or a switch
/// off landing while a hop is on the wire would, then answers.
final class EndingTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sends = 0
    private let whileSending: @Sendable () -> Void

    init(whileSending: @escaping @Sendable () -> Void) { self.whileSending = whileSending }

    var sends: Int { lock.withLock { _sends } }

    func send(_ request: CloudRequest) async throws -> Data {
        lock.withLock { _sends += 1 }
        whileSending()
        return Data(#"{"token":"made-up"}"#.utf8)
    }
}

struct BrokenTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data { Data("not json".utf8) }
}

/// Answers the sign-in hop. Then the message either fails on the wire, or
/// `afterHop` runs, as a switch off just after the hop would, and the
/// message never comes.
final class HopThenTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private let messageFails: Bool
    private let afterHop: @Sendable () -> Void

    init(messageFails: Bool, afterHop: @escaping @Sendable () -> Void) {
        self.messageFails = messageFails
        self.afterHop = afterHop
    }

    var paths: [String] { lock.withLock { _paths } }

    func send(_ request: CloudRequest) async throws -> Data {
        let first = lock.withLock {
            _paths.append(request.url.path)
            return _paths.count == 1
        }
        if first {
            if !messageFails { afterHop() }
            return Data(#"{"token":"made-up"}"#.utf8)
        }
        throw URLError(.networkConnectionLost)
    }
}

/// Sign-in that keeps the token its hop brings back, and lets go of it on
/// `forget()`, as a Keychain-backed one would.
final class KeepingAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var _token: Data?
    private var _handedOver = 0

    var token: Data? { lock.withLock { _token } }
    var handedOver: Int { lock.withLock { _handedOver } }

    func headers(for url: URL) -> [String: String] { [:] }

    func signIn(for endpoint: URL) -> CloudSignIn? {
        CloudSignIn(path: "v1/sign-in", body: Data(#"{"device":"made-up"}"#.utf8))
    }

    func signedIn(_ answer: Data) {
        lock.withLock {
            _token = answer
            _handedOver += 1
        }
    }

    func forget() {
        lock.withLock { _token = nil }
    }
}

/// Runs one piece of work on another thread, the first time it is asked,
/// and says when that work is done.
final class OnceInTheBackground: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let group = DispatchGroup()

    /// True only the first time, when `work` was started.
    func start(_ work: @escaping @Sendable () -> Void) -> Bool {
        let first = lock.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return false }
        group.enter()
        DispatchQueue.global().async { [group] in
            work()
            group.leave()
        }
        return true
    }

    func finished() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
}

#if canImport(Network)
/// A tiny HTTP server on 127.0.0.1, so a test can see the bytes the real
/// URLSession sends without anything leaving this Mac. It answers every
/// request with a reply, sets a cookie on the sign-in hop's answer, as a
/// server's might, and keeps each request's path and headers.
final class LoopbackServer: @unchecked Sendable {
    struct Seen: Sendable {
        let path: String
        /// Header names in lower case.
        let headers: [String: String]
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var _requests: [Seen] = []
    private var ready: CheckedContinuation<UInt16, Never>?

    var requests: [Seen] { lock.withLock { _requests } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening, and gives back the port once it is ready.
    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            lock.withLock { ready = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                let waiting = self.lock.withLock {
                    defer { self.ready = nil }
                    return self.ready
                }
                waiting?.resume(returning: self.listener.port?.rawValue ?? 0)
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.read(connection, Data())
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in head.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if buffer.count - end.upperBound >= length {
                    let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    self.lock.withLock { self._requests.append(Seen(path: path, headers: headers)) }
                    self.answer(connection, signIn: path.hasSuffix("/sign-in"))
                    return
                }
            }
            if done || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer)
        }
    }

    private func answer(_ connection: NWConnection, signIn: Bool) {
        let body = #"{"reply":"Here's a short note you can send."}"#
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if signIn { head += "Set-Cookie: session=made-up-cookie; Path=/; Max-Age=3600\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

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

/// Sign-in that hands back made-up headers and a made-up sign-in hop, and
/// keeps every answer it is handed.
final class SampleAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private let fixed: [String: String]
    private let hop: CloudSignIn?
    private var _answers: [Data] = []

    init(headers: [String: String] = [:], signIn: CloudSignIn? = nil) {
        fixed = headers
        hop = signIn
    }

    var answers: [Data] { lock.withLock { _answers } }

    func headers(for url: URL) -> [String: String] { fixed }

    func signIn(for endpoint: URL) -> CloudSignIn? { hop }

    func signedIn(_ answer: Data) {
        lock.withLock { _answers.append(answer) }
    }
}

/// A transport that holds every send until it is cancelled, and says so.
/// Nothing touches the network; the wait is a sleep cancellation cuts short.
final class HangingTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sends = 0
    private var _cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var sends: Int { lock.withLock { _sends } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    /// Returns once a send has started.
    func started() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if _sends > 0 { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once a send was cancelled.
    func whenCancelled() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if _cancelled { return true }
                cancelWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func send(_ request: CloudRequest) async throws -> Data {
        let waiting = lock.withLock {
            _sends += 1
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            let cancelled = lock.withLock {
                _cancelled = true
                defer { cancelWaiters = [] }
                return cancelWaiters
            }
            for waiter in cancelled { waiter.resume() }
            throw error
        }
        return Data()
    }
}
