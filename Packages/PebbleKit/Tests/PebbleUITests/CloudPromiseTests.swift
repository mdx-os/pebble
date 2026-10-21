#if canImport(SwiftUI)
import Foundation
import PebbleCore
import PebbleModel
import SwiftUI
import Testing
@testable import PebbleUI

/// With the cloud on, the device promise is false everywhere, read from one
/// flag, `PrivacyPlace` from the model (docs/VOICE.md). Also the shared
/// send path and `HomeCover` with a cloud chat, a yes that holds only for
/// its address, Forget everything ending every open cloud chat, and each
/// window's setting speaking only for itself.
@MainActor
struct CloudPromiseTests {
    let brand = Brand(name: "Nova")
    let endpoint = URL(string: "https://cloud.example.com")!
    let local = LocalStubModel()
    private let scratch = ScratchFiles()

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
            FirstRunWords.helloDetail(surface),
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
        #expect(ModelChoice.privacyPlace(settings: CloudHelpSettings(isOn: true, for: endpoint), endpoint: endpoint, local: local)
                == .mayLeaveDevice)
        #expect(ModelChoice.privacyPlace(settings: .off, endpoint: endpoint, local: local) == .onDevice)
        #expect(ModelChoice.privacyPlace(settings: CloudHelpSettings(isOn: true, for: endpoint), endpoint: nil, local: local)
                == .onDevice)
    }

    @Test func aLineReadByTwoChatsPromisesOnlyWhatBothKeep() {
        #expect(PrivacyPlace.all(.onDevice, .onDevice) == .onDevice)
        #expect(PrivacyPlace.all(.onDevice, .mayLeaveDevice) == .mayLeaveDevice)
        #expect(PrivacyPlace.all(.mayLeaveDevice, .onDevice) == .mayLeaveDevice)
        #expect(PrivacyPlace.all(.onDevice) == .onDevice)
        #expect(PrivacyPlace.all(.mayLeaveDevice) == .mayLeaveDevice)
        // `PrivacyPlace.all()` with no place does not compile, and
        // `everyPlaceIsAPrivacyPlace` flags it if the signature loosens.
    }

    /// The cloud model says its place two ways: the static one its own
    /// words read, and the one every model reports from `runsOnDevice`.
    /// They are one answer.
    @Test func theCloudModelsTwoPlacesAgree() {
        let model = CloudModel(endpoint: endpoint, transport: RefusingTransport(), reviewer: CloudReview())
        #expect(model.privacyPlace == CloudModel.place)
        #expect(CloudModel.place == .mayLeaveDevice)
        #expect((model as any ModelClient).privacyPlace == CloudModel.place)
    }

    // MARK: With the cloud on, no line promises the device

    /// A chat started with the cloud on shows no device promise anywhere:
    /// the chat header, the opening, memory's empty, saved and header
    /// lines, Today's sample note, the hello and the cloud setting.
    @Test func withTheCloudOnEveryDeviceLineDropsThePromise() {
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
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
        let cloud = CloudHelp(store: InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint)), endpoint: nil,
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
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
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
        let chat = newChat(help(CloudHelpSettings(isOn: true, for: endpoint), maker: maker,
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
        let chat = newChat(help(CloudHelpSettings(isOn: true, for: endpoint), maker: maker))
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
        let chat = newChat(help(CloudHelpSettings(isOn: true, for: endpoint), maker: maker))
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

    // MARK: Turning on reaches nothing

    /// The yes to the turn on question sends nothing and makes no
    /// transport, even with a sign-in the cloud needs: that goes only as a
    /// hop in a preview (`CloudHelpTests` and `CloudModelTests` drive it).
    @Test func theYesToTurningOnReachesNoNetwork() {
        let maker = TransportMaker()
        let auth = CountingAuth(needsSignIn: true)
        let cloud = help(maker: maker, auth: auth)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        #expect(cloud.usesCloudForNewChats)
        #expect(maker.made == 0)
        #expect(maker.wire.sent.isEmpty)
        #expect(auth.signIns == 0)
        cloud.setOn(false)
        #expect(maker.made == 0)
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

    /// The app makes its setting with `CloudHelp.forApp`, which falls back
    /// to the setting that couldn't be opened, never to one kept only in
    /// memory.
    @Test func theAppFallsBackToTheUnopenedSetting() throws {
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("CloudHelp.forApp("))
        #expect(!app.contains("InMemoryCloudHelpStore"))
        let fallback = CloudHelp.forApp(memory: scratchMemory(), endpoint: endpoint,
                                        openStore: { throw MemoryStore.Unavailable() })
        #expect(!fallback.storeOpened)
        #expect(!fallback.isAvailable)
        #expect(CloudHelp.forApp(memory: nil, endpoint: endpoint, openStore: { InMemoryCloudHelpStore() }).storeOpened
                == false, "without notes the setting isn't opened either")
    }

    // MARK: Sends, previews and the add button

    @Test func aCancelledReplyCountsAsNothingSent() {
        #expect(ChatController.nothingWasSent(CancellationError()))
        #expect(!ChatController.nothingWasSent(URLError(.cancelled)))
        #expect(!ChatController.nothingWasSent(URLError(.timedOut)))
    }

    /// Each transport refusal comes before anything is handed over, so
    /// each is named as nothing sent; a bad answer after the bytes left is
    /// not.
    @Test func eachTransportRefusalCountsAsNothingSent() {
        for refused in [CloudTransportError.headersNotShown, .notSecure, .reservedHeader("Host"), .signInPathRefused("../x"),
                        .signInBodyRefused, .signInHeaderRefused("X Token"), .signInCarriesPersonalDetails] {
            #expect(ChatController.nothingWasSent(refused), "\(refused)")
        }
        #expect(!ChatController.nothingWasSent(URLError(.badServerResponse)))
        #expect(!ChatController.nothingWasSent(CloudModelError.unreadableReply))
    }

    @Test func thePreviewSaysWhatItIsWithoutOverclaiming() {
        #expect(CloudWords.previewDetail.hasPrefix("This shows where your message goes"))
        #expect(!CloudWords.previewDetail.contains("everything I send"))
        #expect(CloudWords.previewDetail.contains("Earlier messages in this chat go again with each new one."))
    }

    /// A preview waiting for a yes was hidden with the private words as
    /// they were, so changing them withdraws it and nothing goes.
    @Test func changingThePrivateWordsWithdrawsAWaitingPreview() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker)
        let chat = newChat(cloud)
        let review = try #require(chat.review)

        chat.submit("Ask about the Riverside Clinic")
        _ = await review.shown()
        cloud.newPrivateWord = "Riverside Clinic"
        cloud.addPrivateWord()
        #expect(review.pending == nil)
        await chat.settled()
        #expect(chat.failure == CloudWords.withdrawn)
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

    // MARK: Rebuilding the home screen

    /// The home screen as the app builds it again on a redraw, with the
    /// same setting, notes and looks. `reportsPlace` hears each place it
    /// works out.
    func rebuildHome(_ cloud: CloudHelp, looks: UserDefaults,
                     reportsPlace: (@MainActor (PrivacyPlace) -> Void)? = nil) -> HomeView {
        HomeView(brand: brand, model: local, names: InMemoryAgentNameStore(stored: "Pip"),
                 onboarding: InMemoryOnboardingStore(finished: true), memory: cloud.memory,
                 looks: looks,
                 conversation: nil, section: .today, needsYou: NeedsYou(rule: .isolated()), cloud: cloud,
                 reportsPlace: reportsPlace)
    }

    /// A cloud chat is open and the cloud is turned off. Rebuilding the
    /// home screen leaves the setting saying "Off for new chats", never
    /// the device promise, while that chat is open.
    @Test func rebuildingTheHomeScreenKeepsAnOpenCloudChatsPlace() throws {
        let suite = "cloud-promise-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
        let chat = newChat(cloud)
        cloud.setOn(false)
        // What the home screen hands its setting, through the memory screen.
        #expect(CloudHelpView.detail(for: cloud, place: surface(cloud, chat: chat))
                == CloudWords.offDetail(.mayLeaveDevice))

        _ = rebuildHome(cloud, looks: looks)
        _ = rebuildHome(cloud, looks: looks)
        let place = surface(cloud, chat: chat)
        #expect(place == .mayLeaveDevice)
        #expect(CloudHelpView.detail(for: cloud, place: place) == "Off for new chats.")
        #expect(!Self.promises(CloudHelpView.detail(for: cloud, place: place)))
    }

    #if os(macOS)
    /// Lets SwiftUI finish the passes a change set off.
    func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A live home screen has a cloud chat open, and the cloud is turned
    /// off. However often the app rebuilds it, the place it works out, and
    /// so its setting's words, never promise the device while that chat is
    /// open: "Off for new chats".
    @Test(.tags(.realWindow)) func aLiveHomeScreenKeepsAnOpenCloudChatsPlaceThroughRebuilds() throws {
        let suite = "cloud-promise-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
        let heard = PlacesHeard()
        let host = NSHostingView(rootView: rebuildHome(cloud, looks: looks) { heard.places.append($0) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)
        #expect(heard.places.last == .mayLeaveDevice)
        cloud.setOn(false)
        settle(host)
        for _ in 0..<2 {
            host.rootView = rebuildHome(cloud, looks: looks) { heard.places.append($0) }
            settle(host)
        }
        let place = try #require(heard.places.last)
        #expect(place == .mayLeaveDevice)
        #expect(CloudHelpView.detail(for: cloud, place: place) == "Off for new chats.")
        #expect(!Self.promises(CloudHelpView.detail(for: cloud, place: place)))
        // Starting a fresh chat on the device is what brings the promise back.
        #expect(surface(cloud, chat: newChat(cloud)) == .onDevice)
    }
    #endif

    /// Building the home screen struct, as every redraw does, makes no
    /// chat: no model asked for, no preview gate, no transport.
    @Test func buildingTheHomeScreenTwiceMakesNothingCloudSide() throws {
        let suite = "cloud-promise-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), maker: maker)
        _ = rebuildHome(cloud, looks: looks)
        _ = rebuildHome(cloud, looks: looks)
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
    @Test func turningTheCloudOffAndOnKeepsTheOpenCloudChat() throws {
        let suite = "cloud-promise-\(UUID().uuidString)"
        let looks = try #require(UserDefaults(suiteName: suite))
        defer { looks.removePersistentDomain(forName: suite) }
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint), maker: maker)
        let host = NSHostingView(rootView: rebuildHome(cloud, looks: looks))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(cloud.chatModelsAsked == 1)
        cloud.setOn(false)
        host.rootView = rebuildHome(cloud, looks: looks)
        host.layoutSubtreeIfNeeded()
        // The cloud chat is still the one open, and no new chat was made.
        #expect(cloud.chatModelsAsked == 1)
        cloud.setOn(true)
        cloud.confirmTurnOn()
        host.rootView = rebuildHome(cloud, looks: looks)
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
        let auth = CountingAuth()
        let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: nil, auth: auth, file: { file })
        var tasksGone = false
        let erased = HomeView.forgetWithoutNotes(cloud: cloud) { tasksGone = true }
        #expect(tasksGone)
        #expect(erased == .erased)
        // Sign-in is told to forget here too, whatever it kept before.
        #expect(auth.forgets == 1)
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
        try file.save(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
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
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let auth = CountingAuth()
        let opened = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory(), auth: auth)
        #expect(HomeView.forgetWithoutNotes(cloud: opened) {} == .erasedWithCloud)
        #expect(auth.forgets == 1)
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

    /// The setting the app falls back to can still erase the file it would
    /// have read, the real one on the device in the app.
    @Test func theAppLetsAnUnopenedSettingEraseItsFile() throws {
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("openStore: { try CloudHelpFileStore.onDevice() }"))
        // The notes didn't open, so the setting isn't opened at launch.
        let file = InMemoryCloudHelpStore(CloudHelpSettings(privateWords: ["lemon cake"]))
        let auth = CountingAuth()
        let fallback = CloudHelp.forApp(memory: nil, endpoint: endpoint, auth: auth, openStore: { file })
        #expect(!fallback.storeOpened)
        #expect(fallback.eraseWordsWithoutNotes() == .erased)
        #expect(try file.load().privateWords.isEmpty)
        // The app's sign-in reaches the fallback, so it forgets there too.
        #expect(auth.forgets == 1)
        // And through the setting that opened.
        let openedAuth = CountingAuth()
        let opened = CloudHelp.forApp(memory: scratchMemory(), endpoint: endpoint, auth: openedAuth,
                                      openStore: { InMemoryCloudHelpStore() })
        #expect(opened.storeOpened)
        try opened.forgetPrivateWords()
        #expect(openedAuth.forgets == 1)
    }

    // MARK: A setting that couldn't be opened

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
            let auth = CountingAuth()
            let cloud = CloudHelp.couldNotOpen(endpoint: endpoint, memory: memory, auth: auth, file: { file })
            #expect(cloud.settings.privateWords.isEmpty)
            let model = MemoryModel(store: memory, place: .onDevice, alsoForget: { try cloud.forgetPrivateWords() })
            model.forgetEverything()
            #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
            #expect(model.status == (wasOn ? CloudWords.forgotAndCloudOff : MemoryWords.forgotten))
            #expect(auth.forgets == 1)
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
        #expect(source.contains("hasNotes: model.hasSomethingToForget, mayHaveWords: help.mayHavePrivateWords"))
        #expect(MemoryView.showsForgetEverything(hasNotes: false, mayHaveWords: true, holdsMore: false))
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

    // MARK: More than one window

    /// Two windows share one setting. Window B has a cloud chat open, the
    /// cloud goes off, and window A starts an on-device chat. A's setting
    /// may promise the device; B's still can't, whatever A did last.
    @Test func eachWindowsSettingReadsItsOwnPlace() throws {
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
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
        // The turn on question is each window's own: see
        // `theTurnOnQuestionIsForOneWindow`, which drives two.
        let memory = try String(contentsOf: Self.sources.appendingPathComponent("PebbleUI/MemoryView.swift"),
                                encoding: .utf8)
        #expect(memory.contains("CloudHelpRow(help: cloud, place: model.place)"))
    }

    #if os(macOS)
    /// Two windows show the one setting. Switching the toggle on in one
    /// opens the turn on question in that window only, and nothing is on
    /// until the yes.
    @Test(.tags(.realWindow)) func theTurnOnQuestionIsForOneWindow() throws {
        let cloud = help()
        let frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        let asking = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        asking.isReleasedWhenClosed = false
        defer { asking.close() }
        let other = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        for shown in [asking, other] {
            shown.contentView = NSHostingView(rootView: CloudHelpView(help: cloud, place: .onDevice))
            shown.orderFront(nil)
        }
        for shown in [asking, other] { settle(try #require(shown.contentView)) }
        let content = try #require(asking.contentView)
        let toggles = Self.switches(in: content)
        #expect(toggles.count == 1)
        let toggle = try #require(toggles.first, "no toggle drawn")
        #expect(toggle.state == .off)
        toggle.performClick(nil)
        for shown in [asking, other] { settle(try #require(shown.contentView)) }
        #expect(asking.attachedSheet != nil, "the question opens where the toggle was switched")
        #expect(other.attachedSheet == nil, "and nowhere else")
        #expect(!cloud.settings.isOn)
        #expect(!cloud.usesCloudForNewChats)
    }

    /// Every switch AppKit drew under `view`: the setting's toggle.
    static func switches(in view: NSView) -> [NSSwitch] {
        ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap { switches(in: $0) }
    }
    #endif

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
    }

    /// Saved on, but this build has no address. It reads as off on the
    /// row, its symbol and the toggle, and it is saved off, so a later
    /// build with an address needs a fresh yes. The private words stay.
    @Test func aSavedOnWithNoAddressIsClearedAtLaunch() throws {
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
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

    // MARK: A yes holds for one address

    /// A yes given for another address, or saved with none, reads as off,
    /// is saved off, and turning on asks again for this address.
    @Test func aSavedYesHoldsOnlyForTheAddressItWasGivenFor() throws {
        let other = try #require(URL(string: "https://other.example.com"))
        for saved in [CloudHelpSettings(isOn: true, for: other, privateWords: ["lemon cake"]),
                      CloudHelpSettings(isOn: true, privateWords: ["lemon cake"])] {
            let store = InMemoryCloudHelpStore(saved)
            let cloud = help(store: store)
            #expect(!cloud.usesCloudForNewChats)
            #expect(newChat(cloud).privacyPlace == .onDevice)
            #expect(try store.load() == CloudHelpSettings(privateWords: ["lemon cake"]))
            #expect(cloud.setOn(true), "a fresh yes is asked for")
            cloud.confirmTurnOn()
            #expect(try store.load().consentedEndpoint == endpoint.absoluteString)
            #expect(newChat(cloud).privacyPlace == .mayLeaveDevice)
        }
    }

    /// A chat model reads the saved yes fresh for each send, against its
    /// own address, so a file changed to another address sends nothing.
    @Test func aChatSendsNothingOnceTheYesIsForAnotherAddress() async throws {
        let maker = TransportMaker()
        let store = InMemoryCloudHelpStore(CloudHelpSettings(isOn: true, for: endpoint))
        let chat = newChat(help(maker: maker, store: store))
        try store.save(CloudHelpSettings(isOn: true, for: try #require(URL(string: "https://other.example.com"))))
        chat.submit("Plan my week")
        // A preview shown here would wait forever for an answer.
        #expect(await finishes { await chat.settled() }, "a preview was shown")
        chat.stopReplying()
        #expect(chat.failure == CloudWords.turnedOff)
        #expect(chat.review?.pending == nil)
        #expect(maker.wire.sent.isEmpty)
    }

    /// The file from a build that needs a fresh yes can't be saved off at
    /// launch. Nothing is erased: the private words are kept and still
    /// hidden, every send is held off, the file is marked off, and the
    /// person is told. Opening the setting tries the save again.
    @Test func aStaleYesThatCantBeSavedOffKeepsTheWordsAndSaysSo() throws {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        store.savesToFail = .max
        let noAddress = CloudHelp(store: store, endpoint: nil, memory: scratchMemory())
        #expect(store.saved == CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        #expect(noAddress.settings == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(noAddress.mayHavePrivateWords)
        #expect(noAddress.holdsSendsOff)
        #expect(noAddress.status == CloudWords.offSavedLater)
        #expect(store.markedOff)
        // Counted, as every line is, so the setting speaks it when shown.
        #expect(noAddress.statusCount == 1)
        // Marked off, it holds; nothing needs the home screen.
        #expect(noAddress.launchNotice == nil)
        // Not even marked off: the home screen says so, since the person
        // did nothing that would bring them to the setting.
        let unmarked = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]))
        unmarked.savesToFail = .max
        unmarked.markFails = true
        let unsaved = CloudHelp(store: unmarked, endpoint: nil, memory: scratchMemory())
        #expect(unsaved.status == CloudWords.offAtLaunchNotSaved)
        #expect(unsaved.statusCount == 1)
        #expect(unsaved.launchNotice == CloudWords.offAtLaunchNotSaved)
        // Plain words: what it couldn't save, and where it tries again,
        // named, since the line is read on Today and not in the setting.
        #expect(CloudWords.offAtLaunchNotSaved
                == "Help from the cloud is off. I couldn't save that it's off, so I'll try again when you open the cloud setting.")
        #expect(!CloudWords.offAtLaunchNotSaved.contains("this setting"))
        // Saving works again: the setting saves off, keeps the words, and
        // the home screen's line goes with the setting's.
        unmarked.savesToFail = 0
        unsaved.refresh()
        #expect(unmarked.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(unsaved.status == nil)
        #expect(unsaved.launchNotice == nil)
        store.savesToFail = 0
        noAddress.refresh()
        #expect(store.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(noAddress.status == nil)
        let later = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory())
        #expect(!later.usesCloudForNewChats)
        #expect(later.settings.privateWords == ["lemon cake"])
        #expect(later.setOn(true))
    }

    /// Not saved off at launch: every send is held off for the whole
    /// session, whatever the file says, until the person says yes again.
    /// A chat started after the file says yes for this very address shows
    /// no preview and sends nothing.
    @Test func aStaleYesThatCantBeSavedOffHoldsEverySendOff() async throws {
        let other = try #require(URL(string: "https://other.example.com"))
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: other))
        store.savesToFail = .max
        store.markFails = true
        let maker = TransportMaker()
        let cloud = help(maker: maker, store: store)
        #expect(cloud.holdsSendsOff)
        #expect(!cloud.usesCloudForNewChats)
        #expect(store.saved?.isOn == true)
        // The file says yes for this address now, and still can't be saved.
        store.savesToFail = 0
        try store.save(CloudHelpSettings(isOn: true, for: endpoint))
        store.savesToFail = .max
        cloud.refresh()
        #expect(!cloud.usesCloudForNewChats)
        let chat = newChat(cloud)
        chat.submit("Plan my week")
        // A preview shown here would wait forever for an answer.
        #expect(await finishes { await chat.settled() }, "a preview was shown")
        #expect(chat.review?.pending == nil)
        chat.stopReplying()
        #expect(maker.wire.sent.isEmpty)
        // Once saving works, the hold is saved.
        store.savesToFail = 0
        cloud.refresh()
        #expect(store.saved?.isOn == false, "the hold is saved once saving works")
        #expect(!cloud.usesCloudForNewChats)
        #expect(maker.wire.sent.isEmpty)
    }

    /// A yes for this address, then a launch with no address while the
    /// device is locked, so the file can't be read. Once it is unlocked the
    /// yes is saved off, as launch would have, and the next build with the
    /// address is off until a new yes. When that save fails at unlock the
    /// sends are held off, the file is marked off and the person is told,
    /// and the next refresh saves it.
    @Test func aYesSavedOffAfterALockedLaunchStaysOffForItsAddress() throws {
        let saved = CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"])
        let store = FailingCloudStore(saved)
        store.loadFails = .locked
        let locked = CloudHelp(store: store, endpoint: nil, memory: scratchMemory())
        #expect(store.saved == saved)
        store.loadFails = nil
        locked.refresh()
        #expect(store.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(!locked.usesCloudForNewChats)
        let later = CloudHelp(store: store, endpoint: endpoint, memory: scratchMemory())
        #expect(!later.usesCloudForNewChats)
        #expect(newChat(later).privacyPlace == .onDevice)
        #expect(later.setOn(true), "a new yes is asked for")
        later.confirmTurnOn()
        #expect(later.usesCloudForNewChats)

        let stuck = FailingCloudStore(saved)
        stuck.loadFails = .locked
        let unlocked = CloudHelp(store: stuck, endpoint: nil, memory: scratchMemory())
        stuck.loadFails = nil
        stuck.savesToFail = .max
        unlocked.refresh()
        #expect(unlocked.holdsSendsOff)
        #expect(stuck.markedOff)
        #expect(unlocked.status == CloudWords.offSavedLater)
        #expect(unlocked.statusCount == 1)
        unlocked.refresh()
        #expect(unlocked.statusCount == 1, "said once, not at every refresh")
        #expect(!CloudHelp(store: stuck, endpoint: endpoint, memory: scratchMemory()).usesCloudForNewChats)
        stuck.savesToFail = 0
        unlocked.refresh()
        #expect(stuck.saved == CloudHelpSettings(privateWords: ["lemon cake"]))
        #expect(unlocked.status == nil)
        #expect(!CloudHelp(store: stuck, endpoint: endpoint, memory: scratchMemory()).usesCloudForNewChats)

        // Not even marked off: the home screen says so, once, however
        // often it is refreshed.
        let unmarked = FailingCloudStore(saved)
        unmarked.loadFails = .locked
        let bare = CloudHelp(store: unmarked, endpoint: nil, memory: scratchMemory())
        unmarked.loadFails = nil
        unmarked.savesToFail = .max
        unmarked.markFails = true
        bare.refresh()
        #expect(bare.holdsSendsOff)
        #expect(bare.launchNotice == CloudWords.offAtLaunchNotSaved)
        #expect(bare.statusCount == 1)
        bare.refresh()
        #expect(bare.statusCount == 1)
        #expect(bare.launchNotice == CloudWords.offAtLaunchNotSaved)
    }

    /// The app's state, made the way the app makes it, keeps the notes
    /// store with no cloud address, as every shipped build has, whether the
    /// setting opens or not.
    @Test func theAppKeepsItsNotesWithNoCloudAddress() throws {
        let memory = scratchMemory("Sam's birthday is May 14.")
        let opened = CloudHelp.forApp(memory: memory, endpoint: nil, openStore: { InMemoryCloudHelpStore() })
        #expect(opened.memory === memory)
        #expect(opened.storeOpened)
        #expect(opened.memory?.notes().map(\.text) == ["Sam's birthday is May 14."])
        let unopened = CloudHelp.forApp(memory: memory, endpoint: nil, openStore: { throw MemoryStore.Unavailable() })
        #expect(unopened.memory === memory)
        #expect(!unopened.storeOpened)
        let app = try String(contentsOf: Self.repo.appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        #expect(app.contains("CloudHelp.forApp("))
        #expect(app.contains("private var memory: MemoryStore? { cloud.memory }"))
    }

    // MARK: Forget everything ends every open cloud chat

    /// A cloud chat's reply is on the wire when the person asks to forget
    /// everything. Before anything is said, the reply and its send are
    /// cancelled, the chat lets go of its turns and of every word it hid,
    /// and the home screen holds a fresh chat. Something went out this
    /// session, so the line says that copy can't be erased from here.
    @Test func forgetEverythingFirstEndsEveryOpenCloudChat() async throws {
        let maker = TransportMaker(hangs: true)
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker,
                         memory: memory)
        let slot = HomeView.chatSlot(newChat(cloud), brand: brand, model: local,
                                     names: InMemoryAgentNameStore(stored: "Pip"), cloud: cloud)
        let chat = try #require(slot.chat)
        let session = try #require(chat.cloudSession)
        let review = try #require(chat.review)
        chat.submit("Ask Sam about the lemon cake")
        review.answer(.send, for: await review.shown().id)
        #expect(await finishes { await maker.wire.started() }, "nothing reached the wire")
        #expect(maker.wire.sent.count == 1)
        #expect(session.hiddenSoFar.privateWords == ["lemon cake"])

        let model = HomeView.memoryModel(store: memory, place: .mayLeaveDevice, cloud: cloud)
        model.forgetEverything()

        #expect(chat.hasEnded)
        #expect(!chat.isReplying)
        #expect(!chat.conversation.turns.contains { $0.speaker == .person })
        #expect(session.hasEnded)
        #expect(session.hiddenSoFar == Redactor())
        #expect(session.sendsOnTheWire == 0)
        let fresh = try #require(slot.chat)
        #expect(fresh !== chat)
        #expect(!fresh.conversation.turns.contains { $0.speaker == .person })
        #expect(model.status == CloudWords.forgotAfterSending + " " + CloudWords.sentCantBeErased)
        #expect(model.status?.contains("I no longer have it") == false)
        #expect(await finishes { await maker.wire.whenCancelled() }, "the send on the wire was never cancelled")
        #expect(maker.wire.cancelled)
        #expect(maker.wire.sent.count == 1)
        // Whatever happened above, nothing is left waiting on the wire.
        chat.stopReplying()
    }

    /// Two cloud chats are open: the one the home screen holds, and one it
    /// doesn't, as another window's would be. Forget everything ends both,
    /// and both let go of every word they hid.
    @Test func forgetEverythingEndsEveryOpenCloudChatNotOnlyTheHeldOne() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker,
                         memory: memory)
        let slot = HomeView.chatSlot(newChat(cloud), brand: brand, model: local,
                                     names: InMemoryAgentNameStore(stored: "Pip"), cloud: cloud)
        let held = try #require(slot.chat)
        let other = newChat(cloud)
        for chat in [held, other] {
            let review = try #require(chat.review)
            chat.submit("Ask Sam about the lemon cake")
            review.answer(.send, for: await review.shown().id)
            await chat.settled()
        }
        let sessions = try [held, other].map { try #require($0.cloudSession) }
        #expect(sessions[0] !== sessions[1])
        for session in sessions { #expect(session.hiddenSoFar.privateWords == ["lemon cake"]) }
        #expect(maker.wire.sent.count == 2)

        HomeView.memoryModel(store: memory, place: .mayLeaveDevice, cloud: cloud).forgetEverything()

        for (chat, session) in zip([held, other], sessions) {
            #expect(chat.hasEnded)
            #expect(!chat.conversation.turns.contains { $0.speaker == .person })
            #expect(session.hasEnded)
            #expect(session.hiddenSoFar == Redactor())
        }
        #expect(slot.chat !== held)
        #expect(maker.wire.sent.count == 2)
    }

    /// A private word typed into another window's composer and never sent
    /// goes with Forget everything too, though that chat holds nothing
    /// else. Left there, it would outlive the erased list, and its next
    /// preview would no longer hide it. A chat with nothing typed is left
    /// open.
    @Test func forgetEverythingClearsAnUnsentDraftInAnotherOpenChat() throws {
        let maker = TransportMaker()
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker,
                         memory: memory)
        let slot = HomeView.chatSlot(newChat(cloud), brand: brand, model: local,
                                     names: InMemoryAgentNameStore(stored: "Pip"), cloud: cloud)
        let held = try #require(slot.chat)
        let other = newChat(cloud)
        other.draft = "Bring the lemon cake on Friday"

        HomeView.memoryModel(store: memory, place: .mayLeaveDevice, cloud: cloud).forgetEverything()

        #expect(cloud.settings.privateWords.isEmpty)
        #expect(other.hasEnded)
        #expect(other.draft.isEmpty)
        #expect(!held.hasEnded)
        #expect(slot.chat === held)
        #expect(maker.wire.sent.isEmpty)
    }

    /// The home screen's launch line draws only while there is one to say.
    @Test func theLaunchLineShowsOnTheHomeScreenOnlyWhileItHolds() throws {
        let unmarked = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        unmarked.savesToFail = .max
        unmarked.markFails = true
        let stuck = CloudHelp(store: unmarked, endpoint: nil, memory: scratchMemory())
        /// How many bytes of the picture differ from the plain backdrop it
        /// is drawn on, so a notice that draws nothing counts none.
        func drawn(_ cloud: CloudHelp) -> Int {
            let renderer = ImageRenderer(content: CloudLaunchNotice(help: cloud)
                .frame(width: 390, height: 200).background(Color.black))
            renderer.scale = 1
            guard let image = renderer.cgImage, let data = image.dataProvider?.data as Data? else { return -1 }
            let step = image.bitsPerPixel / 8
            let backdrop = data.prefix(step)
            return stride(from: 0, to: data.count - step + 1, by: step)
                .filter { data[$0..<$0 + step] != backdrop }.count
        }
        #expect(drawn(help()) == 0)
        #expect(drawn(stuck) > 1_000)
        // Saved off once saving works, the line goes, and the next launch
        // has nothing to say.
        unmarked.savesToFail = 0
        stuck.refresh()
        #expect(stuck.launchNotice == nil)
        #expect(drawn(CloudHelp(store: unmarked, endpoint: nil, memory: scratchMemory())) == 0)
    }

    /// The launch line is announced once a launch, not each time Today
    /// comes back to the front, and VoiceOver reads it as one element
    /// whose label is the line. With no line there is nothing to announce.
    @Test func theLaunchLineIsAnnouncedOnceAsOneElement() throws {
        let unmarked = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        unmarked.savesToFail = .max
        unmarked.markFails = true
        let stuck = CloudHelp(store: unmarked, endpoint: nil, memory: scratchMemory())
        #expect(stuck.launchNotice == CloudWords.offAtLaunchNotSaved)
        #expect(stuck.claimLaunchAnnouncement())
        #expect(!stuck.claimLaunchAnnouncement())
        #expect(!stuck.claimLaunchAnnouncement())
        #expect(!help().claimLaunchAnnouncement())
        // A still render can't be asked what VoiceOver hears, so this
        // reads the notice's own code: one element, labelled with the
        // line, announced only when the claim says so.
        let source = try String(contentsOf: Self.repo.appendingPathComponent(
            "Packages/PebbleKit/Sources/PebbleUI/CloudHelpView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "struct CloudLaunchNotice: View {"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let notice = source[start.lowerBound..<end.upperBound]
        #expect(notice.contains(".accessibilityElement(children: .ignore)"))
        #expect(notice.contains(".accessibilityLabel(line)"))
        #expect(notice.contains("if help.claimLaunchAnnouncement() { AccessibilityNotification.Announcement(line).post() }"))
        #expect(notice.components(separatedBy: "AccessibilityNotification.Announcement(").count == 2,
                "announced only behind the claim")
    }

    /// With nothing handed to the cloud this session, an open cloud chat
    /// still ends, and the line is the plain one.
    @Test func forgetEverythingWithNothingSentEndsTheChatAndSaysGone() async throws {
        let maker = TransportMaker()
        let memory = scratchMemory("Sam's birthday is May 14.")
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker,
                         memory: memory)
        let slot = HomeView.chatSlot(newChat(cloud), brand: brand, model: local,
                                     names: InMemoryAgentNameStore(stored: "Pip"), cloud: cloud)
        let chat = try #require(slot.chat)
        let review = try #require(chat.review)
        chat.submit("Ask Sam about the lemon cake")
        _ = await review.shown()
        let model = HomeView.memoryModel(store: memory, place: .mayLeaveDevice, cloud: cloud)
        model.forgetEverything()
        await chat.settled()
        #expect(chat.hasEnded)
        #expect(review.pending == nil)
        #expect(slot.chat !== chat)
        #expect(!cloud.anythingSentThisSession)
        #expect(model.status == MemoryWords.forgotten)
        #expect(maker.wire.sent.isEmpty)
    }

    /// Ending a chat clears its draft, which Today's composer shares and
    /// which may hold a word being erased. The reply it cut short puts
    /// nothing back: no words in the draft and no failure line.
    @Test func endingAChatClearsTheDraftAndTheCutReplyPutsNothingBack() async throws {
        let maker = TransportMaker()
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint, privateWords: ["lemon cake"]), maker: maker)
        let chat = newChat(cloud)
        let review = try #require(chat.review)
        chat.submit("Ask about the lemon cake")
        _ = await review.shown()
        let reply = try #require(chat.replyTask)
        chat.draft = "lemon cake for Saturday"
        chat.end()
        await reply.value
        #expect(chat.draft.isEmpty)
        #expect(chat.failure == nil)
        #expect(!chat.conversation.turns.contains { $0.speaker == .person })
        #expect(maker.wire.sent.isEmpty)
    }

    /// A chat the home screen no longer holds, ended later, never takes
    /// the place of the one it does hold now.
    @Test func onlyTheHeldChatIsReplacedWhenItEnds() throws {
        let cloud = help(CloudHelpSettings(isOn: true, for: endpoint))
        let old = newChat(cloud)
        let slot = HomeView.chatSlot(old, brand: brand, model: local, names: InMemoryAgentNameStore(stored: "Pip"),
                                     cloud: cloud)
        let current = newChat(cloud)
        slot.chat = current
        old.end()
        #expect(slot.chat === current)
    }

    // MARK: The preview keeps the screen under it

    #if os(macOS)
    /// A chat changing between the device and the cloud swaps whether there
    /// is a preview to watch. The screen under it keeps its identity, so
    /// state such as the memory screen's "Saved." survives.
    @Test func theScreenUnderThePreviewKeepsItsStateWhenTheChatChanges() {
        let births = Births()
        let host = NSHostingView(rootView: PreviewProbe(births: births, review: nil))
        settle(host)
        #expect(births.count == 1)
        host.rootView = PreviewProbe(births: births, review: CloudReview())
        settle(host)
        host.rootView = PreviewProbe(births: births, review: nil)
        settle(host)
        #expect(births.count == 1, "the screen under the preview was made again")
    }
    #endif

    // MARK: Spoken once

    /// One setting serves every window, so a status line is spoken only in
    /// the window whose action it answers.
    @Test func aStatusLineIsSpokenOnlyInTheWindowThatActed() {
        let store = FailingCloudStore(.off)
        store.savesToFail = .max
        let cloud = help(store: store)
        let one = UUID(), two = UUID()
        cloud.newPrivateWord = "Sam"
        cloud.act(as: one) { $0.addPrivateWord() }
        #expect(cloud.status == CloudWords.privateNotSaved)
        #expect(CloudHelpView.speaks(cloud.statusWindow, in: one))
        #expect(!CloudHelpView.speaks(cloud.statusWindow, in: two))
        cloud.act(as: two) { $0.addPrivateWord() }
        #expect(CloudHelpView.speaks(cloud.statusWindow, in: two))
        #expect(!CloudHelpView.speaks(cloud.statusWindow, in: one))
    }

    /// A line no window asked for, such as a switch off from somewhere
    /// else, is never pinned to the window that acted last: every window
    /// showing the setting speaks it.
    @Test func aStatusLineNoWindowAskedForIsSpokenInEveryWindow() {
        let store = FailingCloudStore(CloudHelpSettings(isOn: true, for: endpoint))
        let cloud = help(store: store)
        let one = UUID(), two = UUID()
        store.savesToFail = .max
        store.eraseFails = true
        cloud.newPrivateWord = "Sam"
        cloud.act(as: one) { $0.addPrivateWord() }
        #expect(cloud.speaker == nil, "the speaker is cleared once the window has acted")
        cloud.turnOff()
        #expect(cloud.status == CloudWords.offSavedLater)
        #expect(cloud.statusWindow == nil)
        #expect(CloudHelpView.speaks(cloud.statusWindow, in: one))
        #expect(CloudHelpView.speaks(cloud.statusWindow, in: two))
    }

    // MARK: Helpers

    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let sources = repo.appendingPathComponent("Packages/PebbleKit/Sources")

    private func scratchMemory(_ notes: String...) -> MemoryStore {
        let url = scratch.add(FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-promise-\(UUID().uuidString).json"))
        let store = MemoryStore(fileURL: url)
        for note in notes { _ = try? store.remember(note, source: .toldMe) }
        return store
    }
}

/// Every place a hosted home screen reported.
extension Tag {
    /// Puts a real window on screen, so it needs a window server: a Mac
    /// runner with no display can skip these by this tag.
    @Tag static var realWindow: Self
}

@MainActor
final class PlacesHeard {
    var places: [PrivacyPlace] = []
}

/// How many times a screen under the preview was made.
@MainActor
final class Births {
    var count = 0
}

/// Counts itself once for each time the screen holding it is made.
@MainActor
final class Birth: ObservableObject {
    init(_ births: Births) { births.count += 1 }
}

/// A screen with state of its own, under the cloud preview.
struct PreviewProbe: View {
    let births: Births
    let review: CloudReview?

    var body: some View {
        Survivor(births: births).cloudPreview(review)
    }

    struct Survivor: View {
        @StateObject private var birth: Birth

        init(births: Births) {
            _birth = StateObject(wrappedValue: Birth(births))
        }

        var body: some View { Text("Today") }
    }
}
#endif
