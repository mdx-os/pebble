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
public struct HomeView: View {
    let brand: Brand
    let model: any ModelClient
    let names: any AgentNameStoring
    let onboarding: any OnboardingStoring
    let memory: MemoryStore?
    let looks: UserDefaults

    @State private var finished: Bool
    @State private var firstMessage: String?
    @State private var chat: ChatController?
    @State private var section: HomeSection?
    /// On a narrow screen, whether the memory was opened from the chat, so
    /// closing it goes back there rather than to Today.
    @State private var memoryOverChat = false
    @State private var showsShortcuts = false
    @State private var asksNewChat = false
    @StateObject private var feed: FeedModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// `feed` is where finished work comes from. Questions come only from
    /// `needsYou` and `tasks`, which both ask through `AskFirst`. `tasks`
    /// shows long work on live cards.
    public init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults = .standard,
        feed: [any FeedSource] = [EmptyFeedSource()],
        needsYou: NeedsYou = NeedsYou(),
        tasks: (any TaskEngine)? = nil
    ) {
        self.init(brand: brand, model: model, names: names, onboarding: onboarding, memory: memory,
                  looks: looks, conversation: nil, section: .today, feed: feed, needsYou: needsYou, tasks: tasks)
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
        now: @escaping () -> Date = { Date() }
    ) {
        self.brand = brand
        self.model = model
        self.names = names
        self.onboarding = onboarding
        self.memory = memory
        self.looks = looks
        _feed = StateObject(wrappedValue: FeedModel(sources: feed, needsYou: needsYou, tasks: tasks,
                                                     drivesTasks: drivesTasks, now: now))
        let needed = OnboardingFlow.isNeeded(store: onboarding, names: names)
        // People who named their agent before the first run existed count as finished.
        if !needed, !onboarding.hasFinished() { onboarding.markFinished() }
        _finished = State(initialValue: !needed)
        // The chat starts after the first run so it opens with the chosen name.
        _chat = State(initialValue: needed ? nil
            : ChatController.make(brand: brand, model: model, names: names, conversation: conversation))
        _section = State(initialValue: section)
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
                               onDevice: model.runsOnDevice) { line in
                    firstMessage = line
                    chat = ChatController.make(brand: brand, model: model, names: names, conversation: nil)
                    withAnimation(.easeInOut(duration: 0.4)) { finished = true }
                }
                .transition(.opacity)
            }
        }
        .tint(Theme.accent)
        // The live app plays entrances; still renders show everything at once.
        .environment(\.animatesEntrances, true)
        // A question on screen waits for its answer; Command Return can't
        // send a chat line from behind it.
        .environment(\.sendsFromKeyboard, feed.reviewing == nil)
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
        .sheet(isPresented: $showsShortcuts) {
            KeyboardShortcutsView()
        }
        // The same question sheet as everywhere else, with the rule that
        // asked. Closing it any way but yes withdraws the question.
        .sheet(item: $feed.reviewing, onDismiss: { feed.refresh() }) { request in
            ConfirmationSheet(request: request, look: AgentLook.load(from: looks), rule: feed.rule,
                              onApprove: { feed.approved($0) },
                              onDecline: { feed.closedQuestion(request) })
                .onDisappear { feed.closedQuestion(request) }
        }
        .sheet(item: $feed.reading) { item in
            FeedReader(item: item, time: feed.timeLabel(for: item.time), isSample: feed.isSample(item))
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
        let memorySheetOpen = !usesSidebar && section == .memory
        let readerOpen = feed.reading != nil
        guard memorySheetOpen || showsShortcuts || readerOpen else { return then() }
        if memorySheetOpen { section = memoryOverChat ? .chat : .today }
        showsShortcuts = false
        feed.reading = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { then() }
    }

    private func resetChat() {
        guard finished else { return }
        chat?.stopReplying()
        firstMessage = nil
        chat = ChatController.make(brand: brand, model: model, names: names, conversation: nil)
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
                    ToolbarItem(placement: .primaryAction) { memoryButton }
                }
                .safeAreaInset(edge: .bottom) {
                    // An empty Today offers the chat itself, so one button is enough.
                    if !feed.feed.isEmpty {
                        ChatButton(name: chat.displayName.text) { go(.chat) }
                            .padding(.horizontal, Theme.gutter)
                            .padding(.bottom, 8)
                    }
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
        )) {
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

    private func todayScreen(_ chat: ChatController) -> some View {
        FeedView(model: feed, look: AgentLook.load(from: looks),
                 onTalk: { talk(about: $0) }, onChat: { go(.chat) })
    }

    private func chatScreen(_ chat: ChatController) -> some View {
        ChatView(controller: chat, look: AgentLook.load(from: looks), firstMessage: firstMessage,
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
            MemoryView(store: memory)
        } else {
            // The store couldn't be opened. Say so rather than hide memory.
            // It is only opened again at launch, so the words say that.
            ZStack {
                Backdrop()
                GentleNotice(text: MemoryWords.couldNotOpen)
                    .padding(Theme.gutter)
                    .frame(maxWidth: Theme.readableWidth)
            }
        }
    }
}

/// The chat, one tap from Today on a narrow screen. It sits at the bottom,
/// where a thumb reaches it.
/// With little height, as on a phone turned sideways, it shrinks to a small
/// pill in the corner so the cards keep the room.
struct ChatButton: View {
    let name: String
    let action: () -> Void
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var isShort: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if isShort {
                Button(action: action) { label }
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button(action: action) { label }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: Theme.readableWidth)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .pointerHover(in: Capsule())
        .accessibilityIdentifier("chatButton")
    }

    private var label: some View {
        Label(FeedWords.chatWith(name), systemImage: HomeSection.chat.symbol)
            .labelStyle(.titleAndIcon)
    }
}

/// The primary button's look at the size of its words.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Theme.accent, in: Capsule())
            .scaleEffect(configuration.isPressed ? Motion.pressedScale(reduceMotion: reduceMotion) : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
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
    /// sheet waits for its answer, like the other shortcuts.
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
                            .foregroundStyle(.secondary)
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
