import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// The app's root: the guided first run until it's finished, then the chat
/// with a way to see what the agent remembers.
///
/// On a wide window (an iPad in full screen or a wide Split View) the chat
/// and the memory sit side by side with a sidebar. On a narrow one (iPhone,
/// Slide Over, a narrow Split View) the chat is home and the memory opens
/// over it. The conversation is kept here, so changing the window's shape
/// never loses it.
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
    @State private var showsShortcuts = false
    @State private var asksNewChat = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults = .standard
    ) {
        self.init(brand: brand, model: model, names: names, onboarding: onboarding, memory: memory,
                  looks: looks, conversation: nil, section: .chat)
    }

    /// Opens on a given conversation and section, for screenshots and tests.
    package init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        onboarding: any OnboardingStoring,
        memory: MemoryStore?,
        looks: UserDefaults,
        conversation: Conversation?,
        section: HomeSection
    ) {
        self.brand = brand
        self.model = model
        self.names = names
        self.onboarding = onboarding
        self.memory = memory
        self.looks = looks
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
                        HomeSplit(chat: chat, section: $section, chatScreen: chatScreen(chat),
                                  memoryScreen: memoryScreen, newChat: startNewChat)
                    } else {
                        stack(chat)
                    }
                }
                .transition(.opacity)
            } else {
                OnboardingView(brand: brand, names: names, store: onboarding, looks: looks) { line in
                    firstMessage = line
                    chat = ChatController.make(brand: brand, model: model, names: names, conversation: nil)
                    withAnimation(.easeInOut(duration: 0.4)) { finished = true }
                }
                .transition(.opacity)
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showsShortcuts) {
            KeyboardShortcutsView()
        }
        // An alert, not a popover, so both choices show on iPad and Esc keeps the chat.
        .alert(HomeWords.newChatQuestion, isPresented: $asksNewChat) {
            Button(HomeWords.newChatConfirm, role: .destructive) { resetChat() }
            Button(HomeWords.cancelTitle, role: .cancel) {}
        } message: {
            Text(HomeWords.newChatDetail)
        }
        .focusedSceneValue(\.homeActions, HomeActions(
            canNavigate: finished,
            newChat: startNewChat,
            show: { section = $0 },
            showShortcuts: { afterClosingSheets { showsShortcuts = true } }
        ))
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
    private func afterClosingSheets(_ then: @escaping () -> Void) {
        let memorySheetOpen = !usesSidebar && section == .memory
        guard memorySheetOpen || showsShortcuts else { return then() }
        if memorySheetOpen { section = .chat }
        showsShortcuts = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { then() }
    }

    private func resetChat() {
        guard finished else { return }
        chat?.stopReplying()
        firstMessage = nil
        chat = ChatController.make(brand: brand, model: model, names: names, conversation: nil)
        section = .chat
    }

    /// One column: the chat, with the memory opening over it.
    private func stack(_ chat: ChatController) -> some View {
        NavigationStack {
            chatScreen(chat)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { section = .memory } label: {
                            Label(MemoryWords.title, systemImage: HomeSection.memory.symbol)
                        }
                    }
                }
        }
        .sheet(isPresented: Binding(
            get: { section == .memory },
            set: { if !$0 { section = .chat } }
        )) {
            NavigationStack {
                memoryScreen
                    .presentationDragIndicator(.visible)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(MemoryWords.doneTitle) { section = .chat }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
            }
        }
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
            ZStack {
                Backdrop()
                Label(MemoryWords.unavailable, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(Theme.gutter)
            }
        }
    }
}

/// The wide layout: a sidebar of places, and the chosen one beside it.
struct HomeSplit<ChatScreen: View, MemoryScreen: View>: View {
    @ObservedObject var chat: ChatController
    @Binding var section: HomeSection?
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
                }
            }
            .navigationTitle(chat.displayName.text)
        } detail: {
            NavigationStack {
                switch section ?? .chat {
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
            Button(HomeSection.chat.title) { actions?.show(.chat) }
                .keyboardShortcut("1")
                .disabled(actions?.canNavigate != true)
            Button(HomeSection.memory.title) { actions?.show(.memory) }
                .keyboardShortcut("2")
                .disabled(actions?.canNavigate != true)
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
