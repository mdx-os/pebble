#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// Stands in for URLSession behind the real transport: records every
/// URLRequest and answers with a fixed reply. Never touches the network.
final class FakeWire: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [URLRequest] = []

    var sent: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    @Sendable func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _sent.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (try JSONEncoder().encode(["reply": "Here's a short note."]), response)
    }

    /// Every body that went out, read as text.
    var sentText: [String] { sent.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
}

/// Counts how often a transport is made, which only happens with the cloud on.
final class TransportMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    let wire = FakeWire()

    var made: Int {
        lock.lock(); defer { lock.unlock() }
        return _made
    }

    func make() -> any CloudTransport {
        lock.lock(); _made += 1; lock.unlock()
        return URLSessionCloudTransport(load: wire.load)
    }
}

/// Counts sign-ins. Its headers are made up.
final class CountingAuth: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var _signIns = 0

    var signIns: Int {
        lock.lock(); defer { lock.unlock() }
        return _signIns
    }

    func headers(for url: URL) -> [String: String] { ["X-Sample-Sign-In": "made-up"] }

    func signIn() async {
        lock.withLock { _signIns += 1 }
    }
}

@MainActor
struct CloudHelpTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!

    func help(_ settings: CloudHelpSettings = .off, endpoint: URL?, maker: TransportMaker,
              memory: MemoryStore? = nil, store: InMemoryCloudHelpStore? = nil,
              auth: any CloudAuth = NoCloudAuth()) -> CloudHelp {
        CloudHelp(store: store ?? InMemoryCloudHelpStore(settings), endpoint: endpoint, memory: memory ?? scratchMemory(),
                  auth: auth, transport: { maker.make() })
    }

    /// A chat on whatever model the setting picks, with its own preview
    /// gate and no reply beat.
    func chat(_ cloud: CloudHelp, conversation: Conversation? = nil) -> ChatController {
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        return ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                   conversation: conversation, review: model.runsOnDevice ? nil : review,
                                   replyBeat: .zero)
    }

    func personTurns(_ controller: ChatController) -> [String] {
        controller.conversation.turns.filter { $0.speaker == .person }.map(\.text)
    }

    // MARK: Off by default

    @Test func offByDefaultMakesNoTransportAndKeepsChatsOnDevice() async throws {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        #expect(!cloud.settings.isOn)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        #expect(model.runsOnDevice)
        #expect(cloud.runsOnDevice(local: LocalStubModel()))
        let chat = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                       conversation: nil)
        #expect(chat.conversation.onDevice)
        #expect(chat.review == nil)
        _ = try await chat.conversation.sending("Help me plan my morning.", with: model)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(review.pending == nil)
    }

    @Test func anEmptyAddressMeansDisabledEvenIfSavedOn() {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: CloudEndpoint.url(from: ""), maker: maker)
        #expect(!cloud.isAvailable)
        #expect(!cloud.usesCloudForNewChats)
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        cloud.setOn(true)
        #expect(!cloud.asksToTurnOn)
        cloud.confirmTurnOn()
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        #expect(maker.made == 0)
    }

    // MARK: Turning it on

    @Test func turningOnAsksFirstAndOnlyYesTurnsItOn() {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        cloud.setOn(true)
        #expect(cloud.asksToTurnOn)
        #expect(!cloud.settings.isOn)
        cloud.declineTurnOn()
        #expect(!cloud.settings.isOn)
        #expect(cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.settings.isOn)
        #expect(cloud.usesCloudForNewChats)
        #expect(!cloud.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        cloud.setOn(false)
        #expect(!cloud.settings.isOn)
        #expect(!cloud.asksToTurnOn)
    }

    /// Sign-in may use the network, so it waits for the person's yes.
    @Test func signInHappensOnlyAfterTheYes() async {
        let auth = CountingAuth()
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), auth: auth)
        cloud.setOn(true)
        cloud.declineTurnOn()
        cloud.setOn(true)
        #expect(cloud.signingIn == nil)
        #expect(auth.signIns == 0)
        cloud.confirmTurnOn()
        await cloud.signingIn?.value
        #expect(auth.signIns == 1)
    }

    @Test func theQuestionSaysWhatChangesWithoutOverclaiming() {
        let words = CloudWords.askPoints.joined(separator: " ")
        for promise in ["not on this device", "exactly what goes", "names", "emails", "phone numbers",
                        "addresses", "card numbers", "private words", "never leave this device",
                        "send nothing", "turn this off anytime"] {
            #expect(words.contains(promise), "missing: \(promise)")
        }
        // Taking things out is a best effort; the preview is the safeguard.
        #expect(CloudWords.askPoints[2].hasPrefix("I try to take out"))
    }

    // MARK: The preview

    @Test func theSheetShowsExactlyTheRequestThatIsSent() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]), endpoint: endpoint,
                         maker: maker, memory: scratchMemory("Sam's birthday is May 14."), auth: CountingAuth())
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        let chat = Conversation.firstRun(named: "Pip", onDevice: false)
        let reply = Task { try await chat.sending("Ask Sam to bring the lemon cake to 42 Maple Street.", with: model) }
        let preview = await review.shown()
        let shown = CloudPreviewSheet.shownText(preview)
        #expect(shown.hasPrefix("POST https://cloud.example.com/v1/reply\n"))
        #expect(shown.contains("X-Sample-Sign-In: made-up"))
        #expect(shown.contains("User-Agent: pebble"))
        #expect(shown.contains("Ask [name] to bring the [private] to [address]."))
        #expect(CloudPreviewSheet.hiddenLine(preview) == "Taken out: 1 private word, 1 address, 1 name.")
        #expect(maker.wire.sent.isEmpty)
        review.answer(.send, for: preview.id)
        let next = try await reply.value
        #expect(next.turns.last?.text == "Here's a short note.")
        let sent = try #require(maker.wire.sent.first)
        #expect(maker.wire.sent.count == 1)
        // What URLSession was handed, laid out the same way, is what the person read.
        let wire = CloudRequest.shownText(method: try #require(sent.httpMethod), url: try #require(sent.url),
                                          headers: sent.allHTTPHeaderFields ?? [:], body: sent.httpBody ?? Data())
        #expect(wire == shown)
        #expect(sent.allHTTPHeaderFields == preview.request.headers)
        #expect(review.pending == nil)
    }

    @Test func notSendingTakesTheTurnBackAndTheWordsNeverGoLater() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Write a note about my diagnosis")
        let declined = await review.shown()
        review.answer(.cancel, for: declined.id)
        await controller.settled()
        #expect(!controller.isReplying)
        #expect(controller.failure == CloudWords.notSent)
        #expect(controller.draft == "Write a note about my diagnosis")
        // The declined words are out of the chat, not just back in the composer.
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
        // The next line is sent without them.
        controller.draft = ""
        controller.submit("Plan my week")
        let next = await review.shown()
        #expect(!next.request.text.contains("diagnosis"))
        review.answer(.send, for: next.id)
        await controller.settled()
        #expect(maker.wire.sent.count == 1)
        #expect(maker.wire.sentText.allSatisfy { !$0.contains("diagnosis") })
        #expect(personTurns(controller) == ["Plan my week"])
    }

    @Test func turningOffWhileThePreviewShowsSendsNothingAndTakesTheTurnBack() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        cloud.setOn(false)
        await controller.settled()
        #expect(controller.failure == CloudWords.notSent)
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
        // A later line in the same chat is not sent either, and is taken back too.
        controller.draft = ""
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Plan my week")
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func stoppingAReplyClosesThePreviewAndSendsNothing() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        let reply = Task { try await Conversation.firstRun(named: "Pip").sending("Plan my week", with: model) }
        _ = await review.shown()
        reply.cancel()
        await #expect(throws: (any Error).self) { try await reply.value }
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// The race: a new question replaces the one on screen. A Send meant
    /// for the old one must not send the new one, which was never seen.
    @Test func aTapOnOnePreviewNeverSendsAnother() async throws {
        let review = CloudReview()
        let request = CloudRequest(url: CloudModel.url(for: endpoint), headers: CloudHeaders.fixed, body: Data("{}".utf8))
        let first = CloudPreview(request: request, hidden: [:])
        let second = CloudPreview(request: request, hidden: [:])
        let firstAnswer = Task { await review.review(first) }
        #expect(await review.shown() == first)
        let secondAnswer = Task { await review.review(second) }
        // Asking the second question withdraws the first.
        #expect(await firstAnswer.value == .cancel)
        #expect(review.pending == second)
        // A late tap on the first sheet does nothing to the second.
        review.answer(.send, for: first.id)
        review.answer(.cancel, for: first.id)
        #expect(review.pending == second)
        review.answer(.send, for: second.id)
        #expect(await secondAnswer.value == .send)
        #expect(review.pending == nil)
    }

    @Test func aScreenshotPreviewCanBeDismissed() {
        let review = CloudReview()
        let preview = CloudPreview(request: CloudRequest(url: endpoint, headers: [:], body: Data()), hidden: [:])
        review.show(preview)
        review.answer(.cancel, for: preview.id)
        #expect(review.pending == nil)
    }

    /// Going back to Today, or to another place in the sidebar, while a
    /// preview waits means it is not sent, and the reply never hangs.
    @Test func aPreviewIsNotSentWhenTheChatScreenGoesAway() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        controller.screenWentAway()
        await controller.settled()
        #expect(!controller.isReplying)
        #expect(review.pending == nil)
        #expect(controller.failure == CloudWords.notSent)
        #expect(controller.draft == "Plan my week")
        #expect(personTurns(controller).isEmpty)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Each chat, and so each window, has its own preview. One chat's
    /// question never shows over another's.
    @Test func eachChatShowsOnlyItsOwnPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let one = chat(cloud), two = chat(cloud)
        let oneReview = try #require(one.review), twoReview = try #require(two.review)
        #expect(oneReview !== twoReview)
        one.submit("Plan my week")
        _ = await oneReview.shown()
        #expect(twoReview.pending == nil)
        two.submit("Plan my weekend")
        _ = await twoReview.shown()
        // Turning the cloud off withdraws both.
        cloud.setOn(false)
        await one.settled()
        await two.settled()
        #expect(oneReview.pending == nil && twoReview.pending == nil)
        #expect(one.failure == CloudWords.notSent && two.failure == CloudWords.notSent)
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: Notes the redactor can't read

    @Test func unreadableNotesSendNothingAndSaySo() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory()
        try Data("not notes".utf8).write(to: memory.fileURL)
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker, memory: memory)
        let controller = chat(cloud)
        controller.submit("Write to Sam")
        await controller.settled()
        #expect(controller.failure == CloudWords.notesUnreadable)
        #expect(controller.review?.pending == nil)
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Write to Sam")
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func unreadablePrivateWordsSendNothing() async throws {
        let maker = TransportMaker()
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let cloud = help(endpoint: endpoint, maker: maker, store: store)
        let controller = chat(cloud)
        store.makeUnreadable()
        controller.submit("Bring the lemon cake")
        await controller.settled()
        // Settings that can't be read count as off.
        #expect(controller.failure == CloudWords.turnedOff)
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
        // And nothing is saved over them while they can't be read.
        cloud.newPrivateWord = "Sam"
        cloud.addPrivateWord()
        #expect(cloud.status == CloudWords.privateUnreadable)
        store.makeUnreadable(false)
        #expect(try store.load().privateWords == ["lemon cake"])
    }

    /// The memory screen and the redactor share one store, so a note just
    /// saved counts in the very next request.
    @Test func aNoteJustSavedIsHiddenInTheNextRequest() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker, memory: memory)
        #expect(cloud.memory === memory)
        let notes = MemoryModel(store: memory)
        notes.newNote = "Priya is my sister."
        notes.add()
        let controller = chat(cloud)
        controller.submit("Plan a dinner for Priya")
        let preview = try await #require(controller.review).shown()
        #expect(preview.request.text.contains("Plan a dinner for [name]"))
        controller.screenWentAway()
        await controller.settled()
    }

    // MARK: Private words

    @Test func forgetEverythingErasesThePrivateWordsToo() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let model = MemoryModel(store: memory, alsoForget: { try cloud.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(memory.notes().isEmpty)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(try store.load() == CloudHelpSettings(isOn: true, privateWords: []))
    }

    @Test func addingAPrivateWordKeepsWordsSavedElsewhere() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let cloud = help(endpoint: endpoint, maker: TransportMaker(), store: store)
        // Saved by another window since this one loaded.
        try store.save(CloudHelpSettings(privateWords: ["lemon cake", "Riverside Clinic"]))
        cloud.newPrivateWord = "Sam"
        cloud.addPrivateWord()
        #expect(try store.load().privateWords == ["lemon cake", "Riverside Clinic", "Sam"])
        #expect(cloud.newPrivateWord.isEmpty)
    }

    // MARK: The on-device promise and care

    @Test func anOnDeviceConversationIsNeverHandedToTheCloud() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let review = CloudReview()
        let model = cloud.chatModel(local: LocalStubModel(), review: review)
        // A chat that promised on-device is not reused with the cloud model.
        let promised = Conversation.firstRun(named: "Pip", onDevice: true)
        let controller = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: promised)
        #expect(!controller.conversation.onDevice)
        #expect(controller.conversation.turns.first?.text.contains("stays") == false)
        #expect(controller.presence == CloudWords.presence)
        // And sent directly, it is refused before any preview.
        await #expect(throws: ConversationError.leavesDevice) {
            try await promised.sending("Write to Sam", with: model)
        }
        #expect(review.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func careIsAnsweredHereWithNoPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        controller.submit("I want to kill myself")
        await controller.settled()
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A chat that holds words that must stay here can never be sent
    /// again. It says so warmly and points to a new chat, rather than
    /// asking the person to send again forever.
    @Test func aChatThatMustStayHereSaysSoAndPointsToANewChat() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        var turns = Conversation.firstRun(named: "Pip", onDevice: false).turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "What does a crisis line do?"))
        turns.append(ChatTurn(id: UUID(), speaker: .agent, text: "It's there for anyone thinking about suicide, any time."))
        let controller = chat(cloud, conversation: Conversation(turns: turns, onDevice: false))
        controller.submit("Thanks")
        await controller.settled()
        #expect(controller.failure == CloudWords.staysHere)
        #expect(controller.failure != FirstConversation.couldNotAnswer)
        #expect(CloudWords.staysHere.contains("new chat"))
        #expect(controller.conversation.turns.count == turns.count)
        #expect(controller.draft == "Thanks")
        #expect(controller.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func theOnDeviceHeaderStaysForOnDeviceChats() {
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        #expect(controller.presence == FirstConversation.presence)
    }

    @Test func eachFailureHasItsOwnLine() {
        #expect(ChatController.failureLine(for: CloudModelError.notSent) == CloudWords.notSent)
        #expect(ChatController.failureLine(for: CloudModelError.off) == CloudWords.turnedOff)
        #expect(ChatController.failureLine(for: CloudModelError.staysHere) == CloudWords.staysHere)
        #expect(ChatController.failureLine(for: CloudModelError.notesUnreadable) == CloudWords.notesUnreadable)
        #expect(ChatController.failureLine(for: CloudModelError.unreadableReply) == FirstConversation.couldNotAnswer)
        // Only a reply that went out keeps the person's turn.
        #expect(!ChatController.nothingWasSent(CloudModelError.unreadableReply))
        #expect(!ChatController.nothingWasSent(URLError(.timedOut)))
    }

    // MARK: VoiceOver, privacy and size

    @Test func voiceOverReadsEachMessageWithMasksInWords() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam at 416-555-0199"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let lines = CloudPreviewSheet.spokenLines(preview)
        #expect(lines.first == "Going to https://cloud.example.com/v1/reply.")
        #expect(lines.contains { $0.hasPrefix("Sent with these labels: Accept, application/json.") })
        #expect(lines.last == "You said: Call hidden name at hidden phone number")
        #expect(lines.contains("I said: \(FirstConversation.opening(named: "Pip"))"))
        #expect(!lines.joined().contains("{"))
        #expect(!lines.joined().contains("["))
    }

    /// Marked private, the payload and the word list vanish when the system
    /// hides private things; the rest of the screen stays.
    @Test func thePayloadAndPrivateWordsArePrivacySensitive() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let size = CGSize(width: 390, height: 600)
        // Rendered as an app in use; a still render otherwise counts as in
        // the background.
        let payload = AnyView(CloudPayloadCard(preview: preview).environment(\.scenePhase, .active))
        #expect(try pixels(payload, size: size) != pixels(payload.redacted(reason: .privacy), size: size))
        let words = AnyView(PrivateWordList(words: ["lemon cake"], onRemove: { _ in }).environment(\.scenePhase, .active))
        #expect(try pixels(words, size: size) != pixels(words.redacted(reason: .privacy), size: size))
        // A plain view is not hidden, so the difference is the marking.
        let plain = AnyView(Text("lemon cake").padding())
        #expect(try pixels(plain, size: size) == pixels(plain.redacted(reason: .privacy), size: size))
        // Leaving the app hides them on its own, for the app switcher.
        let leaving = AnyView(CloudPayloadCard(preview: preview).environment(\.scenePhase, .inactive))
        #expect(try pixels(leaving, size: size) == pixels(payload.redacted(reason: .privacy), size: size))
    }

    @Test func privateThingsHideWheneverTheAppIsNotInUse() {
        #expect(privateRedaction(.active).isEmpty)
        #expect(privateRedaction(.inactive) == .privacy)
        #expect(privateRedaction(.background) == .privacy)
    }

    @Test func theAddButtonIsBigEnoughToTap() {
        #expect(CloudHelpView.addButtonSize >= 44)
    }

    @Test func theGoMenuNumbersOnlyTheFirstNinePlaces() {
        #expect(HomeCommands.goShortcut(for: 0)?.key.character == "1")
        #expect(HomeCommands.goShortcut(for: 8)?.key.character == "9")
        #expect(HomeCommands.goShortcut(for: 9) == nil)
        #expect(HomeCommands.goShortcut(for: -1) == nil)
    }

    // MARK: Screens render

    @Test(arguments: [CGSize(width: 393, height: 852), CGSize(width: 1032, height: 1376)])
    func screensRender(size: CGSize) throws {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Call Sam at 416-555-0199"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(names: ["Sam"]))
        let screens: [AnyView] = [
            AnyView(CloudHelpView(help: cloud)),
            AnyView(CloudTurnOnSheet(onYes: {}, onNo: {})),
            AnyView(CloudPreviewSheet(preview: preview, onSend: {}, onCancel: {})),
        ]
        for screen in screens {
            let renderer = ImageRenderer(content: screen.frame(width: size.width, height: size.height))
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(size.width * renderer.scale))
        }
        #expect(maker.made == 0)
    }

    private func pixels(_ view: some View, size: CGSize) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data) as Data
    }

    private func scratchMemory(_ notes: String...) -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-test-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        for note in notes { _ = try? store.remember(note, source: .toldMe) }
        return store
    }
}
#endif
