import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

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
    /// True while another sheet, such as the shortcuts, covers the chat, so
    /// nothing here is spoken over it.
    private let covered: Bool
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
        covered: Bool = false,
        onFirstMessageSent: @escaping () -> Void = {}
    ) {
        _controller = StateObject(wrappedValue: controller())
        self.look = look
        self.firstMessage = firstMessage
        self.covered = covered
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
                    Self.scrollToLatest(controller.conversation, with: scroller, animated: false)
                }
            }
            .onChange(of: controller.conversation.turns.count) {
                Self.scrollToLatest(controller.conversation, with: scroller, animated: !reduceMotion)
                if let line = Self.replyLanded(in: controller, covered: covered) {
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
                if Self.speaks(covered: covered) { sayThinkingSoon() }
                if reduceMotion {
                    scroller.scrollTo(Self.thinkingID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(Self.thinkingID, anchor: .bottom) }
                }
            }
            .onChange(of: controller.failure) {
                if let line = Self.failureLanded(in: controller, covered: covered) {
                    AccessibilityNotification.Announcement(line).post()
                }
            }
            .onChange(of: covered) { _, covered in
                // A sheet came over the chat, so a pending "thinking" stays
                // quiet. When it goes, a reply or a failure that landed under
                // it is read once, or "thinking" follows a reply still coming.
                thinkingNotice?.cancel()
                thinkingNotice = nil
                speak(Self.arrival(for: controller, covered: covered))
            }
            }
            composer
                .padding(.vertical, 16)
                .readableColumn(columnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85),
                   value: controller.conversation.turns.count)
        // The send's tap is played by `SendTap` around the whole home
        // screen, so it is felt whichever screen sent it.
        .onAppear {
            // Sent from Today, the line may be answered, or still on its
            // way, before this screen was here to see it change.
            speak(Self.arrival(for: controller, covered: covered))
        }
        .onDisappear {
            // Never say "thinking" over another screen.
            thinkingNotice?.cancel()
            thinkingNotice = nil
            Self.left(controller)
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
            Text(FirstConversation.presence(controller.privacyPlace))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if controller.showsNameInvitation {
                Text(FirstConversation.nameInvitation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
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
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    Button(FirstConversation.cancelNameTitle) {
                        controller.cancelRename()
                    }
                    .buttonStyle(SoftButtonStyle(neutral: true))
                    Button(FirstConversation.confirmNameTitle) {
                        controller.commitName()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(controller.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            Button(controller.renameTitle) {
                controller.beginRename()
            }
            .buttonStyle(SoftButtonStyle())
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

    /// Says "thinking" once, a beat after the dots appear, unless the reply
    /// lands first.
    private func sayThinkingSoon() {
        thinkingNotice?.cancel()
        thinkingNotice = Task { @MainActor in
            try? await Task.sleep(for: Self.thinkingNoticeDelay(after: controller.replyBeat))
            guard !Task.isCancelled, controller.isReplying else { return }
            AccessibilityNotification.Announcement(FirstConversation.thinking).post()
        }
    }

    private func speak(_ arrival: Arrival) {
        switch arrival {
        case .reply(let line), .failure(let line): AccessibilityNotification.Announcement(line).post()
        case .thinking: sayThinkingSoon()
        case .nothing: break
        }
    }

    /// What the chat says as it comes on screen, or as a sheet over it goes.
    enum Arrival: Equatable {
        case nothing
        /// A reply that landed while no chat could speak it.
        case reply(String)
        /// A failure line that landed while no chat could speak it.
        case failure(String)
        /// A reply still on its way, so "thinking" follows as usual.
        case thinking
    }

    /// A line sent from Today may be answered, or still coming, before the
    /// chat opens, and then the chat never sees the change it speaks on.
    /// So it looks as it arrives, and again each time a sheet over it goes.
    /// The one rule: while covered, nothing is taken; once uncovered, what
    /// nobody heard is taken and read, once.
    static func arrival(for controller: ChatController, covered: Bool) -> Arrival {
        guard speaks(covered: covered) else { return .nothing }
        if controller.isReplying { return .thinking }
        if let reply = controller.takeUnheardReply() { return .reply(reply) }
        if let failure = controller.takeUnheardFailure() { return .failure(failure) }
        return .nothing
    }

    /// The person left the chat, back to Today or another place. A reply
    /// they walked away from stays in the chat but is never read aloud
    /// later, when they come back for something else: the one unheard now
    /// is dropped, and so is the one still on its way.
    static func left(_ controller: ChatController) {
        controller.leftChat()
    }

    /// Where the thinking dots sit, so the chat can follow them.
    static let thinkingID = "thinking"

    /// How long the dots show before VoiceOver hears "thinking". It waits
    /// past the reply beat, so a reply that lands on the beat is read on its
    /// own and only a slow one is announced.
    static func thinkingNoticeDelay(after beat: Duration) -> Duration {
        beat + .milliseconds(400)
    }

    /// "Thinking it over.", the failure line and a new reply are spoken only
    /// while the chat is in front. Another sheet over it means quiet.
    static func speaks(covered: Bool) -> Bool { !covered }

    /// A new turn landed in the chat. What is spoken is only ever what
    /// `takeUnheardReply` hands over, so a reply is read exactly once
    /// however the turn, the cover and the screen change. Covered, nothing
    /// is taken, and the reply waits for the sheet to go.
    static func replyLanded(in controller: ChatController, covered: Bool) -> String? {
        speaks(covered: covered) ? controller.takeUnheardReply() : nil
    }

    /// The failure line changed. Spoken the same way as a reply: taken only
    /// when the chat can speak, so one that lands under a sheet waits.
    static func failureLanded(in controller: ChatController, covered: Bool) -> String? {
        speaks(covered: covered) ? controller.takeUnheardFailure() : nil
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
            Color.primary.opacity(Theme.bubbleTint)
        case .person:
            Theme.accent.opacity(Theme.personBubbleWash)
        }
    }

    /// The new chat's empty state: a few things to start with, so it never
    /// opens on a blank page.
    private var starterJobs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FirstConversation.startersHeading)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
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
        Composer(draft: $controller.draft, isBusy: controller.isReplying, keyboardSends: sendsFromKeyboard) {
            controller.send($0)
        }
    }
}

@MainActor
final class ChatController: ObservableObject {
    let brand: Brand
    private let model: any ModelClient
    private let names: any AgentNameStoring
    @Published private(set) var naming: AgentRenameState
    @Published var conversation: Conversation
    @Published var draft = "" {
        didSet {
            // "What you wrote is still here" stops being true once the
            // person clears the words, so the line goes with them.
            if failure == FirstConversation.couldNotAnswer,
               draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failure = nil
            }
        }
    }
    @Published var isReplying = false
    /// The reply on its way. Tests await it so ordering never rests on timing.
    private(set) var replyTask: Task<Void, Never>?
    /// Goes up with each reply asked for and each stop, so a late reply
    /// can tell it is no longer the current one.
    private var replyGeneration = 0
    @Published var failure: String? {
        didSet {
            // A new line is waiting to be heard; a line that went was never
            // heard and now never will be.
            if failure != oldValue { unheardFailure = failure }
        }
    }
    /// The newest reply, until it has been read aloud. A line sent from
    /// Today can be answered before the chat has opened, or while a sheet
    /// covers it, so it waits here and is read once, by whichever screen
    /// can speak first. Only `takeUnheardReply` reads it, and that clears it.
    private(set) var unheardReply: String?
    /// The failure line, until it has been read aloud, the same way: it can
    /// land under a sheet, or while Today is behind the chat.
    private(set) var unheardFailure: String?
    /// The reply the person left the chat while waiting for. It is kept in
    /// the chat when it lands, but never waits to be heard.
    private var leftGeneration: Int?

    /// Goes up by one each time the person sends something by hand, from
    /// the chat or from Today. `SendTap` plays the light tap for it.
    @Published private(set) var sentCount = 0
    /// True while the chat's last line is the person's and no reply took
    /// it: the reply failed or was stopped. Only then are the same words
    /// sent again a retry rather than a new line.
    private var lastLineUnanswered = false
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
        conversation = .firstRun(named: profile.displayName.text, place: model.privacyPlace)
    }

    static func make(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
                     conversation: Conversation?) -> ChatController {
        let controller = ChatController(brand: brand, model: model, names: names)
        // A given conversation is used only when its privacy promise
        // matches the model; otherwise the honest opening stands.
        if let conversation, conversation.place == model.privacyPlace {
            controller.conversation = conversation
        }
        return controller
    }

    /// Whether the chat may promise the device, from the model it talks to.
    var privacyPlace: PrivacyPlace { model.privacyPlace }

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

    /// What both composers call, in the chat and on Today: the same care
    /// check, the same conversation and the same rules either way. True
    /// when the line went out, false when there was nothing to send or a
    /// reply was still coming.
    @discardableResult
    func send(_ text: String) -> Bool {
        let before = sentCount
        submit(text)
        return sentCount != before
    }

    /// Sends `text`. `byHand` is false for the line the first run sends on
    /// its own, which gets no tap since the person didn't just press anything.
    func submit(_ text: String, byHand: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReplying else { return }
        let clearsDraft = trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same words sent again after their reply failed or was stopped
        // are already the last line of the chat, so they are asked again,
        // not added twice. Said again after an answer, they are a new line.
        let isRetry = lastLineUnanswered
            && (conversation.turns.last.map { $0.speaker == .person && $0.text == trimmed } ?? false)
        if !isRetry {
            do {
                conversation = try conversation.appendingPerson(trimmed)
            } catch {
                return
            }
        }
        lastLineUnanswered = false
        if clearsDraft {
            draft = ""
        }
        if byHand { sentCount += 1 }
        failure = nil
        unheardReply = nil
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
            do {
                next = try await snapshot.appendingReply(from: client)
            } catch {
                next = nil
            }
            let waited = ContinuousClock.now - started
            if !caring, waited < beat { try? await Task.sleep(for: beat - waited) }
            // A reply that was stopped, or overtaken by a newer one, takes
            // nothing and changes nothing; only the newest reply settles.
            guard !Task.isCancelled, generation == replyGeneration else { return }
            // No reply means the person's line still waits for one.
            lastLineUnanswered = next == nil
            if let next {
                unheardReply = generation == leftGeneration ? nil
                    : next.turns.last.flatMap { $0.speaker == .agent ? $0.text : nil }
                conversation = next
            } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The failure line promises the words are back, ready to send.
                draft = trimmed
                failure = FirstConversation.couldNotAnswer
            } else {
                // A newer draft is never replaced, so point at the bubble instead.
                failure = FirstConversation.couldNotAnswerKeptDraft
            }
            isReplying = false
        }
    }

    /// Stops a reply that is still coming, as when a new chat replaces this
    /// one. Nothing it would have said is added.
    func stopReplying() {
        if isReplying { lastLineUnanswered = true }
        replyTask?.cancel()
        replyTask = nil
        replyGeneration += 1
        isReplying = false
    }

    /// The reply nobody has heard yet, handed over once. Whoever takes it
    /// reads it aloud; nothing else clears it but a new send.
    func takeUnheardReply() -> String? {
        defer { unheardReply = nil }
        return unheardReply
    }

    /// The chat went off screen. The reply nobody heard is dropped, and one
    /// still coming lands quietly. A new send is heard as usual. Failures
    /// stay, since Today reads them above its own composer.
    func leftChat() {
        unheardReply = nil
        if isReplying { leftGeneration = replyGeneration }
    }

    /// The failure line nobody has heard yet, handed over once.
    func takeUnheardFailure() -> String? {
        defer { unheardFailure = nil }
        return unheardFailure
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

    /// What appearing does: the chip always lands, and plays its entrance
    /// only when it isn't showing yet. Landing even when Reduce Motion
    /// already shows it means turning Reduce Motion off later never leaves
    /// the chip invisible.
    static func appearing(arrived: Bool, reduceMotion: Bool, animatesEntrances: Bool) -> (arrived: Bool, animates: Bool) {
        (true, !isShown(arrived: arrived, reduceMotion: reduceMotion, animatesEntrances: animatesEntrances))
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
                .background(Theme.accent.opacity(Theme.accentWash), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .pointerHover(in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(SoftPressStyle())
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : Motion.entranceOffset(reduceMotion: reduceMotion))
        .onAppear {
            let step = Self.appearing(arrived: arrived, reduceMotion: reduceMotion, animatesEntrances: animatesEntrances)
            guard step.animates else {
                arrived = step.arrived
                return
            }
            let delay = Motion.stagger(index, reduceMotion: reduceMotion)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) {
                arrived = step.arrived
            }
        }
    }
}

struct AvatarView: View {
    let initial: String

    var body: some View {
        Circle()
            .fill(Theme.accent.gradient)
            .frame(width: 88, height: 88)
            .overlay {
                Text(initial)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.onAccent)
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
