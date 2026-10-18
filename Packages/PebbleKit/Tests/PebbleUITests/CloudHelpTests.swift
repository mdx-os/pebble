#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// Records every request. Never touches the network.
final class FakeTransport: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [CloudRequest] = []

    var sent: [CloudRequest] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    func send(_ request: CloudRequest) async throws -> Data {
        lock.withLock { _sent.append(request) }
        return try JSONEncoder().encode(["reply": "Here's a short note."])
    }
}

/// Counts how often a transport is made, which only happens with the cloud on.
final class TransportMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    let transport = FakeTransport()

    var made: Int {
        lock.lock(); defer { lock.unlock() }
        return _made
    }

    func make() -> any CloudTransport {
        lock.lock(); _made += 1; lock.unlock()
        return transport
    }
}

@MainActor
struct CloudHelpTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!

    func help(_ settings: CloudHelpSettings = .off, endpoint: URL?, maker: TransportMaker,
              memory: MemoryStore? = nil) -> CloudHelp {
        CloudHelp(store: InMemoryCloudHelpStore(settings), endpoint: endpoint, memory: memory,
                  transport: { maker.make() })
    }

    /// Waits until the preview is on screen.
    func waitForPreview(_ review: CloudReview) async throws -> CloudPreview {
        for _ in 0..<500 {
            if let pending = review.pending { return pending }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    // MARK: Off by default

    @Test func offByDefaultMakesNoTransportAndKeepsChatsOnDevice() async throws {
        let maker = TransportMaker()
        let cloud = help(endpoint: endpoint, maker: maker)
        #expect(!cloud.settings.isOn)
        let model = cloud.chatModel(local: LocalStubModel())
        #expect(model.runsOnDevice)
        let chat = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                       conversation: nil)
        #expect(chat.conversation.onDevice)
        _ = try await chat.conversation.sending("Help me plan my morning.", with: model)
        #expect(maker.made == 0)
        #expect(maker.transport.sent.isEmpty)
        #expect(cloud.review.pending == nil)
    }

    @Test func anEmptyAddressMeansDisabledEvenIfSavedOn() {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: CloudEndpoint.url(from: ""), maker: maker)
        #expect(!cloud.isAvailable)
        #expect(cloud.chatModel(local: LocalStubModel()).runsOnDevice)
        cloud.setOn(true)
        #expect(!cloud.asksToTurnOn)
        cloud.confirmTurnOn()
        #expect(cloud.chatModel(local: LocalStubModel()).runsOnDevice)
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
        #expect(cloud.chatModel(local: LocalStubModel()).runsOnDevice)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.settings.isOn)
        #expect(!cloud.chatModel(local: LocalStubModel()).runsOnDevice)
        cloud.setOn(false)
        #expect(!cloud.settings.isOn)
        #expect(!cloud.asksToTurnOn)
    }

    @Test func theQuestionSaysWhatChanges() {
        let words = CloudWords.askPoints.joined(separator: " ")
        for promise in ["not on this device", "exactly what goes", "names", "emails", "phone numbers",
                        "addresses", "card numbers", "private words", "never leave this device",
                        "send nothing", "turn this off anytime"] {
            #expect(words.contains(promise), "missing: \(promise)")
        }
    }

    // MARK: The preview

    @Test func theSheetShowsExactlyTheBytesThatAreSent() async throws {
        let maker = TransportMaker()
        let memory = sampleMemory()
        let cloud = help(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]), endpoint: endpoint,
                         maker: maker, memory: memory)
        let model = cloud.chatModel(local: LocalStubModel())
        let chat = Conversation.firstRun(named: "Pip", onDevice: false)
        let reply = Task { try await chat.sending("Ask Sam to bring the lemon cake to 42 Maple Street.", with: model) }
        let preview = try await waitForPreview(cloud.review)
        let shown = CloudPreviewSheet.shownText(preview)
        #expect(shown.contains("Ask [name] to bring the [private] to [address]."))
        #expect(CloudPreviewSheet.hiddenLine(preview) == "Taken out: 1 private word, 1 address, 1 name.")
        #expect(maker.transport.sent.isEmpty)
        cloud.review.answer(.send)
        let next = try await reply.value
        #expect(next.turns.last?.text == "Here's a short note.")
        let sent = try #require(maker.transport.sent.first)
        #expect(maker.transport.sent.count == 1)
        #expect(sent.body == Data(shown.utf8))
        #expect(cloud.review.pending == nil)
    }

    @Test func notSendingSendsNothingAndKeepsTheWords() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = ChatController.make(brand: brand, model: cloud.chatModel(local: LocalStubModel()),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        controller.submit("Write a note to the school")
        _ = try await waitForPreview(cloud.review)
        cloud.review.answer(.cancel)
        for _ in 0..<500 where controller.isReplying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isReplying)
        #expect(controller.failure == CloudWords.notSent)
        #expect(controller.draft == "Write a note to the school")
        #expect(maker.transport.sent.isEmpty)
    }

    @Test func turningOffWhileThePreviewShowsSendsNothing() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let model = cloud.chatModel(local: LocalStubModel())
        let reply = Task { try await Conversation.firstRun(named: "Pip").sending("Plan my week", with: model) }
        _ = try await waitForPreview(cloud.review)
        cloud.setOn(false)
        await #expect(throws: CloudModelError.notSent) { try await reply.value }
        #expect(maker.transport.sent.isEmpty)
        // A later line in the same chat is not sent either.
        await #expect(throws: CloudModelError.off) {
            try await Conversation.firstRun(named: "Pip").sending("Plan my week", with: model)
        }
        #expect(maker.transport.sent.isEmpty)
    }

    @Test func stoppingAReplyClosesThePreviewAndSendsNothing() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let model = cloud.chatModel(local: LocalStubModel())
        let reply = Task { try await Conversation.firstRun(named: "Pip").sending("Plan my week", with: model) }
        _ = try await waitForPreview(cloud.review)
        reply.cancel()
        await #expect(throws: (any Error).self) { try await reply.value }
        for _ in 0..<500 where cloud.review.pending != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cloud.review.pending == nil)
        #expect(maker.transport.sent.isEmpty)
    }

    // MARK: The on-device promise and care

    @Test func anOnDeviceConversationIsNeverHandedToTheCloud() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let model = cloud.chatModel(local: LocalStubModel())
        // A chat that promised on-device is not reused with the cloud model.
        let promised = Conversation.firstRun(named: "Pip", onDevice: true)
        let controller = ChatController.make(brand: brand, model: model, names: InMemoryAgentNameStore(stored: "Pip"),
                                             conversation: promised)
        #expect(!controller.conversation.onDevice)
        #expect(controller.conversation.turns.first?.text.contains("stays") == false)
        #expect(FirstConversation.presence(controller.privacyPlace) == CloudWords.presence)
        // And sent directly, it is refused before any preview.
        await #expect(throws: ConversationError.leavesDevice) {
            try await promised.sending("Write to Sam", with: model)
        }
        #expect(cloud.review.pending == nil)
        #expect(maker.transport.sent.isEmpty)
    }

    @Test func careIsAnsweredHereWithNoPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        let controller = ChatController.make(brand: brand, model: cloud.chatModel(local: LocalStubModel()),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        controller.submit("I want to kill myself")
        for _ in 0..<500 where controller.isReplying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.conversation.turns.last?.text == CareCheck.reply)
        #expect(cloud.review.pending == nil)
        #expect(maker.transport.sent.isEmpty)
    }

    @Test func theOnDeviceHeaderStaysForOnDeviceChats() {
        let controller = ChatController.make(brand: brand, model: LocalStubModel(),
                                             names: InMemoryAgentNameStore(stored: "Pip"), conversation: nil)
        #expect(FirstConversation.presence(controller.privacyPlace) == FirstConversation.presence(.onDevice))
    }

    /// Today and the memory follow this, so their device lines drop the
    /// moment the cloud is on, and come back when it is off.
    @Test func thePlaceFollowsTheSettingTheSameWayTheModelDoes() {
        let maker = TransportMaker()
        let off = help(endpoint: endpoint, maker: maker)
        #expect(off.place(local: .onDevice) == .onDevice)
        #expect(off.place(local: .mayLeaveDevice) == .mayLeaveDevice)
        #expect(off.place(local: .onDevice, with: CloudHelpSettings(isOn: true)) == .mayLeaveDevice)
        let on = help(CloudHelpSettings(isOn: true), endpoint: endpoint, maker: maker)
        #expect(on.place(local: .onDevice) == .mayLeaveDevice)
        #expect(on.chatModel(local: LocalStubModel()).privacyPlace == .mayLeaveDevice)
        // With no address the setting can't take effect, so nothing changes.
        let nowhere = help(CloudHelpSettings(isOn: true), endpoint: nil, maker: maker)
        #expect(nowhere.place(local: .onDevice) == .onDevice)
        #expect(nowhere.chatModel(local: LocalStubModel()).privacyPlace == .onDevice)
    }

    /// The memory screen's saved line follows a place that changes while it is open.
    @Test func theMemorysDeviceLinesFollowAChangedPlace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        defer { try? store.forgetEverything() }
        let model = MemoryModel(store: store, place: .onDevice)
        model.newNote = "Tea in the afternoon"
        model.add()
        #expect(model.status == MemoryWords.saved(.onDevice))
        model.place = .mayLeaveDevice
        model.newNote = "Sam likes lemon cake"
        model.add()
        #expect(model.status == MemoryWords.saved(.mayLeaveDevice))
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
            AnyView(CloudHelpView(help: cloud, local: .onDevice)),
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

    private func sampleMemory() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-test-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        _ = try? store.remember("Sam's birthday is May 14.", source: .toldMe)
        return store
    }
}
#endif
