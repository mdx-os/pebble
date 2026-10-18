import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import Combine
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
public struct HomeView: View {
    let brand: Brand
    let model: any ModelClient
    let names: any AgentNameStoring
    let onboarding: any OnboardingStoring
    let memory: MemoryStore?
    let looks: UserDefaults
    /// The cloud setting. Nil, or off, means every chat stays on this device.
    let cloud: CloudHelp?

    @State private var finished: Bool
    /// Where the person's words may go from here: the model's place, unless
    /// the cloud is on. Kept fresh as the setting changes, and passed to
    /// Today and the memory so their device lines follow it.
    @State private var place: PrivacyPlace
    @State private var firstMessage: String?
    @State private var chat: ChatController?
    @State private var section: HomeSection?
    /// On a narrow screen, whether the memory was opened from the chat, so
    /// closing it goes back there rather than to Today.
    @State private var memoryOverChat = false
    @State private var showsShortcuts = false
    @State private var asksNewChat = false
    /// What to do once the open sheet has finished closing.
    @State private var handoff = SheetHandoff()
    @StateObject private var feed: FeedModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.scenePhase) private var scenePhase

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
                  looks: looks, conversation: nil, section: .today, feed: feed, needsYou: needsYou,
                  tasks: tasks, cloud: cloud)
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
        cloud: CloudHelp? = nil,
        // Said in the chat as it opens, for screenshots of what follows.
        chatLine: String? = nil
    ) {
        self.brand = brand
        self.model = model
        self.names = names
        self.onboarding = onboarding
        self.memory = memory
        self.looks = looks
        self.cloud = cloud
        let place = cloud?.place(local: model.privacyPlace) ?? model.privacyPlace
        _place = State(initialValue: place)
        let chatModel = cloud?.chatModel(local: model) ?? model
        // Every task, a recon's included, runs through one runner. With no
        // engine given, the scripted one plays in real time.
        let engine = tasks ?? LocalFakeEngine(rule: needsYou.rule)
        let runner = (engine as? ReconRunner) ?? ReconRunner(engine: engine, provider: sources)
        let feedModel = FeedModel(sources: feed, needsYou: needsYou, tasks: runner,
                                  drivesTasks: drivesTasks || tasks == nil, place: place,
                                  memory: memory, now: now)
        // Asked at each start, so turning the cloud on or off counts from
        // the next one, as it does for chats.
        feedModel.summarizer = { ReconSummarizers.choose(for: cloud?.chatModel(local: model) ?? model) }
        _feed = StateObject(wrappedValue: feedModel)
        let needed = OnboardingFlow.isNeeded(store: onboarding, names: names)
        // People who named their agent before the first run existed count as finished.
        if !needed, !onboarding.hasFinished() { onboarding.markFinished() }
        _finished = State(initialValue: !needed)
        // The chat starts after the first run so it opens with the chosen name.
        let chat = needed ? nil
            : Self.wired(ChatController.make(brand: brand, model: chatModel, names: names, conversation: conversation),
                         to: feedModel, local: model.privacyPlace)
        if let chatLine { chat?.submit(chatLine, byHand: false) }
        _chat = State(initialValue: chat)
        _section = State(initialValue: section)
    }

    /// Lets a chat offer to look into something. It starts only on the person's tap.
    /// An on-device chat's recon stays on this device, whatever the cloud
    /// setting is when the person taps.
    private static func wired(_ chat: ChatController, to feed: FeedModel, local: PrivacyPlace) -> ChatController {
        chat.lookInto = { [weak feed] topic, onDevice in feed?.lookInto(topic, onDevice: onDevice) ?? false }
        chat.reconReadsExamples = feed.readsExamples
        chat.localPlace = local
        return chat
    }

    /// The model a new chat gets. A chat keeps the model it started with,
    /// so its opening line stays true; changing the cloud setting counts
    /// from the next new chat.
    private var newChatModel: any ModelClient {
        cloud?.chatModel(local: model) ?? model
    }

    /// Each change to the cloud setting, or none without one.
    private var cloudChanges: AnyPublisher<CloudHelpSettings, Never> {
        cloud?.$settings.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
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
                .transition(.opacity)
            } else {
                OnboardingView(brand: brand, names: names, store: onboarding, looks: looks,
                               onDevice: newChatModel.privacyPlace.staysOnDevice) { line in
                    firstMessage = line
                    chat = Self.wired(ChatController.make(brand: brand, model: newChatModel, names: names, conversation: nil),
                                      to: feed, local: model.privacyPlace)
                    withAnimation(.easeInOut(duration: 0.4)) { finished = true }
                }
                .transition(.opacity)
            }
        }
        // System controls write their words in the tint, so it is the
        // readable accent, not the brand fill.
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
        // What would leave the device, shown over whichever screen asked:
        // the chat, or Today when a summary is put together in the cloud.
        .cloudPreview(cloud?.review)
        // The device lines on Today and in the memory follow the setting.
        .onReceive(cloudChanges) { settings in
            place = cloud?.place(local: model.privacyPlace, with: settings) ?? model.privacyPlace
        }
        .onChange(of: place) { _, place in feed.place = place }
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
            // A question on screen waits for its answer; no shortcut sweeps it away.
            canNavigate: finished && feed.reviewing == nil,
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
        if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chat.draft = line }
        go(.chat)
    }

    /// Today's composer sends the way the chat's does, through
    /// `ChatController.send` into the same conversation, so care comes
    /// first and nothing can act without asking. Then the chat opens on it.
    private func send(fromToday line: String) {
        guard let chat, feed.reviewing == nil, Self.sendsFromToday(line, chat: chat) else { return }
        // The person's own words went first, so a line picked during the
        // first run is no longer waiting to be sent.
        firstMessage = nil
        go(.chat)
    }

    /// The send itself, apart from moving, so tests can drive it.
    @discardableResult
    static func sendsFromToday(_ line: String, chat: ChatController) -> Bool {
        chat.send(line)
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
    /// A question on screen is never closed for this; it waits for its answer.
    private func afterClosingSheets(_ then: @escaping () -> Void) {
        guard feed.reviewing == nil else { return }
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
                  questionOpen: feed.reviewing != nil)
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
        chat = Self.wired(ChatController.make(brand: brand, model: newChatModel, names: names, conversation: nil),
                          to: feed, local: model.privacyPlace)
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
                            Button(MemoryWords.doneTitle) { section = memoryOverChat ? .chat : .today }
                                .keyboardShortcut(.cancelAction)
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

    @ViewBuilder
    private var memoryScreen: some View {
        if let memory {
            MemoryView(store: memory, place: place, cloud: cloud, onForgetEverything: { feed.forgetTasks() })
        } else {
            // The store couldn't be opened. Say so rather than hide memory.
            // Tasks can still be forgotten here, since Forget everything isn't.
            MemoryUnavailableView(hasTasks: feed.hasTasks, forgotten: feed.tasksForgotten,
                                  underway: feed.forgotUnderway, onForgetTasks: { feed.forgetTasks() })
        }
    }
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
    /// is never spoken twice or over a sheet.
    static func spokenFailure(_ failure: String?, inFront: Bool) -> String? {
        inFront ? failure : nil
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
        .onChange(of: chat.failure) { _, failure in
            if let line = Self.spokenFailure(failure, inFront: inFront) {
                AccessibilityNotification.Announcement(line).post()
            }
        }
        .background {
            // Solid, so cards scrolling under it never show through the words.
            Theme.backdropEnds(scheme).bottom.color
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline(scheme)).frame(height: 1) }
        }
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

    /// On a narrow window the memory opens as a sheet over the chat or Today.
    var memorySheetOpen: Bool { !usesSidebar && section == .memory }

    /// Any sheet but a question: the shortcuts, a piece of work to read, or
    /// the memory on a narrow window.
    var anySheetOpen: Bool { showsShortcuts || readerOpen || memorySheetOpen }

    /// The chat says nothing aloud while anything covers it.
    var chatIsCovered: Bool { anySheetOpen || questionOpen }

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
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
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
                    Button(MemoryWords.doneTitle) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
