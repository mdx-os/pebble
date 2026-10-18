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
    @Environment(\.sendsFromKeyboard) private var sendsFromKeyboard
    /// The pending "thinking" announcement, cancelled if the reply lands first.
    @State private var thinkingNotice: Task<Void, Never>?
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
                    if controller.reconOffer != nil {
                        ReconOfferButtons(onYes: { controller.acceptReconOffer() },
                                          onNo: { controller.declineReconOffer() })
                            .id(Self.offerID)
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if controller.conversation.isWaitingForPerson {
                        starterJobs
                    }
                    if controller.isReplying {
                        ThinkingDots()
                            .id(Self.thinkingID)
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if let failure = controller.failure {
                        GentleNotice(text: failure)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                .readableColumn(columnWidth)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85),
                           value: controller.isReplying)
            }
            .onAppear {
                // Wait one pass so layout is done before jumping to the end.
                DispatchQueue.main.async {
                    Self.scrollToLatest(controller, with: scroller, animated: false)
                }
            }
            .onChange(of: controller.conversation.turns.count) {
                Self.scrollToLatest(controller, with: scroller, animated: !reduceMotion)
                if let line = Self.announcement(for: controller.conversation) {
                    AccessibilityNotification.Announcement(line).post()
                }
            }
            .onChange(of: controller.isReplying) { _, replying in
                // Say "thinking" once, a moment after the dots appear, and
                // keep them in view. A reply that lands first, care words
                // above all, is never talked over.
                thinkingNotice?.cancel()
                thinkingNotice = nil
                guard replying else { return }
                thinkingNotice = Task { @MainActor in
                    try? await Task.sleep(for: Self.thinkingNoticeDelay(after: controller.replyBeat))
                    guard !Task.isCancelled, controller.isReplying else { return }
                    AccessibilityNotification.Announcement(FirstConversation.thinking).post()
                }
                if reduceMotion {
                    scroller.scrollTo(Self.thinkingID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(Self.thinkingID, anchor: .bottom) }
                }
            }
            .onChange(of: controller.failure) { _, failure in
                if let failure { AccessibilityNotification.Announcement(failure).post() }
            }
            }
            composer
                .padding(.vertical, 16)
                .readableColumn(columnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85),
                   value: controller.conversation.turns.count)
        .haptic(.sent, trigger: controller.sentCount)
        .onDisappear {
            // Never say "thinking" over another screen.
            thinkingNotice?.cancel()
            thinkingNotice = nil
        }
        .task {
            if let firstMessage, controller.conversation.isWaitingForPerson {
                controller.submit(firstMessage, byHand: false)
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
            Text(controller.presence)
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
    /// An offer's buttons sit under its line, so they come into view too.
    private static func scrollToLatest(_ controller: ChatController, with scroller: ScrollViewProxy, animated: Bool) {
        let target: AnyHashable
        if controller.reconOffer != nil {
            target = offerID
        } else if let last = controller.conversation.turns.last?.id {
            target = last
        } else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(target, anchor: .bottom) }
        } else {
            scroller.scrollTo(target, anchor: .bottom)
        }
    }

    /// Where an offer's buttons sit, so the chat can follow them.
    static let offerID = "reconOffer"

    /// Where the thinking dots sit, so the chat can follow them.
    static let thinkingID = "thinking"

    /// How long the dots show before VoiceOver hears "thinking". It waits
    /// past the reply beat, so a reply that lands on the beat is read on its
    /// own and only a slow one is announced.
    static func thinkingNoticeDelay(after beat: Duration) -> Duration {
        beat + .milliseconds(400)
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
                    .transition(Motion.arrival(reduceMotion: reduceMotion))
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

    /// The new chat's empty state: a few things to start with, so it never
    /// opens on a blank page.
    private var starterJobs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FirstConversation.startersHeading)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 4)
            ForEach(Array(FirstConversation.jobs.enumerated()), id: \.element.id) { index, job in
                StarterChip(title: job.title, index: index) {
                    controller.submit(job.prompt)
                }
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
            .keyboardShortcut(sendsFromKeyboard ? KeyboardShortcut(.return, modifiers: .command) : nil)
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
    /// Goes up with each reply asked for and each stop, so a late reply
    /// can tell it is no longer the current one.
    private var replyGeneration = 0
    @Published var failure: String?
    /// Goes up by one each time the person sends something.
    @Published private(set) var sentCount = 0
    /// An offer to look into something, waiting for the person's tap.
    @Published private(set) var reconOffer: ReconOffer?
    /// Starts looking into a topic, after the person taps Look into it.
    /// Returns false when nothing started. Nil means this chat can't start
    /// one, so it never offers. The second value is true when this chat
    /// promised to stay on this device, so the recon keeps that promise.
    var lookInto: ((_ topic: String, _ onDevice: Bool) -> Bool)?
    /// True while the only pages there are to read are examples, so the
    /// offer says so rather than promise real sources.
    var reconReadsExamples = false
    /// The shortest time the thinking dots show, so a quick reply settles
    /// in after a calm beat instead of snapping onto the screen.
    let replyBeat: Duration

    init(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
         replyBeat: Duration = .milliseconds(600)) {
        self.brand = brand
        self.model = model
        self.names = names
        self.replyBeat = replyBeat
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

    /// Sends `text`. `byHand` is false for the line the first run sends on
    /// its own, which gets no tap since the person didn't just press anything.
    func submit(_ text: String, byHand: Bool = true) {
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
        if byHand { sentCount += 1 }
        failure = nil
        // Saying something else lets an old offer go.
        reconOffer = nil
        // Care comes first: only a message that gets no care reply can be
        // an offer, and the offer starts nothing until the person taps it.
        if lookInto != nil, !CareCheck.answersWithCare(conversation.turns),
           let topic = ReconIntent.topic(in: trimmed),
           let offered = try? conversation.appendingAgent(ReconWords.offer(topic, examples: reconReadsExamples)) {
            conversation = offered
            reconOffer = ReconOffer(topic: topic, turnID: offered.turns.last?.id)
            return
        }
        isReplying = true
        replyGeneration += 1
        let generation = replyGeneration
        let snapshot = conversation
        let client = model
        let beat = replyBeat
        // Words of care are never held back, not even for a beat. Decided
        // from the turns, the same way the reply itself is chosen.
        let caring = CareCheck.answersWithCare(snapshot.turns)
        replyTask = Task {
            let started = ContinuousClock.now
            let next: Conversation?
            var failure = FirstConversation.couldNotAnswer
            do {
                next = try await snapshot.appendingReply(from: client)
            } catch {
                next = nil
                failure = Self.failureLine(for: error)
            }
            let waited = ContinuousClock.now - started
            if !caring, waited < beat { try? await Task.sleep(for: beat - waited) }
            // A reply that was stopped, or overtaken by a newer one, takes
            // nothing and changes nothing; only the newest reply settles.
            guard !Task.isCancelled, generation == replyGeneration else { return }
            if let next {
                conversation = next
            } else {
                self.failure = failure
                // The failure line promises the words are still here to send.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = trimmed }
            }
            isReplying = false
        }
    }

    /// The line under the name. "On this device" only when it is true.
    var presence: String {
        model.runsOnDevice ? FirstConversation.presence : CloudWords.presence
    }

    /// What to say when no reply came. Choosing not to send is not a failure.
    nonisolated static func failureLine(for error: Error) -> String {
        switch error as? CloudModelError {
        case .notSent: CloudWords.notSent
        case .off: CloudWords.turnedOff
        default: FirstConversation.couldNotAnswer
        }
    }

    /// The person tapped Look into it. Starts it once, and says so. A chat
    /// that said it stays on this device keeps the recon here too.
    func acceptReconOffer() {
        guard let offer = reconOffer else { return }
        reconOffer = nil
        let started = lookInto?(offer.topic, model.runsOnDevice) ?? false
        if let next = try? conversation.appendingAgent(started ? ReconWords.started : ReconWords.couldNotStart) {
            conversation = next
        }
    }

    /// The person tapped Not now. Nothing starts.
    func declineReconOffer() {
        guard reconOffer != nil else { return }
        reconOffer = nil
        if let next = try? conversation.appendingAgent(ReconWords.offerDeclined) {
            conversation = next
        }
    }

    /// Stops a reply that is still coming, as when a new chat replaces this
    /// one. Nothing it would have said is added.
    func stopReplying() {
        replyTask?.cancel()
        replyTask = nil
        replyGeneration += 1
        isReplying = false
    }
}

/// An offer in the chat to look into something.
struct ReconOffer: Equatable {
    let topic: String
    /// The agent's line that made the offer.
    let turnID: UUID?
}

/// The two choices under an offer to look into something. Nothing starts
/// until Look into it is tapped.
struct ReconOfferButtons: View {
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconOffer")
    }

    @ViewBuilder
    private var buttons: some View {
        Button(ReconWords.offerYes, action: onYes)
            .buttonStyle(CardButtonStyle(kind: .primary))
            .accessibilityIdentifier("reconOfferYes")
        Button(ReconWords.offerNo, action: onNo)
            .buttonStyle(CardButtonStyle(kind: .quiet))
    }
}

/// One starter in a new chat. The chips arrive one after another and give
/// a little under a press.
struct StarterChip: View {
    let title: String
    let index: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animatesEntrances) private var animatesEntrances
    @State private var arrived = false

    /// Shown from the start with Reduce Motion or in a still picture, so a
    /// render or preview never catches the chips before they arrive.
    static func isShown(arrived: Bool, reduceMotion: Bool, animatesEntrances: Bool) -> Bool {
        arrived || reduceMotion || !animatesEntrances
    }

    private var shown: Bool {
        Self.isShown(arrived: arrived, reduceMotion: reduceMotion, animatesEntrances: animatesEntrances)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .pointerHover(in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(SoftPressStyle())
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : Motion.entranceOffset(reduceMotion: reduceMotion))
        .onAppear {
            guard !shown else { return }
            let delay = Motion.stagger(index, reduceMotion: reduceMotion)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) {
                arrived = true
            }
        }
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
