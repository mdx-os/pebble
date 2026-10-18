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

    /// The setting's own words read the flag its window gives it.
    @Test func theSettingScreenReadsTheSameFlag() {
        let cloud = help()
        #expect(CloudHelpView.detail(for: cloud, place: .onDevice) == CloudWords.offDetail(.onDevice))
        #expect(CloudHelpView.detail(for: cloud, place: .mayLeaveDevice) == CloudWords.offDetail(.mayLeaveDevice))
        #expect(!Self.promises(CloudHelpView.detail(for: cloud, place: .mayLeaveDevice)))
        // With no flag given, no promise.
        #expect(CloudHelpView(help: cloud).place == .mayLeaveDevice)
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
        #expect(CloudHelpView.detail(for: cloud, place: .onDevice) == CloudWords.couldNotOpen)
        #expect(CloudWords.couldNotOpen.contains("stays off"))
        #expect(!cloud.setOn(true))
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
        let icon = try #require(body.range(of: "Image(systemName: help.usesCloudForNewChats"))
        let next = body[icon.upperBound...].prefix(300)
        #expect(next.contains(".accessibilityHidden(true)"))
    }

    // MARK: Fix round 5

    /// The home screen as the app builds it again on a redraw, with the
    /// same setting and notes.
    func rebuildHome(_ cloud: CloudHelp) -> HomeView {
        HomeView(brand: brand, model: local, names: InMemoryAgentNameStore(stored: "Pip"),
                 onboarding: InMemoryOnboardingStore(finished: true), memory: cloud.memory,
                 looks: UserDefaults(suiteName: "cloud-promise-\(UUID().uuidString)")!,
                 conversation: nil, section: .today, needsYou: NeedsYou(rule: .isolated()), cloud: cloud)
    }

    /// A cloud chat is open and the cloud is turned off. Rebuilding the
    /// home screen leaves the setting saying "Off for new chats", never
    /// the device promise, while that chat is open.
    @Test func rebuildingTheHomeScreenKeepsAnOpenCloudChatsPlace() {
        let cloud = help(CloudHelpSettings(isOn: true))
        let chat = newChat(cloud)
        cloud.setOn(false)
        // What the home screen hands its setting, through the memory screen.
        #expect(CloudHelpView.detail(for: cloud, place: surface(cloud, chat: chat))
                == CloudWords.offDetail(.mayLeaveDevice))

        _ = rebuildHome(cloud)
        _ = rebuildHome(cloud)
        let place = surface(cloud, chat: chat)
        #expect(place == .mayLeaveDevice)
        #expect(CloudHelpView.detail(for: cloud, place: place) == "Off for new chats.")
        #expect(!Self.promises(CloudHelpView.detail(for: cloud, place: place)))
    }

    /// Building the home screen struct, as every redraw does, makes no
    /// chat: no model asked for, no preview gate, no transport.
    @Test func buildingTheHomeScreenTwiceMakesNothingCloudSide() {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), maker: maker)
        _ = rebuildHome(cloud)
        _ = rebuildHome(cloud)
        #expect(cloud.chatModelsAsked == 0)
        #expect(maker.made == 0)
        // A chat started for real still asks once and makes one transport.
        _ = newChat(cloud)
        #expect(cloud.chatModelsAsked == 1)
        #expect(maker.made == 1)
    }

    #if os(macOS)
    /// The home screen is keyed on the model that runs here, and the cloud
    /// setting is not that model. So turning the cloud off and on again
    /// under a live screen makes no new screen: the open cloud chat stays,
    /// and no chat model or transport is made again. The copy still moves,
    /// through `surfacePlace`.
    @MainActor
    @Test func turningTheCloudOffAndOnKeepsTheOpenCloudChat() {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true), maker: maker)
        let host = NSHostingView(rootView: rebuildHome(cloud))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(cloud.chatModelsAsked == 1)
        cloud.setOn(false)
        host.rootView = rebuildHome(cloud)
        host.layoutSubtreeIfNeeded()
        // The cloud chat is still the one open, and no new chat was made.
        #expect(cloud.chatModelsAsked == 1)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        host.rootView = rebuildHome(cloud)
        host.layoutSubtreeIfNeeded()
        #expect(cloud.chatModelsAsked == 1, "the same screen keeps the same chat")
        #expect(maker.made == 1)
    }
    #endif

    /// The init never writes the setting's flag, and the app holds the
    /// setting without observing it, so its changes don't rebuild home.
    @Test func neitherTheHomeInitNorTheAppObservesOrWritesTheFlag() throws {
        let home = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/HomeView.swift"),
                              encoding: .utf8)
        let start = try #require(home.range(of: "package init("))
        // Through `HomeScreen`'s init too, which ends where its own
        // `newChat()` begins.
        let end = try #require(home.range(of: "private func newChat() -> ChatController {"))
        #expect(!home.contains("cloud?.place ="))
        #expect(home[start.upperBound..<end.lowerBound].contains("struct HomeScreen"))
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("@State private var cloud: CloudHelp"))
        #expect(!app.contains("@StateObject private var cloud"))
    }

    /// The Forget everything question reads the setting as it is now, and
    /// watches it, so it can't show the "notes and tasks" words while
    /// private words are kept.
    @Test func theForgetEverythingQuestionFollowsThePrivateWords() throws {
        let cloud = help()
        #expect(MemoryView.forgetEverythingDetail(for: nil) == MemoryWords.forgetEverythingDetail(background: false))
        #expect(MemoryView.forgetEverythingDetail(for: cloud) == MemoryWords.forgetEverythingDetail(background: false))
        cloud.newPrivateWord = "lemon cake"
        cloud.addPrivateWord()
        #expect(MemoryView.forgetEverythingDetail(for: cloud) == CloudWords.forgetEverythingDetail)
        // With background work, the summaries and the switch are named too,
        // with the private words or without.
        #expect(MemoryView.forgetEverythingDetail(for: cloud, background: true)
                == CloudWords.forgetEverythingWithSummariesDetail)
        #expect(MemoryView.forgetEverythingDetail(for: help(), background: true)
                == MemoryWords.forgetEverythingDetail(background: true))
        #expect(MemoryView.forgetEverythingDetail(for: nil, background: true)
                == MemoryWords.forgetEverythingDetail(background: true))
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/MemoryView.swift"),
                                encoding: .utf8)
        let dialog = try #require(source.range(of: "private struct ForgetEverythingDialog"))
        // The struct's own body, up to its closing brace at the start of a
        // line: the types inside it close indented.
        let after = source[dialog.upperBound...]
        let end = try #require(after.range(of: "\n}\n"), "ForgetEverythingDialog's closing brace")
        let watching = after[..<end.lowerBound]
        #expect(!watching.contains("\nstruct ") && !watching.contains("\nprivate struct "), "only the one struct")
        #expect(watching.contains("@ObservedObject var help: CloudHelp"))
        #expect(watching.contains("forgetEverythingDetail(for: help, background: background)"))
    }

    /// The notes folder won't open, but a words file from an earlier launch
    /// is there. Forgetting the tasks erases it too, and says so.
    @Test func theFallbackMemoryScreenErasesKeptPrivateWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try file.save(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: nil, file: { file })
        var tasksGone = false
        let erased = HomeView.forgetWithoutNotes(cloud: cloud) { tasksGone = true }
        #expect(tasksGone)
        #expect(erased == .erased)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(try file.load() == .off)
        let view = MemoryUnavailableView(hasTasks: false, forgotten: true, wordsErased: erased, erasesWords: true,
                                         onForgetTasks: {})
        #expect(view.status == CloudWords.tasksAndWordsForgotten)
        #expect(view.detail == CloudWords.forgetTasksAndWordsDetail)
        #expect(view.detail.contains("words you asked me to hide"))
    }

    /// The same, when the file said on: it is cleared, so the cloud reads
    /// as off next launch too, and the line says so rather than only that
    /// the words went.
    @Test func theFallbackMemoryScreenSaysWhenTheCloudWentOffWithTheWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try file.save(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: nil, file: { file })
        let erased = HomeView.forgetWithoutNotes(cloud: cloud) {}
        #expect(erased == .erasedWithCloud)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        let view = MemoryUnavailableView(hasTasks: false, forgotten: true, wordsErased: erased, erasesWords: true,
                                         onForgetTasks: {})
        #expect(view.status == CloudWords.tasksAndWordsAndCloudForgotten)
        #expect(CloudWords.tasksAndWordsAndCloudForgotten.contains("help from the cloud is off"))
        // The setting opened at launch, and the words could only go with
        // the whole file: the same line.
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let opened = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory())
        #expect(HomeView.forgetWithoutNotes(cloud: opened) {} == .erasedWithCloud)
    }

    /// The words file can't be reached either: the tasks still go, and the
    /// line says plainly that the words remain.
    @Test func theFallbackMemoryScreenSaysWhenTheWordsRemain() {
        struct Unreachable: Error {}
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: nil, file: { throw Unreachable() })
        var tasksGone = false
        let erased = HomeView.forgetWithoutNotes(cloud: cloud) { tasksGone = true }
        #expect(tasksGone)
        #expect(erased == .stayed)
        let view = MemoryUnavailableView(hasTasks: false, forgotten: true, underway: TaskWords.forgotUnderway(1),
                                         wordsErased: erased, erasesWords: true, onForgetTasks: {})
        #expect(view.status == CloudWords.tasksForgottenNotWords + " " + TaskWords.forgotUnderway(1))
        #expect(CloudWords.tasksForgottenNotWords.contains("couldn't erase the words"))
        // With no cloud setting, the plain words, as before.
        #expect(HomeView.forgetWithoutNotes(cloud: nil) {} == nil)
        #expect(MemoryUnavailableView(hasTasks: false, forgotten: true, onForgetTasks: {}).status
                == TaskWords.tasksForgotten)
        #expect(MemoryUnavailableView(hasTasks: true, onForgetTasks: {}).detail == TaskWords.forgetTasksDetail)
    }

    @Test func theAppLetsAnUnopenedSettingEraseItsFile() throws {
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("file: { try CloudHelpFileStore.onDevice() }"))
    }

    // MARK: Fix round 6

    /// The notes opened but the setting's file didn't, so the normal memory
    /// screen shows. Forget everything still erases the words kept in that
    /// file from an earlier launch, and only then says they went.
    @Test func forgetEverythingErasesWordsKeptInASettingThatCouldntBeOpened() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-unopened-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        let memory = scratchMemory("Sam's birthday is May 14.")
        for wasOn in [false, true] {
            try file.save(CloudHelpSettings(isOn: wasOn, privateWords: ["lemon cake"]))
            let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory, file: { file })
            #expect(cloud.settings.privateWords.isEmpty)
            let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try cloud.forgetPrivateWords() })
            model.forgetEverything()
            #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
            #expect(model.status == (wasOn ? CloudWords.forgotAndCloudOff : MemoryWords.forgotten))
        }
    }

    /// The same, but that file can't be reached or erased now: the line says
    /// the words stayed, never "Gone."
    @Test func forgetEverythingSaysWhenWordsInAnUnopenedSettingStayed() throws {
        struct Unreachable: Error {}
        let memory = scratchMemory("Sam's birthday is May 14.")
        let unreachable = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory, file: { throw Unreachable() })
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try unreachable.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == CloudWords.forgotNotesNotWords)
        #expect(memory.notes().isEmpty)

        // Reached, but the erase itself fails.
        let stuck = FailingCloudStore(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        stuck.eraseFails = true
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory, file: { stuck })
        _ = try memory.remember("Prefers tea.", source: .toldMe)
        let again = MemoryModel(store: memory, place: .onDevice, alsoForget: { try cloud.forgetPrivateWords() })
        again.forgetEverything()
        #expect(again.status == CloudWords.forgotNotesNotWords)
        #expect(try stuck.load().privateWords == ["lemon cake"])
        #expect(again.status != MemoryWords.forgotten)
    }

    /// Words that couldn't be read at launch, as on a locked device, are
    /// still named by the Forget everything question, and the button shows
    /// with no notes. Once they are read and there are none, the plain
    /// question is the true one, and the button goes with nothing to erase.
    @Test func theForgetEverythingQuestionNamesWordsThatCouldntBeRead() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        store.makeUnreadable()
        let cloud = help(store: store)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(cloud.mayHavePrivateWords)
        #expect(MemoryView.forgetEverythingDetail(for: cloud) == CloudWords.forgetEverythingDetail)

        // Unlocked: read again, and the words are there to name.
        store.makeUnreadable(false)
        cloud.refresh()
        #expect(cloud.settings.privateWords == ["lemon cake"])
        #expect(MemoryView.forgetEverythingDetail(for: cloud) == CloudWords.forgetEverythingDetail)

        // None kept, read fine: the plain words.
        let empty = help()
        #expect(!empty.mayHavePrivateWords)
        #expect(MemoryView.forgetEverythingDetail(for: empty) == MemoryWords.forgetEverythingDetail(background: false))

        // Opened, read and erased: nothing left to name.
        try cloud.forgetPrivateWords()
        #expect(!cloud.mayHavePrivateWords)

        // A setting that couldn't be opened at launch may keep words in its
        // file, so the question names them until that file is erased.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-unopened-\(UUID().uuidString)")
        let file = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        let unopened = CloudHelp.couldNotOpen(endpoint: endpoint, memory: scratchMemory(), file: { file })
        #expect(MemoryView.forgetEverythingDetail(for: unopened) == CloudWords.forgetEverythingDetail)
        try unopened.forgetPrivateWords()
        #expect(MemoryView.forgetEverythingDetail(for: unopened) == MemoryWords.forgetEverythingDetail(background: false))
        // With nothing to reach, nothing was ever kept.
        #expect(!CloudHelp.couldNotOpen(endpoint: endpoint, memory: nil).mayHavePrivateWords)

        // The screen reads the words again when it appears, and its button
        // shows whenever the question would name them.
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/MemoryView.swift"),
                                encoding: .utf8)
        #expect(source.contains(".onAppear { cloud?.refresh() }"))
        #expect(source.contains("model.hasSomethingToForget || help.mayHavePrivateWords"))
        // Which shows for the notes file, and for background work's summaries.
        #expect(source.contains("var hasSomethingToForget: Bool { hasStoredFile || hasBackgroundToForget }"))
    }

    /// The setting's changes reach the home screen through one publisher,
    /// made once, not one built again on every redraw.
    @Test func theHomeScreenHoldsTheSettingsPublisherOnce() throws {
        let home = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/HomeView.swift"),
                              encoding: .utf8)
        #expect(home.contains("@State private var cloudSettings: AnyPublisher<CloudHelpSettings, Never>"))
        #expect(!home.contains("private var cloudSettings: AnyPublisher<CloudHelpSettings, Never> {"))
    }

    /// The cloud setting's only way in is a link on the memory screen, so
    /// both places that show that screen hold it in a navigation stack.
    /// `CloudUITests` taps it in the real app on iPhone and iPad.
    @Test func theMemoryScreenSitsInANavigationStackInBothLayouts() throws {
        let home = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/HomeView.swift"),
                              encoding: .utf8)
        let sheet = try #require(home.range(of: "), onDismiss: sheetClosed) {"))
        #expect(home[sheet.upperBound...].prefix(120).contains("NavigationStack {\n                memoryScreen"))
        let split = try #require(home.range(of: "} detail: {"))
        let detail = home[split.upperBound...].prefix(600)
        #expect(detail.contains("NavigationStack {"))
        #expect(detail.contains("memoryScreen"))
    }

    // MARK: Fix round 8

    /// Two windows share one setting. Window B has a cloud chat open, the
    /// cloud goes off, and window A starts an on-device chat. A's setting
    /// may promise the device; B's still can't, whatever A did last.
    @Test func eachWindowsSettingReadsItsOwnPlace() throws {
        let cloud = help(CloudHelpSettings(isOn: true))
        let chatB = newChat(cloud)
        cloud.setOn(false)
        let chatA = newChat(cloud)
        #expect(chatA.privacyPlace == .onDevice)
        // Each window's memory screen follows its own flag, and hands it to
        // its row and setting.
        let memoryA = MemoryModel(store: scratchMemory(), place: surface(cloud, chat: chatA))
        let memoryB = MemoryModel(store: scratchMemory(), place: surface(cloud, chat: chatB))
        let rowA = CloudHelpRow(help: cloud, place: memoryA.place)
        let rowB = CloudHelpRow(help: cloud, place: memoryB.place)
        #expect(CloudHelpView.detail(for: cloud, place: rowA.place) == CloudWords.offDetail(.onDevice))
        let shownInB = CloudHelpView.detail(for: cloud, place: rowB.place)
        #expect(shownInB == "Off for new chats.")
        #expect(shownInB != "Off. Everything I do stays on this device.")
        #expect(!Self.promises(shownInB))

        // Nothing shared holds a window's place or its turn on question.
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/CloudHelpView.swift"),
                                encoding: .utf8)
        let start = try #require(source.range(of: "public final class CloudHelp: ObservableObject {"))
        let end = try #require(source.range(of: "/// The session's switch off"))
        let shared = source[start.upperBound..<end.lowerBound]
        #expect(!shared.contains("var place"))
        #expect(!shared.contains("asksToTurnOn"))
        #expect(source.contains("@State private var asksToTurnOn: Bool"))
        let memory = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/MemoryView.swift"),
                                encoding: .utf8)
        #expect(memory.contains("CloudHelpRow(help: cloud, place: model.place)"))
    }

    /// The turn on question shows only in the window whose toggle asked.
    @Test func theTurnOnQuestionIsForOneWindow() {
        let cloud = help()
        // The answer goes to the asking window's own state, and the shared
        // setting holds nothing another window could show.
        #expect(cloud.setOn(true), "this window asks")
        #expect(!cloud.settings.isOn)
        cloud.confirmTurnOn()
        #expect(cloud.settings.isOn)
        #expect(!cloud.setOn(true), "already on, nothing to ask")
    }

    /// A setting that couldn't be opened refuses private words, and its
    /// field and button are off, so nothing is typed into what would
    /// forget it.
    @Test func anUnopenedSettingRefusesPrivateWords() throws {
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: scratchMemory())
        cloud.newPrivateWord = "lemon cake"
        cloud.addPrivateWord()
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(!cloud.mayHavePrivateWords)
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/CloudHelpView.swift"),
                                encoding: .utf8)
        let card = try #require(source.range(of: "private var privateWordsCard: some View {"))
        let body = source[card.upperBound...].prefix(1_200)
        #expect(body.contains(".disabled(!help.storeOpened)"))
        let add = try #require(source.range(of: "func addPrivateWord() {"))
        #expect(source[add.upperBound...].prefix(80).contains("guard storeOpened else { return }"))
    }

    /// Forget everything on a setting that couldn't be opened clears what
    /// it shows too, so the list is empty and the status is true.
    @Test func forgettingAnUnopenedSettingClearsWhatItShows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-unopened-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudHelpFileStore(fileURL: folder.appendingPathComponent("cloud-help.json"))
        try file.save(CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory, file: { file })
        cloud.newPrivateWord = "Riverside"
        cloud.addPrivateWord()
        let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try cloud.forgetPrivateWords() })
        model.forgetEverything()
        #expect(model.status == MemoryWords.forgotten)
        #expect(cloud.settings == .off)
        #expect(cloud.settings.privateWords.isEmpty)
        #expect(cloud.newPrivateWord.isEmpty)
        #expect(!cloud.mayHavePrivateWords)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/CloudHelpView.swift"),
                                encoding: .utf8)
        let erase = try #require(source.range(of: "private func eraseUnopenedFile() throws -> Forgot {"))
        let body = source[erase.upperBound...].prefix(800)
        #expect(body.contains("try? store.erase()"))
        #expect(body.contains("settings = .off"))
    }

    /// Saved on, but this build has no address. It reads as off on the
    /// row, its symbol and the toggle, and it is saved off, so a later
    /// build with an address needs a fresh yes. The private words stay.
    @Test func aSavedOnWithNoAddressIsClearedAtLaunch() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, privateWords: ["lemon cake"]))
        let noAddress = CloudHelp(store: store, endpoint: nil, memory: scratchMemory())
        #expect(!noAddress.settings.isOn)
        #expect(!noAddress.usesCloudForNewChats)
        #expect(try store.load() == CloudHelpSettings(isOn: false, privateWords: ["lemon cake"]))
        #expect(CloudHelpView.detail(for: noAddress, place: .onDevice) == CloudWords.unavailable)

        // The next build has an address: still off, and turning on asks.
        let later = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory())
        #expect(!later.settings.isOn)
        #expect(!later.usesCloudForNewChats)
        #expect(newChat(later).privacyPlace == .onDevice)
        #expect(later.setOn(true))

        // The row, its symbol and the toggle read what new chats get.
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/CloudHelpView.swift"),
                                encoding: .utf8)
        #expect(source.contains("Binding(get: { help.usesCloudForNewChats }"))
        #expect(source.contains("systemImage: help.usesCloudForNewChats ?"))
        #expect(source.contains("Text(help.usesCloudForNewChats ? CloudWords.rowOn : CloudWords.rowOff)"))
        #expect(!source.contains("help.settings.isOn ?"))
    }

    /// The doc on `HiddenSoFar` ties erased words kept for an open chat to
    /// what the setting says about Forget everything.
    @Test func hiddenSoFarSaysWhyErasedWordsStayForAnOpenChat() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("PebbleModel/CloudModel.swift"),
                                encoding: .utf8)
        #expect(source.contains("So after Forget everything, an open cloud chat still holds the erased"))
        #expect(source.contains("`CloudWords.privateDetail`"))
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
