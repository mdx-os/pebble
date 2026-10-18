#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// A sign-in that waits until it is cancelled, and says whether it was.
/// It never touches the network; the wait is a sleep that cancellation
/// cuts short, so nothing here rests on timing.
final class WaitingSignIn: CloudAuth, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled = false
    private var _finished = false

    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var finished: Bool { lock.withLock { _finished } }

    func headers(for url: URL) -> [String: String] { [:] }

    func signIn() async {
        lock.withLock { _started = true }
        do {
            try await Task.sleep(for: .seconds(3_600))
            lock.withLock { _finished = true }
        } catch {
            lock.withLock { _cancelled = true }
        }
    }
}

/// Mandeep's decision, item 11: with the cloud on, the device promise is
/// false everywhere, read from one flag, `PrivacyPlace` from the model.
/// Plus the merge with main's shared send path and `HomeCover`, and the
/// last review round's shoulds and nits.
@MainActor
struct CloudPromiseTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!
    let local = LocalStubModel()

    func help(_ settings: CloudHelpSettings = .off, maker: TransportMaker = TransportMaker(),
              memory: MemoryStore? = nil, store: (any CloudHelpStoring)? = nil,
              auth: any CloudAuth = NoCloudAuth()) -> CloudHelp {
        CloudHelp(store: store ?? InMemoryCloudHelpStore(settings), endpoint: endpoint,
                  memory: memory ?? scratchMemory(), auth: auth, transport: { maker.make() })
    }

    /// A new chat made the way the home screen makes one.
    func newChat(_ cloud: CloudHelp?) -> ChatController {
        HomeView.newChat(brand: brand, model: local, names: InMemoryAgentNameStore(stored: "Pip"),
                         cloud: cloud, conversation: nil)
    }

    /// The flag every line outside the chat reads, as the home screen
    /// works it out with `chat` open.
    func surface(_ cloud: CloudHelp?, chat: ChatController?) -> PrivacyPlace {
        HomeView.surfacePlace(chat: chat?.privacyPlace, newChat: cloud?.privacyPlace(local: local) ?? local.privacyPlace)
    }

    /// Every device line the screens show, each read the way its screen
    /// reads it: the chat's own lines from the chat, the rest from the
    /// surface flag.
    func shownDeviceLines(chat: ChatController, surface: PrivacyPlace) -> [String] {
        [
            FirstConversation.presence(chat.privacyPlace),
            chat.conversation.turns.first?.text ?? "",
            MemoryWords.empty(surface),
            MemoryWords.saved(surface),
            MemoryWords.privacyNote(surface),
            FeedWords.sampleNote(surface),
            FirstRunWords.helloDetail(onDevice: surface.staysOnDevice),
            CloudWords.offDetail(surface),
        ]
    }

    static func promises(_ line: String) -> Bool {
        line.contains("this device") || line.contains("stays here") || line.contains("stays on")
    }

    // MARK: One flag, from the model

    @Test func theCloudModelSaysItIsNotOnTheDevice() {
        let model = CloudModel(endpoint: endpoint, transport: RefusingTransport(), reviewer: CloudReview())
        #expect(!model.runsOnDevice)
        #expect(model.privacyPlace == .mayLeaveDevice)
        #expect(CloudModel.place == .mayLeaveDevice)
        // Picked without making a model, it reads the same.
        #expect(ModelChoice.privacyPlace(settings: CloudHelpSettings(isOn: true), endpoint: endpoint, local: local)
                == .mayLeaveDevice)
        #expect(ModelChoice.privacyPlace(settings: .off, endpoint: endpoint, local: local) == .onDevice)
        #expect(ModelChoice.privacyPlace(settings: CloudHelpSettings(isOn: true), endpoint: nil, local: local)
                == .onDevice)
    }

    @Test func aLineReadByTwoChatsPromisesOnlyWhatBothKeep() {
        #expect(PrivacyPlace.all(.onDevice, .onDevice) == .onDevice)
        #expect(PrivacyPlace.all(.onDevice, .mayLeaveDevice) == .mayLeaveDevice)
        #expect(PrivacyPlace.all(.mayLeaveDevice, .onDevice) == .mayLeaveDevice)
        #expect(PrivacyPlace.all() == .onDevice)
    }

    // MARK: Item 11

    /// A chat started with the cloud on shows no device promise anywhere:
    /// the chat header, the opening, memory's empty, saved and header
    /// lines, Today's sample note, the hello and the cloud setting.
    @Test func withTheCloudOnEveryDeviceLineDropsThePromise() {
        let cloud = help(CloudHelpSettings(isOn: true))
        let chat = newChat(cloud)
        #expect(chat.privacyPlace == .mayLeaveDevice)
        #expect(chat.review != nil)
        let surface = surface(cloud, chat: chat)
        #expect(surface == .mayLeaveDevice)
        for line in shownDeviceLines(chat: chat, surface: surface) {
            #expect(!Self.promises(line), "device promise in: \(line)")
        }
    }

    @Test func withTheCloudOffEveryDeviceLineKeepsThePromise() {
        for cloud in [help(), nil] as [CloudHelp?] {
            let chat = newChat(cloud)
            #expect(chat.privacyPlace == .onDevice)
            #expect(chat.review == nil)
            let surface = surface(cloud, chat: chat)
            #expect(surface == .onDevice)
            for line in shownDeviceLines(chat: chat, surface: surface) {
                #expect(Self.promises(line), "no device promise in: \(line)")
            }
        }
    }

    /// No address means no cloud, even with the setting saved on, so the
    /// promise stays.
    @Test func withNoAddressThePromiseStays() {
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true)), endpoint: nil,
                              memory: scratchMemory())
        let chat = newChat(cloud)
        #expect(surface(cloud, chat: chat) == .onDevice)
        #expect(Self.promises(FirstConversation.presence(chat.privacyPlace)))
    }

    /// The chat that was open before the cloud was turned on keeps its own
    /// promise, which stays true: it never sends. Every line outside it
    /// drops the promise at once, since the next chat would use the cloud.
    @Test func anOnDeviceChatStartedBeforeTurningTheCloudOnKeepsItsPromiseAndNeverSends() async throws {
        let maker = TransportMaker()
        let cloud = help(maker: maker)
        let chat = newChat(cloud)
        #expect(chat.privacyPlace == .onDevice)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.usesCloudForNewChats)

        #expect(chat.privacyPlace == .onDevice)
        #expect(chat.review == nil)
        #expect(Self.promises(FirstConversation.presence(chat.privacyPlace)))
        #expect(chat.conversation.turns.first?.text.contains("so what you tell me stays here") == true)
        #expect(surface(cloud, chat: chat) == .mayLeaveDevice)

        chat.submit("Text Sam at 416 555 0199 about Saturday")
        await chat.settled()
        #expect(chat.conversation.turns.last?.speaker == .agent)
        #expect(chat.failure == nil)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)

        // The next new chat is the cloud one, and promises nothing.
        let next = newChat(cloud)
        #expect(next.privacyPlace == .mayLeaveDevice)
        #expect(!Self.promises(next.conversation.turns.first?.text ?? ""))
    }

    /// Turning the cloud off with a cloud chat still open: that chat's
    /// words already left, so the lines outside it still make no promise
    /// until a new chat starts on the device.
    @Test func turningOffWithACloudChatOpenPromisesOnlyOnceANewChatStarts() {
        let cloud = help(CloudHelpSettings(isOn: true))
        let chat = newChat(cloud)
        cloud.setOn(false)
        #expect(surface(cloud, chat: chat) == .mayLeaveDevice)
        #expect(CloudWords.offDetail(surface(cloud, chat: chat)) == "Off for new chats.")
        let fresh = newChat(cloud)
        #expect(surface(cloud, chat: fresh) == .onDevice)
        #expect(Self.promises(CloudWords.offDetail(surface(cloud, chat: fresh))))
    }

    /// The setting's own words read the flag the home screen gives it.
    @Test func theSettingScreenReadsTheSameFlag() {
        let cloud = help()
        cloud.place = .onDevice
        #expect(CloudHelpView.detail(for: cloud) == CloudWords.offDetail(.onDevice))
        cloud.place = .mayLeaveDevice
        #expect(CloudHelpView.detail(for: cloud) == CloudWords.offDetail(.mayLeaveDevice))
        #expect(!Self.promises(CloudHelpView.detail(for: cloud)))
    }

    /// The memory screen's copy of the flag follows it while it is open,
    /// and a "Saved" line already showing is said again truthfully.
    @Test func aSavedLineOnScreenFollowsTheFlag() {
        let model = MemoryModel(store: scratchMemory(), place: .onDevice)
        model.newNote = "Sam's birthday is May 14."
        model.add()
        #expect(model.status == MemoryWords.saved(.onDevice))
        model.place = .mayLeaveDevice
        #expect(model.status == "Saved.")
        model.newNote = "Prefers tea"
        model.add()
        #expect(model.status == "Saved.")
    }

    // MARK: The shared send path and HomeCover

    /// A line sent from Today's composer in a cloud chat goes through the
    /// same preview as one typed in the chat. Not sending it puts it back,
    /// and Today shows the line that says so.
    @Test func aSendFromTodayInACloudChatIsPreviewedFirst() async throws {
        let maker = TransportMaker()
        let chat = newChat(help(CloudHelpSettings(isOn: true), maker: maker,
                                memory: scratchMemory("Lunch with Sam's sister on Friday.")))
        let review = try #require(chat.review)
        #expect(HomeView.sendsFromToday("Remind Sam about Friday", chat: chat))
        let preview = await review.shown()
        #expect(preview.request.text.contains("Remind [name] about Friday"))
        #expect(maker.wire.sent.isEmpty)
        review.answer(.cancel, for: preview.id)
        await chat.settled()
        #expect(maker.wire.sent.isEmpty)
        #expect(chat.draft == "Remind Sam about Friday")
        #expect(!chat.conversation.turns.contains { $0.text == "Remind Sam about Friday" })
        let today = TodayComposer(chat: chat, inFront: true) { _ in }
        #expect(today.failure == CloudWords.notSent)
    }

    @Test func aSendFromTodayThatIsApprovedGoesOnce() async throws {
        let maker = TransportMaker()
        let chat = newChat(help(CloudHelpSettings(isOn: true), maker: maker))
        let review = try #require(chat.review)
        HomeView.sendsFromToday("Plan my week", chat: chat)
        let preview = await review.shown()
        review.answer(.send, for: preview.id)
        await chat.settled()
        #expect(maker.wire.sent.count == 1)
        #expect(maker.wire.sent.first?.httpBody == preview.request.body)
        #expect(chat.conversation.turns.last?.text == "Here's a short note.")
    }

    /// A preview waiting for its answer covers the home screen like any
    /// sheet: the chat stays quiet, Command Return can't send from behind
    /// it, and it waits for its answer like a question.
    @Test func aWaitingPreviewCoversTheHomeScreen() {
        for usesSidebar in [true, false] {
            for section in [HomeSection.today, .chat] {
                let open = HomeCover(usesSidebar: usesSidebar, section: section, showsShortcuts: false,
                                     readerOpen: false, questionOpen: false, previewOpen: true)
                #expect(open.chatIsCovered)
                #expect(!open.chatSendsFromKeyboard)
                #expect(!open.todayInFront)
                #expect(open.waitsForAnAnswer)
                #expect(!open.anySheetOpen, "it is not a sheet the handoff closes")
                let shut = HomeCover(usesSidebar: usesSidebar, section: section, showsShortcuts: false,
                                     readerOpen: false, questionOpen: false)
                #expect(!shut.previewOpen)
                #expect(!shut.waitsForAnAnswer)
                #expect(shut.chatSendsFromKeyboard)
            }
        }
    }

    /// A preview held back by another sheet is not shown, and not cancelled.
    @Test func aPreviewWaitsForAnotherSheetWithoutBeingCancelled() async throws {
        let maker = TransportMaker()
        let chat = newChat(help(CloudHelpSettings(isOn: true), maker: maker))
        let review = try #require(chat.review)
        chat.submit("Plan my week")
        let preview = await review.shown()
        #expect(CloudPreviewPresenter.shown(review.pending, blocked: true) == nil)
        #expect(review.pending == preview)
        #expect(CloudPreviewPresenter.shown(review.pending, blocked: false) == preview)
        review.answer(.cancel, for: preview.id)
        await chat.settled()
        #expect(maker.wire.sent.isEmpty)
    }

    // MARK: The last review round: shoulds

    @Test func turningOffCancelsASignInUnderWay() async throws {
        let auth = WaitingSignIn()
        let cloud = help(auth: auth)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        let signingIn = try #require(cloud.signingIn)
        while !auth.started { await Task.yield() }
        cloud.setOn(false)
        await signingIn.value
        #expect(auth.cancelled)
        #expect(!auth.finished)
        #expect(cloud.signingIn == nil)
    }

    @Test func forgetEverythingThatClearsTheSettingCancelsASignInUnderWay() async throws {
        let auth = WaitingSignIn()
        let store = FailingCloudStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let cloud = help(store: store, auth: auth)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        let signingIn = try #require(cloud.signingIn)
        while !auth.started { await Task.yield() }
        store.savesToFail = .max
        #expect(try cloud.forgetPrivateWords() == .privateWordsAndCloud)
        await signingIn.value
        #expect(auth.cancelled)
        #expect(!auth.finished)
    }

    /// A Forget everything that only clears the words leaves sign-in alone,
    /// since the cloud is still on.
    @Test func forgettingOnlyTheWordsLeavesSignInAlone() async throws {
        let auth = WaitingSignIn()
        let cloud = help(CloudHelpSettings(privateWords: ["lemon cake"]), auth: auth)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        let signingIn = try #require(cloud.signingIn)
        while !auth.started { await Task.yield() }
        #expect(try cloud.forgetPrivateWords() == .privateWords)
        #expect(cloud.signingIn != nil)
        signingIn.cancel()
        await signingIn.value
    }

    @Test func signInDocumentsCancellation() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleModel/CloudModel.swift"),
                                encoding: .utf8)
        #expect(source.contains("It runs in a task that is cancelled when the person turns the cloud"))
        #expect(source.contains("check for cancellation"))
    }

    /// The setting's file couldn't be opened: it reads as off, can't be
    /// turned on, says so plainly, and every chat stays on the device.
    @Test func aSettingThatCantBeOpenedReadsAsUnavailableAndSaysWhy() {
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: scratchMemory())
        #expect(!cloud.storeOpened)
        #expect(!cloud.isAvailable)
        #expect(!cloud.settings.isOn)
        #expect(CloudHelpView.detail(for: cloud) == CloudWords.couldNotOpen)
        #expect(CloudWords.couldNotOpen.contains("stays off"))
        cloud.setOn(true)
        #expect(!cloud.asksToTurnOn)
        cloud.confirmTurnOn()
        #expect(!cloud.usesCloudForNewChats)
        #expect(cloud.privacyPlace(local: local) == .onDevice)
        #expect(newChat(cloud).privacyPlace == .onDevice)
    }

    @Test func theAppFallsBackToTheUnopenedSetting() throws {
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("CloudHelp.couldNotOpen("))
        #expect(!app.contains("InMemoryCloudHelpStore"))
    }

    // MARK: The last review round: nits

    @Test func aCancelledReplyCountsAsNothingSent() {
        #expect(ChatController.nothingWasSent(CancellationError()))
        #expect(!ChatController.nothingWasSent(URLError(.cancelled)))
        #expect(!ChatController.nothingWasSent(URLError(.timedOut)))
    }

    @Test func thePreviewSaysWhatItIsWithoutOverclaiming() {
        #expect(CloudWords.previewDetail.hasPrefix("This is the whole request for this message"))
        #expect(!CloudWords.previewDetail.contains("everything I send"))
        #expect(CloudWords.previewDetail.contains("Earlier messages in this chat go again with each new one."))
    }

    /// A preview waiting for a yes was hidden with the private words as
    /// they were, so changing them withdraws it and nothing goes.
    @Test func changingThePrivateWordsWithdrawsAWaitingPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]), maker: maker)
        let chat = newChat(cloud)
        let review = try #require(chat.review)

        chat.submit("Ask about the Riverside Clinic")
        _ = await review.shown()
        cloud.newPrivateWord = "Riverside Clinic"
        cloud.addPrivateWord()
        #expect(review.pending == nil)
        await chat.settled()
        #expect(chat.failure == CloudWords.notSent)
        #expect(chat.draft == "Ask about the Riverside Clinic")

        chat.submit(chat.draft)
        let again = await review.shown()
        #expect(again.request.text.contains("Ask about the [private]"))
        cloud.removePrivateWord("lemon cake")
        #expect(review.pending == nil)
        await chat.settled()
        #expect(maker.wire.sent.isEmpty)
    }

    @Test func theAddButtonOnlyAddsWords() {
        #expect(!CloudHelpView.canAdd(""))
        #expect(!CloudHelpView.canAdd("   \n"))
        #expect(CloudHelpView.canAdd("Sam"))
    }

    /// Before anything is typed the add button looks as it is: off.
    @Test(arguments: [ColorScheme.light, .dark])
    func theAddButtonLooksDimmedUntilThereAreWords(scheme: ColorScheme) throws {
        func pixels(enabled: Bool) throws -> Data {
            let renderer = ImageRenderer(content: AddPrivateWordButton(size: 44) {}
                .disabled(!enabled)
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try #require(image.dataProvider?.data as Data?)
        }
        #expect(try pixels(enabled: true) != pixels(enabled: false))
    }

    @Test func theCloudRowIconIsHiddenFromVoiceOver() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/CloudHelpView.swift"),
                                encoding: .utf8)
        let row = try #require(source.range(of: "struct CloudHelpRow"))
        let end = try #require(source.range(of: "struct CloudTurnOnSheet"))
        let body = source[row.upperBound..<end.lowerBound]
        let icon = try #require(body.range(of: "Image(systemName: help.settings.isOn"))
        let next = body[icon.upperBound...].prefix(300)
        #expect(next.contains(".accessibilityHidden(true)"))
    }

    // MARK: Helpers

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let sources = repo.appendingPathComponent("Packages/PebbleKit/Sources")

    private func scratchMemory(_ notes: String...) -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-promise-\(UUID().uuidString).json")
        let store = MemoryStore(fileURL: url)
        for note in notes { _ = try? store.remember(note, source: .toldMe) }
        return store
    }
}
#endif
