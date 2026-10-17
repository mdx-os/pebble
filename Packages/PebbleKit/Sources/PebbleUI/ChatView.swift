import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import GameController
#endif

/// The first screen: the agent has a face, a name, and a conversation.
public struct ChatView: View {
    @StateObject private var controller: ChatController
    @FocusState private var nameFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    /// Grows with the text size so lines keep a comfortable length.
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = Theme.chatWidth
    @ScaledMetric(relativeTo: .body) private var bubbleWidth: CGFloat = Theme.bubbleWidth
    private let look: AgentLook?
    private let firstMessage: String?
    private let onFirstMessageSent: () -> Void

    public init(
        brand: Brand,
        model: any ModelClient = LocalStubModel(),
        names: any AgentNameStoring = UserDefaultsAgentNameStore(),
        look: AgentLook? = nil,
        firstMessage: String? = nil,
        onFirstMessageSent: @escaping () -> Void = {}
    ) {
        self.init(brand: brand, model: model, names: names, look: look, firstMessage: firstMessage,
                  conversation: nil, onFirstMessageSent: onFirstMessageSent)
    }

    package init(
        brand: Brand,
        model: any ModelClient,
        names: any AgentNameStoring,
        look: AgentLook?,
        firstMessage: String?,
        conversation: Conversation?,
        onFirstMessageSent: @escaping () -> Void = {}
    ) {
        self.init(
            controller: ChatController.make(brand: brand, model: model, names: names, conversation: conversation),
            look: look, firstMessage: firstMessage, onFirstMessageSent: onFirstMessageSent
        )
    }

    /// Shows a conversation kept by the screen around it, so the chat
    /// survives the window changing between the sidebar and one column.
    init(
        controller: @autoclosure @escaping () -> ChatController,
        look: AgentLook?,
        firstMessage: String?,
        onFirstMessageSent: @escaping () -> Void = {}
    ) {
        _controller = StateObject(wrappedValue: controller())
        self.look = look
        self.firstMessage = firstMessage
        self.onFirstMessageSent = onFirstMessageSent
    }

    /// When there is little height, as on a phone turned sideways, the
    /// header scrolls with the conversation instead of crowding it.
    private var headerScrolls: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !headerScrolls {
                header
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .readableColumn(columnWidth)
            }
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if headerScrolls {
                        header
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                    }
                    transcript
                    if controller.conversation.isWaitingForPerson {
                        starterJobs
                    }
                    if controller.isReplying {
                        Text(FirstConversation.thinking)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let failure = controller.failure {
                        Text(failure)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                .readableColumn(columnWidth)
            }
            .onAppear {
                // Wait one pass so layout is done before jumping to the end.
                DispatchQueue.main.async {
                    Self.scrollToLatest(controller.conversation, with: scroller, animated: false)
                }
            }
            .onChange(of: controller.conversation.turns.count) {
                Self.scrollToLatest(controller.conversation, with: scroller, animated: !reduceMotion)
                if let line = Self.announcement(for: controller.conversation) {
                    AccessibilityNotification.Announcement(line).post()
                }
            }
            }
            composer
                .padding(.vertical, 16)
                .readableColumn(columnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: controller.conversation.turns.count)
        .task {
            if let firstMessage, controller.conversation.isWaitingForPerson {
                controller.submit(firstMessage)
                onFirstMessageSent()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let look {
                CharacterView(look: look, size: 72)
            } else {
                AvatarView(initial: controller.displayName.initial)
            }
            Text(controller.displayName.text)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(FirstConversation.presence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if controller.showsNameInvitation {
                Text(FirstConversation.nameInvitation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            renameControl
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var renameControl: some View {
        if controller.isChoosingName {
            VStack(spacing: 8) {
                TextField(
                    FirstConversation.namePlaceholder,
                    text: Binding(
                        get: { controller.nameDraft },
                        set: { controller.setNameDraft($0) }
                    )
                )
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 280)
                .focused($nameFieldFocused)
                .onAppear { nameFieldFocused = true }
                .onSubmit { controller.commitName() }
                if let nameHint = controller.nameHint {
                    Text(nameHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    Button(FirstConversation.cancelNameTitle) {
                        controller.cancelRename()
                    }
                    .buttonStyle(.bordered)
                    Button(FirstConversation.confirmNameTitle) {
                        controller.commitName()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(controller.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            Button(controller.renameTitle) {
                controller.beginRename()
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
    }

    /// New replies land below the fold on small screens, so follow them.
    private static func scrollToLatest(_ conversation: Conversation, with scroller: ScrollViewProxy, animated: Bool) {
        guard let last = conversation.turns.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(last, anchor: .bottom) }
        } else {
            scroller.scrollTo(last, anchor: .bottom)
        }
    }

    /// New lines from the agent are read out, since they may land offscreen.
    static func announcement(for conversation: Conversation) -> String? {
        guard let last = conversation.turns.last, last.speaker == .agent, !conversation.isWaitingForPerson else {
            return nil
        }
        return last.text
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(controller.conversation.turns) { turn in
                bubble(turn)
                    .id(turn.id)
            }
        }
    }

    private func bubble(_ turn: ChatTurn) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if turn.speaker == .person {
                Spacer(minLength: 48)
            }
            Text(turn.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleFill(for: turn.speaker), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: bubbleWidth, alignment: turn.speaker == .agent ? .leading : .trailing)
            if turn.speaker == .agent {
                Spacer(minLength: 48)
            }
        }
    }

    private func bubbleFill(for speaker: ChatTurn.Speaker) -> Color {
        switch speaker {
        case .agent:
            Color.primary.opacity(0.06)
        case .person:
            Color.orange.opacity(0.18)
        }
    }

    private var starterJobs: some View {
        VStack(spacing: 10) {
            ForEach(FirstConversation.jobs) { job in
                Button {
                    controller.submit(job.prompt)
                } label: {
                    Text(job.title)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .pointerHover(in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(controller.isReplying)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Return sends and Shift Return starts a new line. The field
            // stays open while a reply comes, so a keyboard never loses its
            // place; sending waits until the reply is in.
            TextField(FirstConversation.composerPlaceholder, text: composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .submitLabel(.send)
                .accessibilityIdentifier("composer")
                // Keyboards are reported a moment after first asking, so ask early.
                .onAppear { _ = Self.shiftIsDown }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                // One send path per platform: the draft binding reads a lone
                // Return as Send on iOS, and onKeyPress handles it on the Mac.
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        addLine()
                        return .handled
                    }
                    controller.submit(controller.draft)
                    return .handled
                }
                #endif
            Button(FirstConversation.sendTitle) {
                controller.submit(controller.draft)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(controller.isReplying || controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    #if os(macOS)
    /// Shift Return on the Mac. The break goes at the end, where the cursor
    /// almost always is while writing.
    private func addLine() {
        controller.draft += "\n"
    }
    #endif

    /// True while Shift is held on a hardware keyboard.
    private static var shiftIsDown: Bool {
        #if os(iOS)
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keys.button(forKeyCode: .leftShift)?.isPressed == true
            || keys.button(forKeyCode: .rightShift)?.isPressed == true
        #else
        false
        #endif
    }

    /// The draft, with a lone Return read as Send. On iPad the field types
    /// Return and Shift Return alike as a line break, so the Shift key is
    /// checked here. See `ComposerReturn`.
    private var composerText: Binding<String> {
        Binding(
            get: { controller.draft },
            set: { new in
                if !Self.shiftIsDown, let text = ComposerReturn.textToSend(old: controller.draft, new: new) {
                    controller.draft = text
                    controller.submit(text)
                } else {
                    controller.draft = new
                }
            }
        )
    }
}

@MainActor
final class ChatController: ObservableObject {
    let brand: Brand
    private let model: any ModelClient
    private let names: any AgentNameStoring
    @Published private(set) var naming: AgentRenameState
    @Published var conversation: Conversation
    @Published var draft = ""
    @Published var isReplying = false
    private var replyTask: Task<Void, Never>?
    @Published var failure: String?

    init(brand: Brand, model: any ModelClient, names: any AgentNameStoring) {
        self.brand = brand
        self.model = model
        self.names = names
        let profile = AgentProfile(brand: brand, stored: names.loadDisplayName())
        naming = AgentRenameState(profile: profile)
        // The privacy line is decided once here. If the model can ever be
        // swapped, rebuild the opening so it never promises too much.
        conversation = .firstRun(named: profile.displayName.text, onDevice: model.runsOnDevice)
    }

    static func make(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
                     conversation: Conversation?) -> ChatController {
        let controller = ChatController(brand: brand, model: model, names: names)
        // A given conversation is used only when its privacy promise
        // matches the model; otherwise the honest opening stands.
        if let conversation, conversation.onDevice == model.runsOnDevice {
            controller.conversation = conversation
        }
        return controller
    }

    var displayName: AgentName { naming.profile.displayName }
    var renameTitle: String { naming.renameTitle }
    var isChoosingName: Bool { naming.isOpen }
    var showsNameInvitation: Bool { naming.showsInvitation }
    var nameDraft: String { naming.draft }
    var nameHint: String? { naming.hint }

    func beginRename() {
        var next = naming
        next.begin()
        naming = next
    }

    func cancelRename() {
        var next = naming
        next.cancel()
        naming = next
    }

    func setNameDraft(_ text: String) {
        var next = naming
        next.setDraft(text)
        naming = next
    }

    func commitName() {
        var next = naming
        guard let name = next.confirm() else {
            naming = next
            return
        }
        naming = next
        names.saveDisplayName(name.text)
        conversation = conversation.renamingAgent(to: name)
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        let clearsDraft = trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            conversation = try conversation.appendingPerson(trimmed)
        } catch {
            return
        }
        if clearsDraft {
            draft = ""
        }
        failure = nil
        isReplying = true
        let snapshot = conversation
        let client = model
        replyTask = Task {
            do {
                let answered = try await snapshot.appendingReply(from: client)
                if !Task.isCancelled { conversation = answered }
            } catch {
                if !Task.isCancelled { failure = FirstConversation.couldNotAnswer }
            }
            isReplying = false
        }
    }

    /// Stops a reply that is still coming, as when a new chat replaces this
    /// one. Nothing it would have said is added.
    func stopReplying() {
        replyTask?.cancel()
    }
}

struct AvatarView: View {
    let initial: String

    var body: some View {
        Circle()
            .fill(Color.orange.gradient)
            .frame(width: 88, height: 88)
            .overlay {
                Text(initial)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ChatView(brand: Brand(name: "Preview"), names: InMemoryAgentNameStore())
}
#else
public enum PebbleUISupport {
    public static let available = false
}
#endif
