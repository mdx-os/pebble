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
            if let failure, Self.pointsAtTheDraft(failure),
               draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.failure = nil
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
    /// Where a cloud chat shows its previews. Nil for a chat on this device.
    let review: CloudReview?

    init(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
         replyBeat: Duration = .milliseconds(600), review: CloudReview? = nil) {
        self.brand = brand
        self.model = model
        self.names = names
        self.replyBeat = replyBeat
        self.review = review
        let profile = AgentProfile(brand: brand, stored: names.loadDisplayName())
        naming = AgentRenameState(profile: profile)
        // The privacy line is decided once here, from this chat's model,
        // which it keeps for life. A new chat gets a new controller.
        conversation = .firstRun(named: profile.displayName.text, onDevice: model.privacyPlace.staysOnDevice)
    }

    static func make(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
                     conversation: Conversation?, review: CloudReview? = nil,
                     replyBeat: Duration = .milliseconds(600)) -> ChatController {
        let controller = ChatController(brand: brand, model: model, names: names, replyBeat: replyBeat,
                                        review: review)
        // A given conversation is used only when its privacy promise
        // matches the model; otherwise the honest opening stands.
        if let conversation, conversation.onDevice == model.runsOnDevice {
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
        // The line this send asks about, so words that were never sent can
        // leave the chat again: the one already there on a retry.
        let personID: UUID
        if isRetry, let last = conversation.turns.last {
            personID = last.id
        } else {
            personID = UUID()
            do {
                conversation = try conversation.appendingPerson(trimmed, id: personID)
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
            var error: Error?
            do {
                next = try await snapshot.appendingReply(from: client)
            } catch let thrown {
                next = nil
                error = thrown
            }
            let waited = ContinuousClock.now - started
            if !caring, waited < beat { try? await Task.sleep(for: beat - waited) }
            // A reply that was stopped, overtaken by a newer one, or left in
            // a chat that ended takes nothing and changes nothing: no words
            // go back to the draft and no failure is set. Only the newest
            // reply in an open chat settles.
            guard !Task.isCancelled, !hasEnded, generation == replyGeneration else { return }
            // No reply means the person's line still waits for one.
            lastLineUnanswered = next == nil
            if let next {
                unheardReply = next.turns.last.flatMap { $0.speaker == .agent ? $0.text : nil }
                conversation = next
            } else if let error, Self.nothingWasSent(error) {
                // Words that were not sent leave the conversation, so no
                // later request carries them. They go back to the composer,
                // ahead of anything typed since, which is never replaced.
                conversation = conversation.removingTurn(personID)
                // Gone from the chat, so sending them again adds them again.
                lastLineUnanswered = false
                draft = Self.draft(givingBack: trimmed, to: draft)
                failure = Self.failureLine(for: error)
            } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The failure line promises the words are back, ready to send.
                draft = trimmed
                failure = Self.failureLine(for: error)
            } else {
                // A newer draft is never replaced, so point at the bubble instead.
                failure = FirstConversation.couldNotAnswerKeptDraft
            }
            isReplying = false
        }
    }

    /// What to say when no reply came. Choosing not to send is not a failure.
    nonisolated static func failureLine(for error: Error?) -> String {
        switch error as? CloudTransportError {
        case .signInBodyRefused?, .signInHeaderRefused?, .signInCarriesPersonalDetails?:
            return CloudWords.signInRefused
        default: break
        }
        return switch error as? CloudModelError {
        case .notSent: CloudWords.notSent
        case .off: CloudWords.turnedOff
        case .staysHere: CloudWords.staysHere
        case .notesUnreadable: CloudWords.notesUnreadable
        case .ended: CloudWords.chatEnded
        case .needsSignIn: CloudWords.needsSignIn
        case .signInFirst: CloudWords.signInFirst
        case .noToken: CloudWords.noToken
        case .noSession: CloudWords.noSession
        case .oldKeyStayed: CloudWords.oldKeyStayed
        default: FirstConversation.couldNotAnswer
        }
    }

    /// True for a line that says the words are back in the composer, so it
    /// goes once the person clears them.
    ///
    /// `staysHere`, `turnedOff`, `chatEnded`, `needsSignIn` and
    /// `signInFirst` give the words back too, but they are about the chat
    /// or the build, not the draft: clearing the words doesn't make "part
    /// of this chat has to stay here" or "the cloud is off" any less true,
    /// so those lines stay until the next send or a new chat.
    nonisolated static func pointsAtTheDraft(_ failure: String) -> Bool {
        [FirstConversation.couldNotAnswer, CloudWords.notSent, CloudWords.notesUnreadable,
         CloudWords.noSession, CloudWords.oldKeyStayed, CloudWords.noToken].contains(failure)
    }

    /// The words that weren't sent, back in the composer. Anything typed
    /// since is kept after them, never replaced.
    nonisolated static func draft(givingBack words: String, to draft: String) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? words : words + "\n" + draft
    }

    /// True when the reply stopped before anything left the device: the
    /// person said no, the setting was off, the chat must stay here, the
    /// notes couldn't be read, the transport refused a request whose
    /// labels weren't the ones shown, or the reply was cancelled before it
    /// reached the transport. `CloudModel` throws `CancellationError` only
    /// from its own check right after the yes, before the transport is
    /// called; URLSession reports a send cut short as a `URLError`, which
    /// is not counted here. Any other transport failure may have come
    /// after the bytes went, so the turn stays.
    nonisolated static func nothingWasSent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        // Refused before sending: labels that weren't shown, an address
        // that isn't https, a reserved label, or a sign-in path, body,
        // header or value that may carry more than a credential or go other
        // than shown. Each case is named, so a new one, which may come
        // after the bytes left, must be decided here.
        if let refused = error as? CloudTransportError {
            return switch refused {
            case .headersNotShown, .notSecure, .reservedHeader, .signInPathRefused, .signInBodyRefused,
                 .signInHeaderRefused, .signInCarriesPersonalDetails: true
            }
        }
        // Without a session or a sign-in, and with an old key kept, nothing
        // went. With no session after signing in, only the sign-in went,
        // which carries nothing of the chat, and the message stayed here.
        // With no token after a token ask, only the ask went, the same way.
        return switch error as? CloudModelError {
        case .notSent, .off, .staysHere, .notesUnreadable, .ended, .needsSignIn, .signInFirst, .noToken, .noSession,
             .oldKeyStayed: true
        case .unreadableReply, nil: false
        }
    }

    /// The home screen went away. A preview still waiting for an answer is
    /// not sent, so the reply never hangs on a sheet no one can see.
    func screenWentAway() {
        review?.cancelPending()
    }

    /// Waits for the current reply to settle, with no timing involved. For tests.
    func settled() async {
        await replyTask?.value
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

    /// True once Forget everything has ended this chat.
    private(set) var hasEnded = false

    /// The cloud chat's session, for a chat on the cloud model.
    var cloudSession: CloudChatSession? { (model as? CloudModel)?.session }

    /// True when ending the chat would let go of something: words the
    /// person said, a reply or preview under way, or anything it hid.
    var holdsAnything: Bool {
        conversation.turns.contains { $0.speaker == .person } || isReplying || review?.pending != nil
            || cloudSession?.holdsAnything == true
    }
    /// Told when the chat ends, so the screen holding it can start a fresh one.
    var onEnded: (@MainActor () -> Void)?

    /// Ends the chat, as Forget everything does with every open cloud chat:
    /// the reply under way stops, a waiting preview closes unsent, any send
    /// on the wire is cancelled, and the chat lets go of its turns, its
    /// draft (shared with Today's composer, and maybe holding a word being
    /// erased) and everything it hid so far. Nothing more is sent from it.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        stopReplying()
        review?.cancelPending()
        cloudSession?.end()
        conversation = .firstRun(named: displayName.text, onDevice: model.privacyPlace.staysOnDevice)
        draft = ""
        lastLineUnanswered = false
        failure = nil
        unheardReply = nil
        onEnded?()
    }

    /// The reply nobody has heard yet, handed over once. Whoever takes it
    /// reads it aloud; nothing else clears it but a new send.
    func takeUnheardReply() -> String? {
        defer { unheardReply = nil }
        return unheardReply
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
