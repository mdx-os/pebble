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

/// Refuses every request before sending, as the real transport does when
/// the labels aren't the ones shown.
struct RefusingTransport: CloudTransport {
    func send(_ request: CloudRequest) async throws -> Data {
        throw CloudTransportError.headersNotShown
    }
}

/// A settings store whose saves and erases can be made to fail, as a full
/// disk or a failed rename would.
final class FailingCloudStore: CloudHelpStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: CloudHelpSettings?
    private var _savesToFail = 0
    private var _eraseFails = false

    init(_ settings: CloudHelpSettings) { self.settings = settings }

    /// How many of the next saves fail. `Int.max` for all of them.
    var savesToFail: Int {
        get { lock.withLock { _savesToFail } }
        set { lock.withLock { _savesToFail = newValue } }
    }

    var eraseFails: Bool {
        get { lock.withLock { _eraseFails } }
        set { lock.withLock { _eraseFails = newValue } }
    }

    /// What is on disk: nil when there is no file.
    var saved: CloudHelpSettings? { lock.withLock { settings } }

    func load() throws -> CloudHelpSettings { lock.withLock { settings ?? .off } }

    func save(_ next: CloudHelpSettings) throws {
        try lock.withLock {
            if _savesToFail > 0 {
                if _savesToFail != .max { _savesToFail -= 1 }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            settings = next
        }
    }

    func erase() throws {
        try lock.withLock {
            if _eraseFails { throw CocoaError(.fileWriteNoPermission) }
            settings = nil
        }
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

    // MARK: Turning it off fails closed

    func cloud(_ store: any CloudHelpStoring, maker: TransportMaker) -> CloudHelp {
        CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), transport: { maker.make() })
    }

    /// The save fails twice, so the file is erased: off now, in chats
    /// already open, on this screen, and on the next launch.
    @Test func aSwitchOffThatCantBeSavedErasesTheFileAndStaysOff() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.savesToFail = .max
        help.setOn(false)
        #expect(help.status == CloudWords.offButCleared)
        #expect(!help.settings.isOn)
        #expect(store.saved == nil)
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        #expect(controller.review?.pending == nil)
        help.refresh()
        #expect(!help.settings.isOn)
        // The next launch reads it fresh, and it is off.
        #expect(!cloud(store, maker: maker).settings.isOn)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Neither saved nor erased: off for every chat until the app closes,
    /// the switch never flips back on, and the person is told plainly.
    @Test func aSwitchOffThatCantBeSavedOrErasedStaysOffForTheSession() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        store.savesToFail = .max
        store.eraseFails = true
        help.setOn(false)
        #expect(help.status == CloudWords.offForNow)
        #expect(store.saved?.isOn == true)
        controller.submit("Plan my week")
        await controller.settled()
        #expect(controller.failure == CloudWords.turnedOff)
        // Coming back to the screen reads the file, which still says on.
        help.refresh()
        #expect(!help.settings.isOn)
        #expect(!help.usesCloudForNewChats)
        #expect(help.chatModel(local: LocalStubModel(), review: CloudReview()).runsOnDevice)
        // Once saving works again, the switch off is saved then.
        store.savesToFail = 0
        help.refresh()
        #expect(store.saved?.isOn == false)
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func aSaveThatFailsOnceIsTriedAgain() {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = 1
        help.setOn(false)
        #expect(help.status == nil)
        #expect(store.saved == CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
    }

    /// Settings locked away when it is switched off are erased, so a later
    /// unlock can't bring it back on.
    @Test func aSwitchOffWhileTheSettingsCantBeReadErasesThem() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true))
        let help = cloud(store, maker: TransportMaker())
        store.makeUnreadable()
        help.setOn(false)
        #expect(help.status == CloudWords.offButCleared)
        #expect(try store.load() == .off)
    }

    /// A private word saved later keeps the switch off, too.
    @Test func laterChangesKeepTheSwitchOff() {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true))
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        store.eraseFails = true
        help.setOn(false)
        store.savesToFail = 0
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(store.saved == CloudHelpSettings(isOn: false, privateWords: ["Sam"]))
    }

    @Test func aYesThatCantBeSavedLeavesItOffAndSaysSo() async {
        let auth = CountingAuth()
        let store = FailingCloudStore(.off)
        let help = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), auth: auth,
                             transport: { TransportMaker().make() })
        store.savesToFail = .max
        help.setOn(true)
        help.confirmTurnOn()
        #expect(help.status == CloudWords.onNotSaved)
        #expect(!help.settings.isOn)
        #expect(help.signingIn == nil)
        #expect(auth.signIns == 0)
        // Trying again once it can be saved turns it on.
        store.savesToFail = 0
        help.setOn(true)
        help.confirmTurnOn()
        #expect(help.status == nil)
        #expect(help.settings.isOn)
    }

    @Test func aPrivateWordThatCantBeSavedSaysSo() {
        let store = FailingCloudStore(.off)
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateNotSaved)
        #expect(help.newPrivateWord == "Sam")
    }

    /// VoiceOver speaks the same failure again when it happens again.
    @Test func theSameFailureTwiceIsCountedTwice() {
        let store = FailingCloudStore(.off)
        let help = cloud(store, maker: TransportMaker())
        store.savesToFail = .max
        help.newPrivateWord = "Sam"
        help.addPrivateWord()
        let first = help.statusCount
        help.addPrivateWord()
        #expect(help.status == CloudWords.privateNotSaved)
        #expect(help.statusCount == first + 1)
    }

    @Test func theQuestionSaysWhatChangesWithoutOverclaiming() {
        let words = CloudWords.askPoints.joined(separator: " ")
        for promise in ["not on this device", "exactly what goes", "names", "emails", "phone numbers",
                        "addresses", "card numbers", "private words", "never leave this device",
                        "send nothing", "turn this off anytime", "The name you gave me goes too",
                        "internet address"] {
            #expect(words.contains(promise), "missing: \(promise)")
        }
        // Taking things out is a best effort; the preview is the safeguard.
        #expect(CloudWords.askPoints[2].hasPrefix("I try to take out"))
        // The preview doesn't claim nothing else goes: the server sees the
        // device's internet address.
        #expect(!CloudWords.previewDetail.contains("Nothing else"))
        #expect(CloudWords.previewDetail.contains("internet address"))
    }

    /// Every request carries the whole chat again, so neither the question
    /// nor the preview says the words go only once.
    @Test func theWordsSayEarlierMessagesGoAgain() {
        #expect(!CloudWords.previewDetail.contains("only once"))
        #expect(CloudWords.previewDetail.contains("Earlier messages in this chat go again with each new one"))
        #expect(CloudWords.askPoints.contains { $0.contains("Earlier messages in a chat go again with each new one") })
        #expect(CloudWords.all.allSatisfy { !$0.contains("only once") })
    }

    /// Sign-in is a hop the preview doesn't show, so the question names it
    /// in words that stay true whatever sign-in there is, and the promise
    /// "before anything leaves" is about what comes from a chat.
    @Test func theQuestionNamesSignIn() throws {
        let signIn = try #require(CloudWords.askPoints.first { $0.contains("sign in") })
        #expect(signIn.contains("right after your yes"))
        #expect(signIn.contains("never carries your chats, notes or private words"))
        #expect(CloudWords.askPoints[1].hasPrefix("Before anything from a chat leaves"))
        #expect(CloudWords.onDetail.contains("Before anything from a chat leaves"))
        // And any real sign-in has to bring its own line.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleModel/CloudModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("must also ship with its\n    /// own disclosure"))
    }

    /// The question still only signs in after the yes.
    @Test func signInWaitsForTheYes() async {
        let auth = CountingAuth()
        let help = CloudHelp(store: InMemoryCloudHelpStore(), endpoint: endpoint, memory: scratchMemory(), auth: auth,
                             transport: { TransportMaker().make() })
        help.setOn(true)
        #expect(help.asksToTurnOn)
        #expect(help.signingIn == nil)
        help.confirmTurnOn()
        await help.signingIn?.value
        #expect(auth.signIns == 1)
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
        #expect(CloudPreviewSheet.hiddenLine(preview) == "Taken out of this chat: 1 private word, 1 address, 1 name.")
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

    /// The count covers the whole chat, which goes again each time, and the
    /// line says so rather than reading as new for this message.
    @Test func theHiddenCountSaysItIsForTheWholeChat() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Call 416-555-0199")
        let first = await review.shown()
        #expect(CloudPreviewSheet.hiddenLine(first) == "Taken out of this chat: 1 phone number.")
        review.answer(.send, for: first.id)
        await controller.settled()
        controller.submit("Thanks")
        let second = await review.shown()
        // Nothing new was hidden; the one number is still the one number.
        #expect(CloudPreviewSheet.hiddenLine(second) == "Taken out of this chat: 1 phone number.")
        review.answer(.cancel, for: second.id)
        await controller.settled()
    }

    /// A request the transport refuses for its labels never left, so the
    /// turn is taken back and a resend doesn't carry it twice.
    @Test func aRequestRefusedForItsLabelsTakesTheTurnBack() async throws {
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: endpoint,
                              memory: scratchMemory(), transport: { RefusingTransport() })
        let controller = chat(cloud)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        review.answer(.send, for: await review.shown().id)
        await controller.settled()
        #expect(personTurns(controller).isEmpty)
        #expect(controller.draft == "Plan my week")
        controller.draft = ""
        controller.submit("Plan my week")
        let again = await review.shown()
        let payload = try JSONDecoder().decode(CloudPayload.self, from: again.request.body)
        #expect(payload.messages.filter { $0.role == "person" }.map(\.text) == ["Plan my week"])
        review.answer(.cancel, for: again.id)
        await controller.settled()
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

    /// Each half is erased whatever happens to the other, and the line says
    /// what actually went.
    @Test func forgetEverythingErasesTheWordsEvenWhenTheNotesCantBeErased() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        // A folder that can't be changed, so the notes can't be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        let model = MemoryModel(store: memory, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotWordsNotNotes)
        #expect(try store.load().privateWords.isEmpty)
        #expect(memory.notes().count == 1)
    }

    @Test func forgetEverythingErasesTheNotesEvenWhenTheWordsCantBeErased() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        store.eraseFails = true
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: memory, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotNotesNotWords)
        #expect(memory.notes().isEmpty)
    }

    /// Words that can't be saved without them are erased with the file,
    /// which also turns the cloud off, and the line says so.
    @Test func privateWordsThatCantBeSavedAwayAreErasedWithTheFile() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: memory, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotAndCloudOff)
        #expect(CloudWords.forgotAndCloudOff.contains("help from the cloud is off"))
        #expect(store.saved == nil)
        #expect(help.settings == .off)
    }

    /// Words that can't even be read are erased with the file too. Unread,
    /// the setting may have said on, so the line says it is off now.
    @Test func unreadableWordsAreErasedWithTheFileAndTheLineSaysTheCloudIsOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let memory = MemoryStore(fileURL: folder.appendingPathComponent("memory.json"))
        _ = try memory.remember("Sam's birthday is May 14.", source: .toldMe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), memory: memory, store: store)
        store.makeUnreadable()
        let model = MemoryModel(store: memory, alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotWordsAndCloudNotNotes)
        #expect(try store.load() == .off)
    }

    /// When the setting was already off, clearing it turns nothing off, so
    /// the plain line is the true one.
    @Test func clearingASettingThatWasOffSaysOnlyGone() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let help = cloud(store, maker: TransportMaker())
        let model = MemoryModel(store: scratchMemory("Sam's birthday is May 14."),
                                alsoForget: { try help.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(store.saved == nil)
    }

    /// The cloud going off this way closes any preview waiting in an open
    /// chat, and that chat sends nothing more.
    @Test func clearingTheSettingClosesAWaitingPreview() async throws {
        let maker = TransportMaker()
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = cloud(store, maker: maker)
        let controller = chat(help)
        let review = try #require(controller.review)
        controller.submit("Plan my week")
        _ = await review.shown()
        store.savesToFail = .max
        #expect(try help.forgetPrivateWords() == .privateWordsAndCloud)
        await controller.settled()
        #expect(review.pending == nil)
        #expect(controller.failure == CloudWords.notSent)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A word half typed into the field goes with Forget everything too.
    @Test func forgetEverythingClearsAHalfTypedWord() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: TransportMaker(), store: store)
        help.newPrivateWord = "Riverside Cli"
        MemoryModel(store: scratchMemory(), alsoForget: { try help.forgetPrivateWords() }).forgetEverything()
        #expect(help.newPrivateWord.isEmpty)
        // Even when nothing could be erased.
        let failing = FailingCloudStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        failing.savesToFail = .max
        failing.eraseFails = true
        let stuck = cloud(failing, maker: TransportMaker())
        stuck.newPrivateWord = "Riverside Cli"
        #expect(throws: (any Error).self) { try stuck.forgetPrivateWords() }
        #expect(stuck.newPrivateWord.isEmpty)
    }

    /// Forget everything in the middle of a cloud chat never puts what was
    /// hidden back in the clear in that chat's next request.
    @Test func forgettingNeverUnhidesWordsInAnOpenChat() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory("Sam's birthday is May 14.")
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let help = help(endpoint: endpoint, maker: maker, memory: memory, store: store)
        let controller = chat(help)
        let review = try #require(controller.review)
        controller.submit("Ask Sam about the lemon cake")
        review.answer(.send, for: await review.shown().id)
        await controller.settled()
        MemoryModel(store: memory, alsoForget: { try help.forgetPrivateWords() }).forgetEverything()
        #expect(memory.notes().isEmpty && help.settings.privateWords.isEmpty)
        controller.submit("Thanks")
        let next = await review.shown()
        #expect(next.request.text.contains("Ask [name] about the [private]"))
        review.answer(.send, for: next.id)
        await controller.settled()
        #expect(maker.wire.sent.count == 2)
        #expect(maker.wire.sentText.allSatisfy { !$0.contains("Sam") && !$0.contains("lemon cake") })
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
        // Refused before sending, for labels that weren't shown.
        #expect(ChatController.nothingWasSent(CloudTransportError.headersNotShown))
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

    /// A sign-in value is shown on the card but never spoken: VoiceOver
    /// says its name and how long it is.
    @Test func voiceOverNeverReadsASignInValue() throws {
        var turns = Conversation.firstRun(named: "Pip").turns
        turns.append(ChatTurn(id: UUID(), speaker: .person, text: "Plan my week"))
        let preview = try CloudModel.preview(for: turns, endpoint: endpoint, redactor: Redactor(),
                                             headers: ["X-Sample-Sign-In": "made-up"])
        #expect(CloudPreviewSheet.shownText(preview).contains("X-Sample-Sign-In: made-up"))
        let spoken = CloudPreviewSheet.spokenLines(preview).joined(separator: " ")
        #expect(spoken.contains("X-Sample-Sign-In, sign-in value, 7 characters"))
        #expect(!spoken.contains("made-up"))
        // The fixed labels say nothing secret, so they are read in full.
        #expect(spoken.contains("User-Agent, pebble"))
    }

    /// The card's text can't be selected, so a long press never puts a
    /// sign-in value on the clipboard.
    @Test func thePayloadCantBeSelectedOrCopied() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains(".textSelection(.enabled)"))
        #expect(text.contains(".textSelection(.disabled)"))
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

    /// A word half typed into the field is as private as the list. A still
    /// render can't draw a text field, so this reads the field's own code:
    /// the one place the screen types a private word is marked private and
    /// hides when the app is not in use.
    @Test func theHalfTypedWordIsPrivacySensitive() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PebbleUI/CloudHelpView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "struct PrivateWordField: View {"))
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let field = text[start.lowerBound..<end.upperBound]
        #expect(field.contains("TextField(CloudWords.privatePlaceholder, text: $word)"))
        #expect(field.contains(".privacySensitive()"))
        #expect(field.contains(".redacted(reason: privateRedaction(scenePhase))"))
        #expect(field.contains(".autocorrectionDisabled()"))
        // And it is the field the screen uses, the only one there.
        #expect(text.components(separatedBy: "TextField(").count == 2)
        #expect(text.contains("PrivateWordField(word: $help.newPrivateWord)"))
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
