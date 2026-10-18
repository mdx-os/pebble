import Combine
import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// The app's root: the guided first run until it's finished, then Today,
/// with the chat one tap away and a way to see what the agent remembers.
///
/// On a wide window (an iPad in full screen or a wide Split View) Today,
/// the chat and the memory sit in a sidebar, with Today chosen first. On a
/// narrow one (iPhone, Slide Over, a narrow Split View) Today is home, the
/// chat opens on top of it, and the memory opens over either. The
/// conversation and the feed are kept here, so changing the window's shape
/// never loses them.
///
/// The screen is keyed on the model it is given, the one that runs here:
/// another model starts it fresh, so no word keeps promising the device
/// after words may leave it, or the other way round. The cloud setting is
/// not part of that key. Turning it on or off never makes a new screen, so
/// an open cloud chat stays open; instead the screen works out where words
/// go (`surfacePlace`) and pushes each change into Today and the memory.
public struct HomeView: View {
    let screen: HomeScreen

    /// `feed` is where finished work comes from. Questions come only from
    /// `needsYou` and `tasks`, which both ask through `AskFirst`. `tasks`
    /// shows long work on live cards. Without one, looking into something
    /// plays on the scripted engine with the sample sources, labelled as
    /// examples.
    public init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults = .standard,
        feed: [any FeedSource] = [EmptyFeedSource()],
        needsYou: NeedsYou = NeedsYou(),
        tasks: (any TaskEngine)? = nil,
        cloud: CloudHelp? = nil
    ) {
        self.init(brand: brand, model: model, names: names, onboarding: onboarding, memory: memory,
                  looks: looks, conversation: nil, section: .today, feed: feed, needsYou: needsYou, tasks: tasks,
                  cloud: cloud)
    }

    /// Opens on a given conversation, section and feed, for screenshots and tests.
    package init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults,
        conversation: Conversation?,
        section: HomeSection,
        feed: [any FeedSource] = [EmptyFeedSource()],
        // No default: screenshots and tests pass their own rule, so they
        // never touch the app's `AskFirst.shared`.
        needsYou: NeedsYou,
        tasks: (any TaskEngine)? = nil,
        drivesTasks: Bool = false,
        sources: any SourceProvider = SampleSources(),
        now: @escaping () -> Date = { Date() },
        cloud: CloudHelp? = nil
    ) {
        screen = HomeScreen(brand: brand, model: model, names: names, onboarding: onboarding, memory: memory,
                            looks: looks, conversation: conversation, section: section, feed: feed,
                            needsYou: needsYou, tasks: tasks, drivesTasks: drivesTasks, sources: sources,
                            now: now, cloud: cloud, chatLine: nil)
    }

    #if DEBUG
    /// The same, with `chatLine` said in the chat as it opens, for the
    /// showcase's screenshots of what follows. Only the showcase can say a
    /// line the person didn't type, and only in a debug build.
    init(brand: Brand, model: any ModelClient, names: any AgentNameStoring, onboarding: any OnboardingStoring,
         memory: MemoryStore?, looks: UserDefaults, conversation: Conversation?, section: HomeSection,
         feed: [any FeedSource], needsYou: NeedsYou, now: @escaping () -> Date, chatLine: String) {
        screen = HomeScreen(brand: brand, model: model, names: names, onboarding: onboarding, memory: memory,
                            looks: looks, conversation: conversation, section: section, feed: feed,
                            needsYou: needsYou, tasks: nil, drivesTasks: false, sources: SampleSources(),
                            now: now, cloud: nil, chatLine: chatLine)
    }
    #endif

    /// Which model the screen was made for: its kind and where its words
    /// go. Either changing makes a new screen.
    struct ModelIdentity: Hashable {
        let kind: ObjectIdentifier
        let staysOnDevice: Bool
    }

    static func identity(of model: any ModelClient) -> ModelIdentity {
        ModelIdentity(kind: ObjectIdentifier(type(of: model)), staysOnDevice: model.privacyPlace.staysOnDevice)
    }

    public var body: some View {
        // Load-bearing: the screen's state objects keep the model they were
        // made with, so only a new identity can change it. The cloud model
        // a chat may get is not here: it is picked per chat, and the places
        // that read it follow `surfacePlace` instead.
        screen.id(Self.identity(of: screen.model))
    }

    /// Today's model, which takes its privacy place from the active model,
    /// so the example note never promises the device when words may leave.
    static func feedModel(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)? = nil,
                          drivesTasks: Bool = false, model: any ModelClient,
                          now: @escaping () -> Date) -> FeedModel {
        feedModel(sources: sources, needsYou: needsYou, tasks: tasks, drivesTasks: drivesTasks,
                  place: model.privacyPlace, now: now)
    }

    /// The same, from a place already worked out, as the home screen does
    /// with the cloud setting in it. `memory` is where Remember this saves.
    static func feedModel(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)? = nil,
                          drivesTasks: Bool = false, place: PrivacyPlace, memory: MemoryStore? = nil,
                          now: @escaping () -> Date) -> FeedModel {
        FeedModel(sources: sources, needsYou: needsYou, tasks: tasks, drivesTasks: drivesTasks,
                  place: place, memory: memory, now: now)
    }

    /// The memory screen's model, with its privacy place from the active
    /// model, the same way. Forget everything forgets the tasks too.
    static func memoryModel(store: MemoryStore, model: any ModelClient,
                            onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) -> MemoryModel {
        memoryModel(store: store, place: model.privacyPlace, onForgetEverything: onForgetEverything)
    }

    /// The same, from a place already worked out. With `cloud`, Forget
    /// everything erases the words always hidden too.
    static func memoryModel(store: MemoryStore, place: PrivacyPlace, cloud: CloudHelp? = nil,
                            onForgetEverything: @escaping @MainActor () -> ClearedTasks = { .none }) -> MemoryModel {
        MemoryModel(store: store, place: place, alsoForget: MemoryView.alsoForget(cloud),
                    onForgetEverything: onForgetEverything)
    }

    /// Today's model as the home screen makes it, with looking into things
    /// in it. Every task, a recon's included, runs through one runner. With
    /// no engine given, the scripted one plays in real time over `reading`.
    static func reconFeedModel(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)?,
                               drivesTasks: Bool, reading: any SourceProvider, place: PrivacyPlace,
                               memory: MemoryStore?, model: any ModelClient, cloud: CloudHelp?,
                               now: @escaping () -> Date) -> FeedModel {
        let engine = tasks ?? LocalFakeEngine(rule: needsYou.rule)
        let runner = (engine as? ReconRunner) ?? ReconRunner(engine: engine, provider: reading)
        let feed = feedModel(sources: sources, needsYou: needsYou, tasks: runner,
                             drivesTasks: drivesTasks || tasks == nil, place: place, memory: memory, now: now)
        // Asked at each start, so turning the cloud on or off counts from
        // the next one, as it does for chats. A summary put together in the
        // cloud asks through Today's own preview gate.
        let review = feed.cloudReview
        feed.summarizer = { ReconSummarizers.choose(for: cloud?.chatModel(local: model, review: review) ?? model) }
        return feed
    }

    /// Lets a chat offer to look into something. It starts only on the person's tap.
    /// An on-device chat's recon stays on this device, whatever the cloud
    /// setting is when the person taps.
    static func wired(_ chat: ChatController, to feed: FeedModel) -> ChatController {
        chat.lookInto = { [weak feed] topic, onDevice in feed?.lookInto(topic, onDevice: onDevice) ?? false }
        chat.reconReadsExamples = feed.readsExamples
        return chat
    }

    /// What Today's `onTalk` does to the chat, apart from moving, so tests
    /// can drive it: the line goes in the composer, ready, and nothing is
    /// sent. Words the person already typed are never replaced.
    static func draft(_ line: String, in chat: ChatController) {
        if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chat.draft = line }
    }

    /// The send itself, apart from moving, so tests can drive it.
    @discardableResult
    static func sendsFromToday(_ line: String, chat: ChatController) -> Bool {
        chat.send(line)
    }

    /// A new chat with the model the setting picks now. A chat keeps the
    /// model it started with, so its opening line stays true; changing the
    /// cloud setting counts from the next new chat. A cloud chat gets its
    /// own preview gate, shown over the home screen that holds it.
    static func newChat(brand: Brand, model: any ModelClient, names: any AgentNameStoring, cloud: CloudHelp?,
                        conversation: Conversation?) -> ChatController {
        let review = CloudReview()
        let chatModel = cloud?.chatModel(local: model, review: review) ?? model
        return ChatController.make(brand: brand, model: chatModel, names: names, conversation: conversation,
                                   review: chatModel.privacyPlace.staysOnDevice ? nil : review)
    }

    /// The flag every device line outside a chat reads: memory, Today's
    /// sample note, the hello and the cloud setting. On the device only
    /// when both the open chat and the next new one are, so with the cloud
    /// on it never promises the device. The chat's own lines read
    /// `ChatController.privacyPlace` alone. See `PrivacyPlace`.
    static func surfacePlace(chat: PrivacyPlace?, newChat: PrivacyPlace) -> PrivacyPlace {
        PrivacyPlace.all(chat ?? newChat, newChat)
    }

    /// The fallback memory screen's forget, apart from the screen, so tests
    /// can drive it: every task, then the private words, each whatever
    /// happens to the other.
    static func forgetWithoutNotes(cloud: CloudHelp?, forgetTasks: () -> Void) -> CloudHelp.WordsErased? {
        forgetTasks()
        return cloud?.eraseWordsWithoutNotes()
    }
}

/// The home screen itself, for one model. See `HomeView`.
struct HomeScreen: View {
    let brand: Brand
    let model: any ModelClient
    let names: any AgentNameStoring
    let onboarding: any OnboardingStoring
    let memory: MemoryStore?
    let looks: UserDefaults
    /// The cloud setting. Nil, or off, means every chat stays on this device.
    let cloud: CloudHelp?

    @State private var finished: Bool
    @State private var firstMessage: String?
    /// The open chat. Kept in a `StateObject` so it is made once, the first
    /// time the home screen shows, and never by a rebuild of this struct.
    @StateObject private var chats: ChatSlot
    @State private var section: HomeSection?
    /// On a narrow screen, whether the memory was opened from the chat, so
    /// closing it goes back there rather than to Today.
    @State private var memoryOverChat = false
    @State private var showsShortcuts = false
    @State private var asksNewChat = false
    /// What to do once the open sheet has finished closing.
    @State private var handoff = SheetHandoff()
    /// The `privacyPlace` of the model a new chat would get now, kept in
    /// step with the cloud setting.
    @State private var newChatPlace: PrivacyPlace
    /// A cloud chat's preview is waiting for its answer, on screen or held
    /// back until another sheet closes. It covers the home screen.
    @State private var previewWaiting = false
    /// The same for Today's preview, of a summary put together in the cloud.
    @State private var todayPreviewWaiting = false
    /// True when Today's preview came first, so it shows and the chat's
    /// waits; otherwise the chat's goes first. Only one sheet shows at a time.
    @State private var todayPreviewFirst = false
    /// What the fallback memory screen did with the private words when
    /// the tasks went. Nil until it has tried.
    @State private var wordsErased: CloudHelp.WordsErased?
    /// Every change to the cloud setting, as it is about to be set. Made
    /// once, so a redraw never subscribes again.
    @State private var cloudSettings: AnyPublisher<CloudHelpSettings, Never>
    @StateObject private var feed: FeedModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults,
        conversation: Conversation?,
        section: HomeSection,
        feed: [any FeedSource],
        needsYou: NeedsYou,
        tasks: (any TaskEngine)?,
        drivesTasks: Bool,
        sources: any SourceProvider,
        now: @escaping () -> Date,
        cloud: CloudHelp?,
        chatLine: String?
    ) {
        self.brand = brand
        self.model = model
        self.names = names
        self.onboarding = onboarding
        self.memory = memory
        self.looks = looks
        self.cloud = cloud
        // One store for the notes: the redactor must read the same notes
        // the memory screen writes.
        assert(cloud.map { $0.memory === memory } ?? true, "Pass the same MemoryStore to CloudHelp and HomeView")
        let needed = OnboardingFlow.isNeeded(store: onboarding, names: names)
        // People who named their agent before the first run existed count as finished.
        if !needed, !onboarding.hasFinished() { onboarding.markFinished() }
        _finished = State(initialValue: !needed)
        let newChatPlace = cloud?.privacyPlace(local: model) ?? model.privacyPlace
        _newChatPlace = State(initialValue: newChatPlace)
        // A chat made now gets the model the setting picks now, so this is
        // its place too. A rebuild must never work it out from a chat that
        // isn't the one open. The `onChange` of `surfacePlace` in `body`
        // keeps it true, and the memory screen hands it to the setting.
        // Today is made once, for the feed and the chat wired to it both,
        // whichever `StateObject` asks first.
        let today = TodayMaker {
            HomeView.reconFeedModel(sources: feed, needsYou: needsYou, tasks: tasks, drivesTasks: drivesTasks,
                                    reading: sources, place: newChatPlace, memory: memory, model: model,
                                    cloud: cloud, now: now)
        }
        // `StateObject` makes it only once, so a rebuild of this struct makes
        // no chat, no preview gate and no cloud transport.
        // The chat starts after the first run so it opens with the chosen name.
        _chats = StateObject(wrappedValue: ChatSlot(needed ? nil : {
            let chat = HomeView.wired(
                HomeView.newChat(brand: brand, model: model, names: names, cloud: cloud, conversation: conversation),
                to: today.feed)
            if let chatLine { chat.submit(chatLine, byHand: false) }
            return chat
        }()))
        _feed = StateObject(wrappedValue: today.feed)
        _section = State(initialValue: section)
        _cloudSettings = State(initialValue: cloud?.$settings.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
    }

    private func newChat() -> ChatController {
        HomeView.wired(HomeView.newChat(brand: brand, model: model, names: names, cloud: cloud, conversation: nil),
                       to: feed)
    }

    private var chat: ChatController? { chats.chat }

    /// See `HomeView.surfacePlace`.
    private var surfacePlace: PrivacyPlace {
        HomeView.surfacePlace(chat: chat?.privacyPlace, newChat: newChatPlace)
    }

    /// True when the window is wide enough for a sidebar.
    var usesSidebar: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    public var body: some View {
        Group {
            if finished, let chat {
                Group {
                    if usesSidebar {
                        HomeSplit(chat: chat, section: $section, needsYouCount: feed.feed.needsYou.count,
                                  todayScreen: todayScreen(chat), chatScreen: chatScreen(chat),
                                  memoryScreen: memoryScreen, newChat: startNewChat)
                    } else {
                        stack(chat)
                    }
                }
                // Here, around Today and the chat both, so the tap never
                // rests on which screen is still on show once a send from
                // Today has moved to the chat.
                .modifier(SendTap(chat: chat))
                .transition(.opacity)
            } else {
                // No chat yet, so the hello speaks for the one about to start.
                OnboardingView(brand: brand, names: names, store: onboarding, looks: looks,
                               onDevice: surfacePlace.staysOnDevice) { line in
                    firstMessage = line
                    chats.chat = newChat()
                    withAnimation(.easeInOut(duration: 0.4)) { finished = true }
                }
                .transition(.opacity)
            }
        }
        // System controls write their words in the tint, so it is the
        // readable accent, not the brand fill. Controls that fill with the
        // tint and write white on it (the sidebar's selected row, Done)
        // take `Theme.tintFill` instead.
        .tint(Theme.accentText)
        // The live app plays entrances; still renders show everything at once.
        .environment(\.animatesEntrances, true)
        // Questions time out on their own. Looked after here, above Today,
        // so the count beside Today stays true from any place.
        .task { await feed.keepFresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { feed.refresh() }
        }
        // A question or any sheet, the memory on a narrow window included,
        // sits in front; Command Return can't send a chat line from behind it.
        .environment(\.sendsFromKeyboard, cover.chatSendsFromKeyboard)
        // Something waiting on a sheet to close is only for where it was asked.
        .onChange(of: SheetHandoff.Place(section: section, usesSidebar: usesSidebar)) { _, now in
            handoff.moved(to: now)
        }
        .onChange(of: section) { old, new in
            // The sidebar can change places without `go`, so keep where the
            // memory was opened from true, and forget it once the memory
            // closes. A later narrow window then never reopens a stale place.
            if new == .memory, old != .memory {
                memoryOverChat = old == .chat
            } else if new != .memory {
                memoryOverChat = false
            }
        }
        // The flag every device line outside the chat reads, kept in step
        // with the cloud setting and with the chat that is open.
        .onReceive(cloudSettings) { settings in
            newChatPlace = cloud?.privacyPlace(local: model, settings: settings) ?? model.privacyPlace
        }
        .onChange(of: surfacePlace, initial: true) { _, place in
            feed.place = place
        }
        // What a cloud chat would send, over whichever screen is in front,
        // so a line sent from Today's composer is previewed too. It waits,
        // unsent, while another sheet or a question is open, and while it
        // waits it covers the home screen like any sheet (`HomeCover`).
        .cloudPreview(chat?.review, blocked: cover.anySheetOpen || cover.questionOpen || previewTurn.chatWaits,
                      waiting: $previewWaiting)
        // What a summary put together in the cloud would send, the same
        // way, from Today's own gate. Whichever preview came first shows
        // first; the other waits, unsent, for it to close.
        .cloudPreview(feed.cloudReview, blocked: cover.anySheetOpen || cover.questionOpen || previewTurn.todayWaits,
                      waiting: $todayPreviewWaiting)
        .onChange(of: todayPreviewWaiting) { _, waiting in
            var turn = previewTurn
            turn.todayChanged(to: waiting)
            todayPreviewFirst = turn.todayFirst
        }
        .onChange(of: previewWaiting) { _, waiting in
            var turn = previewTurn
            turn.chatChanged(to: waiting)
            todayPreviewFirst = turn.todayFirst
        }
        // A preview can't wait on a window that is gone, so it is not sent.
        .onDisappear {
            chat?.screenWentAway()
            feed.cloudReview.cancelPending()
        }
        .sheet(isPresented: $showsShortcuts, onDismiss: sheetClosed) {
            KeyboardShortcutsView()
        }
        // The same question sheet as everywhere else, with the rule that
        // asked. Closing it any way but yes withdraws the question.
        .sheet(item: $feed.reviewing, onDismiss: { feed.refresh() }) { request in
            ConfirmationSheet(request: request, look: AgentLook.load(from: looks), rule: feed.rule,
                              isExample: feed.isSample(request),
                              onApprove: { feed.approved($0) },
                              onDecline: { feed.closedQuestion(request) })
                .onDisappear { feed.closedQuestion(request) }
        }
        .sheet(item: $feed.reading, onDismiss: sheetClosed) { item in
            FeedReader(item: item, time: feed.timeLabel(for: item.time), isSample: feed.isSample(item))
        }
        .sheet(item: $feed.readingSources, onDismiss: sheetClosed) { summary in
            ReconSourcesSheet(summary: summary, isSample: feed.recon?.isSample(summary.id) == true)
        }
        .sheet(item: $feed.choosingPoint, onDismiss: sheetClosed) { summary in
            ReconRememberSheet(model: feed, summary: summary)
        }
        .task(id: feed.ticks) {
            // Scripted tasks play in real time, wherever the person is, and
            // only while one is live. With nothing going, nothing ticks.
            guard feed.ticks else { return }
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let now = ContinuousClock.now
                let step = now - last
                last = now
                feed.tick(Double(step.components.seconds) + Double(step.components.attoseconds) / 1e18)
            }
        }
        // An alert, not a popover, so both choices show on iPad and Esc keeps the chat.
        .alert(HomeWords.newChatQuestion, isPresented: $asksNewChat) {
            Button(HomeWords.newChatConfirm, role: .destructive) { resetChat() }
            Button(HomeWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(HomeWords.newChatDetail)
        }
        .focusedSceneValue(\.homeActions, HomeActions(
            // A question or a cloud preview on screen waits for its answer;
            // no shortcut sweeps it away.
            canNavigate: finished && !cover.waitsForAnAnswer,
            newChat: startNewChat,
            show: { place in afterClosingSheets { go(place) } },
            showShortcuts: { afterClosingSheets { showsShortcuts = true } }
        ))
    }

    /// Moves to a place. On a narrow screen the memory opens over whatever
    /// is showing and closing it goes back there.
    private func go(_ place: HomeSection) {
        if place == .memory, section != .memory { memoryOverChat = section == .chat }
        section = place
    }

    /// Opens the chat with a line ready to send. Words the person already
    /// typed are never replaced.
    private func talk(about line: String) {
        guard let chat else { return }
        HomeView.draft(line, in: chat)
        go(.chat)
    }

    /// Today's composer sends the way the chat's does, through
    /// `ChatController.send` into the same conversation, so care comes
    /// first and nothing can act without asking. Then the chat opens on it.
    /// In a cloud chat the line goes through the same preview as one typed
    /// in the chat, shown over the chat as it opens.
    private func send(fromToday line: String) {
        guard let chat, !cover.waitsForAnAnswer, HomeView.sendsFromToday(line, chat: chat) else { return }
        // The person's own words went first, so a line picked during the
        // first run is no longer waiting to be sent.
        firstMessage = nil
        go(.chat)
    }

    /// Chats aren't kept yet, so starting over asks first once the person
    /// has said anything. An untouched chat just starts fresh.
    private func startNewChat() {
        guard finished, let chat else { return }
        let asks = NewChatRule.asksFirst(
            personHasSpoken: chat.conversation.turns.contains { $0.speaker == .person },
            draft: chat.draft,
            pendingLine: firstMessage
        )
        afterClosingSheets {
            if asks { asksNewChat = true } else { resetChat() }
        }
    }

    /// A question can't show over a sheet, so close any sheet first and ask
    /// once it has gone. Nothing open means no wait.
    /// A question or a cloud preview is never closed for this; it waits for
    /// its answer.
    private func afterClosingSheets(_ then: @escaping () -> Void) {
        guard !cover.waitsForAnAnswer else { return }
        let closesMemory = cover.memorySheetOpen
        let after = closesMemory ? (memoryOverChat ? HomeSection.chat : .today) : section
        // Run once the sheet has finished closing, not after a guessed time,
        // and only if the home screen is still where it will be then.
        if let now = handoff.start(then, sheetOpen: cover.anySheetOpen,
                                   at: SheetHandoff.Place(section: after, usesSidebar: usesSidebar)) {
            return now()
        }
        if closesMemory { section = after }
        showsShortcuts = false
        feed.reading = nil
        feed.readingSources = nil
        feed.choosingPoint = nil
    }

    /// What covers the home screen right now, read in one place so
    /// Command Return, the handoff and the chat's quiet always agree.
    private var cover: HomeCover {
        HomeCover(usesSidebar: usesSidebar, section: section, showsShortcuts: showsShortcuts,
                  readerOpen: feed.reading != nil || feed.readingSources != nil || feed.choosingPoint != nil,
                  questionOpen: feed.reviewing != nil,
                  previewOpen: previewWaiting || todayPreviewWaiting)
    }

    /// Which of the two previews holds back for the other.
    private var previewTurn: PreviewTurn {
        PreviewTurn(chatPending: previewWaiting, todayPending: todayPreviewWaiting, todayFirst: todayPreviewFirst)
    }

    /// A sheet finished closing. What was waiting runs only if nothing is
    /// open now and no question has opened in the meantime.
    private func sheetClosed() {
        handoff.sheetClosed(stillOpen: cover.anySheetOpen, questionOpen: cover.questionOpen)?()
    }

    private func resetChat() {
        guard finished else { return }
        chat?.stopReplying()
        firstMessage = nil
        chats.chat = newChat()
        section = .chat
    }

    /// One column: Today, with the chat opening on top of it and the memory
    /// opening over either.
    private func stack(_ chat: ChatController) -> some View {
        NavigationStack(path: Binding(
            get: { section == .chat || (section == .memory && memoryOverChat) ? [HomeSection.chat] : [] },
            set: { path in
                if path.isEmpty {
                    section = .today
                    memoryOverChat = false
                } else {
                    section = .chat
                }
            }
        )) {
            todayScreen(chat)
                .toolbar {
                    // The chat as it was, one tap away, for when there is
                    // nothing new to type.
                    ToolbarItem(placement: .primaryAction) { ChatToolbarButton(chat: chat) { go(.chat) } }
                    ToolbarItem(placement: .primaryAction) { memoryButton }
                }
                .navigationDestination(for: HomeSection.self) { _ in
                    chatScreen(chat)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) { memoryButton }
                        }
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
        }
        .sheet(isPresented: Binding(
            get: { section == .memory },
            // Only a swipe down still has the memory chosen. Done has
            // already gone back, and where it came from is forgotten by now.
            set: { if !$0, section == .memory { section = memoryOverChat ? .chat : .today } }
        ), onDismiss: sheetClosed) {
            NavigationStack {
                memoryScreen
                    .presentationDragIndicator(.visible)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            DoneButton { section = memoryOverChat ? .chat : .today }
                        }
                    }
            }
        }
    }

    private var memoryButton: some View {
        Button { go(.memory) } label: {
            Label(MemoryWords.title, systemImage: HomeSection.memory.symbol)
        }
    }

    /// Today, with the chat's composer right on it: type and go.
    private func todayScreen(_ chat: ChatController) -> some View {
        FeedView(model: feed, look: AgentLook.load(from: looks), onTalk: { talk(about: $0) })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Command Return belongs to whichever composer is in front.
                TodayComposer(chat: chat, inFront: cover.todayInFront) {
                    send(fromToday: $0)
                }
            }
    }

    private func chatScreen(_ chat: ChatController) -> some View {
        ChatView(controller: chat, look: AgentLook.load(from: looks), firstMessage: firstMessage,
                 covered: cover.chatIsCovered,
                 onFirstMessageSent: { firstMessage = nil })
            .background(Backdrop())
            // A new chat is a new conversation, so it starts fresh on screen too.
            // Load-bearing: ChatView keeps its controller in a StateObject, so
            // without this id a new controller would never reach the screen.
            .id(ObjectIdentifier(chat))
    }

    /// The fallback memory screen's forget: every task, then the private
    /// words, each whatever happens to the other.
    private func forgetTasksWithoutNotes() {
        wordsErased = HomeView.forgetWithoutNotes(cloud: cloud) { feed.forgetTasks() }
    }

    @ViewBuilder
    private var memoryScreen: some View {
        if let memory {
            // Built inside MemoryView's StateObject, once per screen, never
            // on each pass through here. `place` then keeps its words in
            // step with the cloud setting and the open chat.
            MemoryView(model: HomeView.memoryModel(store: memory, place: surfacePlace, cloud: cloud,
                                                   onForgetEverything: { feed.forgetTasks() }),
                       place: surfacePlace, cloud: cloud)
        } else {
            // The store couldn't be opened. Say so rather than hide memory.
            // Tasks can still be forgotten here, since Forget everything isn't.
            //
            // The cloud setting is reached only through the memory screen,
            // so it has no way in from here, and that is safe. The notes
            // folder is the only place either can be kept, so if it can't
            // be opened the setting's file can't be either: the app makes
            // the setting with `CloudHelp.couldNotOpen`, which reads as off,
            // can't be turned on and says why. Even if it could, with no
            // notes to read the redactor refuses to send anything. If the
            // setting is ever kept somewhere that opens on its own, give it
            // a route here, so it can always be seen and turned off.
            //
            // Private words kept from an earlier launch go with the tasks,
            // through `CloudHelp.eraseWordsWithoutNotes`, and the line says
            // whether they could.
            MemoryUnavailableView(hasTasks: feed.hasTasks, forgotten: feed.tasksForgotten,
                                  underway: feed.forgotUnderway, wordsErased: wordsErased,
                                  erasesWords: cloud != nil, onForgetTasks: forgetTasksWithoutNotes)
        }
    }
}

/// The home screen's open chat. Starting a new one replaces it, which
/// redraws the home screen.
@MainActor
final class ChatSlot: ObservableObject {
    @Published var chat: ChatController?

    init(_ chat: ChatController?) { self.chat = chat }
}

/// Only one sheet shows at a time, so when a cloud chat and Today's summary
/// both have a preview waiting, the one that came first shows and the other
/// waits, unsent. One alone never waits for the other.
struct PreviewTurn: Equatable {
    var chatPending: Bool
    var todayPending: Bool
    /// Today's preview was waiting before the chat's.
    var todayFirst: Bool

    var chatWaits: Bool { todayPending && todayFirst }
    var todayWaits: Bool { chatPending && !todayFirst }

    /// Today's preview started or stopped waiting. It is first when no
    /// chat preview was there before it.
    mutating func todayChanged(to pending: Bool) {
        todayPending = pending
        if pending { todayFirst = !chatPending }
    }

    /// The chat's preview started or stopped waiting. When it closes with
    /// Today's still waiting, Today's shows now, so it counts as first: a
    /// new chat preview then waits for it, and never takes a sheet already
    /// on screen away from the person.
    mutating func chatChanged(to pending: Bool) {
        chatPending = pending
        if pending, !todayPending { todayFirst = false }
        if !pending, todayPending { todayFirst = true }
    }
}

/// Makes Today's model once, on first ask, so the feed and the first chat
/// wired to it share it whichever `StateObject` is made first.
@MainActor
final class TodayMaker {
    private let make: () -> FeedModel
    private(set) lazy var feed: FeedModel = make()

    init(_ make: @escaping () -> FeedModel) { self.make = make }
}

/// The chat's composer, at the foot of Today. It shares the chat's draft,
/// so words typed here are still there in the chat, and the other way round.
///
/// A reply can fail after the person has come back to Today, and then the
/// line may reappear here. So the failure shows here too, right above the
/// words it talks about, and is spoken while Today is in front.
struct TodayComposer: View {
    @ObservedObject var chat: ChatController
    /// True while Today is the screen in front, with no sheet or question
    /// over it. Only then may Command Return send or anything be spoken.
    let inFront: Bool
    let send: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = Theme.chatWidth

    /// The shared field, with a hint that sending here opens the chat.
    var composer: Composer {
        Composer(draft: $chat.draft, isBusy: chat.isReplying, keyboardSends: inFront,
                 identifier: "todayComposer", lines: 1...4, hint: FeedWords.composerHint, send: send)
    }

    /// The chat's failure line, when there is one, to show above the field.
    var failure: String? { chat.failure }

    /// The failure is read aloud here only while Today is in front, so it
    /// is never spoken over a sheet. It is taken from the chat, so whichever
    /// screen speaks it first, here or the chat, is the only one that does.
    /// One that landed while Today was behind is read when Today comes back.
    static func spokenFailure(_ chat: ChatController, inFront: Bool) -> String? {
        inFront ? chat.takeUnheardFailure() : nil
    }

    private func speakFailure() {
        if let line = Self.spokenFailure(chat, inFront: inFront) {
            AccessibilityNotification.Announcement(line).post()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure {
                GentleNotice(text: failure)
                    .transition(.opacity)
                    .accessibilityIdentifier("todayFailure")
            }
            composer
        }
        .padding(.vertical, 12)
        .readableColumn(columnWidth)
        .onChange(of: chat.failure) { speakFailure() }
        .onChange(of: inFront) { speakFailure() }
        .onAppear { speakFailure() }
        .background {
            // Solid, so cards scrolling under it never show through the words.
            Theme.backdropEnds(scheme).bottom.color
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(scheme)).frame(height: 1) }
        }
    }
}

/// The light tap for a line the person sent, from Today or the chat. It
/// wraps both screens, so it never sits on a screen that leaves as it
/// sends: Today moves to the chat in the same pass as its send, and a
/// tap left to either screen could be lost or felt twice.
struct SendTap: ViewModifier {
    @ObservedObject var chat: ChatController

    /// Whether the send count changing to `count` is felt. A new chat
    /// starts at zero, which is no send.
    static func plays(_ count: Int) -> Bool { count > 0 }

    func body(content: Content) -> some View {
        content.haptic(.sent, trigger: chat.sentCount, when: Self.plays)
    }
}

/// The chat, one tap from Today on a narrow screen, for when there is
/// nothing new to type.
struct ChatToolbarButton: View {
    @ObservedObject var chat: ChatController
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(FeedWords.chatWith(chat.displayName.text), systemImage: HomeSection.chat.symbol)
        }
        .help(FeedWords.chatWith(chat.displayName.text))
        .accessibilityIdentifier("chatButton")
    }
}

/// What covers the home screen, from its state. Every rule about sheets
/// reads this one value: Command Return in the chat and on Today, the
/// handoff that waits for a sheet to close, and whether the chat may speak.
struct HomeCover: Equatable {
    var usesSidebar: Bool
    var section: HomeSection?
    var showsShortcuts: Bool
    /// A finished piece of work open to read.
    var readerOpen: Bool
    /// A question waiting for its answer.
    var questionOpen: Bool
    /// A cloud chat's preview waiting for its answer: on screen, or held
    /// back, unsent, until the sheet in front of it closes.
    var previewOpen = false

    /// On a narrow window the memory opens as a sheet over the chat or Today.
    var memorySheetOpen: Bool { !usesSidebar && section == .memory }

    /// Any sheet but a question or a preview: the shortcuts, a piece of
    /// work to read, or the memory on a narrow window.
    var anySheetOpen: Bool { showsShortcuts || readerOpen || memorySheetOpen }

    /// A question or a preview is up. Each waits for its answer, so no
    /// shortcut, handoff or send from Today sweeps it away.
    var waitsForAnAnswer: Bool { questionOpen || previewOpen }

    /// The chat says nothing aloud while anything covers it.
    var chatIsCovered: Bool { anySheetOpen || waitsForAnAnswer }

    /// Command Return may send a chat line only with nothing in front.
    var chatSendsFromKeyboard: Bool { !chatIsCovered }

    /// Today's composer also needs Today itself in front, not the chat.
    var todayInFront: Bool { section == .today && !chatIsCovered }
}

/// Something to do once the open sheet has finished closing, such as
/// showing the shortcuts. It waits for the sheet to say it has gone, not
/// for a guessed time, and is dropped if a question opened meanwhile,
/// since a question waits for its answer.
///
/// It is held for one place: the section the home screen will show once
/// the sheet is gone, at the window's current shape. If the place changes
/// first, say the window is resized from a sidebar to one column mid-close,
/// the sheet that was meant to close may never say so, and a much later
/// dismissal would run it by surprise. So a move elsewhere drops it.
struct SheetHandoff {
    struct Place: Equatable {
        var section: HomeSection?
        var usesSidebar: Bool
    }

    private(set) var waiting: (() -> Void)?
    private var place: Place?

    mutating func hold(_ then: @escaping () -> Void, at place: Place) {
        waiting = then
        self.place = place
    }

    /// Asked to do `then` once the sheets are closed. With nothing open it
    /// comes straight back to run now, and anything older is dropped so a
    /// later dismissal can't run it. Otherwise it waits at `place`.
    mutating func start(_ then: @escaping () -> Void, sheetOpen: Bool, at place: Place) -> (() -> Void)? {
        guard sheetOpen else {
            clear()
            return then
        }
        hold(then, at: place)
        return nil
    }

    /// Nothing waits any more, such as when nothing was open to close.
    mutating func clear() {
        waiting = nil
        place = nil
    }

    /// The section or the window's shape changed. Anything held for
    /// another place is dropped.
    mutating func moved(to now: Place) {
        if waiting != nil, now != place { clear() }
    }

    /// A sheet has gone. What to run now, if anything.
    mutating func sheetClosed(stillOpen: Bool, questionOpen: Bool) -> (() -> Void)? {
        guard let then = waiting, !stillOpen else { return nil }
        clear()
        return questionOpen ? nil : then
    }
}

/// The wide layout: a sidebar of places, and the chosen one beside it.
struct HomeSplit<TodayScreen: View, ChatScreen: View, MemoryScreen: View>: View {
    @ObservedObject var chat: ChatController
    @Binding var section: HomeSection?
    /// Shown beside Today while questions wait, so they are seen from anywhere.
    var needsYouCount = 0
    let todayScreen: TodayScreen
    let chatScreen: ChatScreen
    let memoryScreen: MemoryScreen
    let newChat: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(HomeSection.allCases, id: \.self) { place in
                    NavigationLink(value: place) {
                        Label(place.title, systemImage: place.symbol)
                    }
                    .badge(place == .today ? needsYouCount : 0)
                }
            }
            // The selected row is filled with the tint and its words turn
            // white, so the sidebar takes the deep fill tint, not the root's
            // `accentText`, which is too light under white in dark mode.
            .tint(Theme.tintFill)
            .navigationTitle(chat.displayName.text)
        } detail: {
            NavigationStack {
                switch section ?? .today {
                case .today:
                    todayScreen
                case .chat:
                    chatScreen
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) { newChatButton }
                        }
                case .memory:
                    memoryScreen
                }
            }
        }
    }

    private var newChatButton: some View {
        Button(action: newChat) {
            Label(HomeWords.newChatTitle, systemImage: "square.and.pencil")
        }
        .help(HomeWords.newChatTitle)
    }
}

/// What the menus and keyboard shortcuts can ask the focused window to do.
public struct HomeActions {
    public let canNavigate: Bool
    public let newChat: () -> Void
    public let show: (HomeSection) -> Void
    public let showShortcuts: () -> Void
}

extension FocusedValues {
    @Entry public var homeActions: HomeActions?
}

extension EnvironmentValues {
    /// Whether Command Return may send the chat line. Off while a question
    /// sheet waits for its answer, like the other shortcuts, and while any
    /// other sheet covers the chat. See `HomeCover`.
    @Entry var sendsFromKeyboard = true
}

/// The app's menu commands. On iPad, holding Command shows them with their
/// shortcuts, and a hardware keyboard can reach every one.
public struct HomeCommands: Commands {
    @FocusedValue(\.homeActions) private var actions

    public init() {}

    /// Command 1 to Command 9 for the first nine places. A tenth gets no
    /// shortcut rather than a key that doesn't exist.
    static func goShortcut(for index: Int) -> KeyboardShortcut? {
        guard (0..<9).contains(index) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))))
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(HomeWords.newChatTitle) { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions?.canNavigate != true)
        }
        CommandMenu(HomeWords.goMenuTitle) {
            // Numbered in sidebar order, the way Apple's apps do it.
            ForEach(Array(HomeSection.allCases.enumerated()), id: \.element) { index, place in
                Button(place.title) { actions?.show(place) }
                    .keyboardShortcut(Self.goShortcut(for: index))
                    .disabled(actions?.canNavigate != true)
            }
        }
        CommandGroup(replacing: .help) {
            Button(HomeWords.shortcutsTitle) { actions?.showShortcuts() }
                .keyboardShortcut("/")
                .disabled(actions == nil)
        }
    }
}

/// Every keyboard shortcut in plain words, including the ones that live in
/// the composer and so never show up in a menu.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(HomeWords.shortcuts, id: \.action) { shortcut in
                    LabeledContent(shortcut.action) {
                        Text(shortcut.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(shortcut.action), \(HomeWords.spoken(shortcut.keys))")
                }
            }
            .navigationTitle(HomeWords.shortcutsTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
