import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
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
    /// True while another sheet, such as the shortcuts, covers the chat, so
    /// nothing here is spoken over it.
    private let covered: Bool
    private let onFirstMessageSent: () -> Void

    public init(
        brand: Brand,
        model: any ModelClient,
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
                    .padding(.top, Theme.Space.xxl)
                    .padding(.bottom, Theme.Space.l)
                    .readableColumn(columnWidth)
            }
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if headerScrolls {
                        header
                            .padding(.top, Theme.Space.s)
                            .padding(.bottom, Theme.Space.xs)
                    }
                    transcript
                    if let offer = controller.reconOffer {
                        ReconOfferButtons(question: controller.conversation.turns.first { $0.id == offer.turnID }?.text,
                                          onYes: { controller.acceptReconOffer() },
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
                .padding(.bottom, Theme.Space.s)
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
                .padding(.vertical, Theme.Space.m)
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
            Self.cameBack(controller)
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
        VStack(spacing: Theme.Space.xs) {
            if let look {
                CharacterView(look: look, size: 72)
            } else {
                AvatarView(initial: controller.displayName.initial)
            }
            Text(controller.displayName.text)
                .font(Theme.TypeScale.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(FirstConversation.presence(controller.privacyPlace))
                .font(Theme.TypeScale.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if controller.showsNameInvitation {
                Text(FirstConversation.nameInvitation)
                    .font(Theme.TypeScale.subheadline)
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
            VStack(spacing: Theme.Space.xs) {
                TextField(
                    FirstConversation.namePlaceholder,
                    text: Binding(
                        get: { controller.nameDraft },
                        set: { controller.setNameDraft($0) }
                    )
                )
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Color.primary.opacity(Theme.fieldTint), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .frame(maxWidth: 280)
                .focused($nameFieldFocused)
                .onAppear { nameFieldFocused = true }
                .onSubmit { controller.commitName() }
                if let nameHint = controller.nameHint {
                    Text(nameHint)
                        .font(Theme.TypeScale.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: Theme.Space.xs) {
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

    /// The person left the chat: back to Today, to another place, or to
    /// memory over it on the iPad. A reply that lands while they are away
    /// stays in the chat but isn't read aloud later, even when they come
    /// back to this same chat. One still on its way when they come back is
    /// read as it lands. A new send, from the chat or from Today, is heard
    /// as usual. This is decided, and the tests that start with "Leave"
    /// pin it.
    static func left(_ controller: ChatController) {
        controller.leftChat()
    }

    /// The person came back to the chat. A reply still on its way will land
    /// in front of them, so VoiceOver reads it as it lands, as a sighted
    /// person sees it. One that already landed while they were away is not
    /// read.
    static func cameBack(_ controller: ChatController) {
        controller.cameBack()
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
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
                Spacer(minLength: Theme.Space.xxxl)
            }
            Text(turn.text)
                .font(Theme.TypeScale.body)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(bubbleFill(for: turn.speaker), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .frame(maxWidth: bubbleWidth, alignment: turn.speaker == .agent ? .leading : .trailing)
            if turn.speaker == .agent {
                Spacer(minLength: Theme.Space.xxxl)
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(FirstConversation.startersHeading)
                .font(Theme.TypeScale.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Theme.Space.xxs)
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
            // person clears the words, or changes the ones given back, so
            // the line goes with them.
            if let failure, Self.pointsAtTheDraft(failure),
               !Self.stillHolds(returnedWords, draft: draft) {
                self.failure = nil
            }
        }
    }
    /// The words the last failed send put back in the composer, until its
    /// line goes.
    private(set) var returnedWords: String?
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
            // With no line, no words are held to it, so a later line is
            // never judged against stale ones.
            if failure == nil { returnedWords = nil }
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
    /// How many chat screens show this controller right now.
    private(set) var visibleChats = 0

    /// Goes up by one each time the person sends something by hand, from
    /// the chat or from Today. `SendTap` plays the light tap for it.
    @Published private(set) var sentCount = 0
    /// An offer to look into something, waiting for the person's tap.
    @Published private(set) var reconOffer: ReconOffer?
    /// Starts looking into a topic, after the person taps Look into it, and
    /// says what came of it: started, one already going or ready on Today
    /// (with the line to say), or nothing could start. Nil means this chat
    /// can't start one, so it never offers. The second value is this chat's
    /// model's place: when it stays on this device the recon keeps that
    /// promise, and a line about one already going says if it may not.
    var lookInto: ((_ topic: String, _ place: PrivacyPlace) -> ReconTap)?
    /// True while the only pages there are to read are examples, so the
    /// offer says so rather than promise real sources.
    var reconReadsExamples = false
    /// True while the chat's last line is the person's and no reply took
    /// it: the reply failed or was stopped. Only then are the same words
    /// sent again a retry rather than a new line.
    private var lastLineUnanswered = false
    /// The shortest time the thinking dots show, so a quick reply settles
    /// in after a calm beat instead of snapping onto the screen.
    let replyBeat: Duration
    /// How the beat is waited out. Always a real sleep in the app; tests
    /// pass one that writes down each wait, so whether a reply took the
    /// beat never rests on how fast the machine is.
    private let sleep: @Sendable (Duration) async -> Void
    /// Where a cloud chat shows its previews. Nil for a chat on this device.
    let review: CloudReview?

    init(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
         replyBeat: Duration = .milliseconds(600), review: CloudReview? = nil,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.brand = brand
        self.model = model
        self.names = names
        self.replyBeat = replyBeat
        self.sleep = sleep
        self.review = review
        let profile = AgentProfile(brand: brand, stored: names.loadDisplayName())
        naming = AgentRenameState(profile: profile)
        // The privacy line is decided once here, from this chat's model,
        // which it keeps for life. A new chat gets a new controller.
        conversation = .firstRun(named: profile.displayName.text, place: model.privacyPlace)
    }

    static func make(brand: Brand, model: any ModelClient, names: any AgentNameStoring,
                     conversation: Conversation?, review: CloudReview? = nil,
                     replyBeat: Duration = .milliseconds(600)) -> ChatController {
        let controller = ChatController(brand: brand, model: model, names: names, replyBeat: replyBeat,
                                        review: review)
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
        // Saying something else lets an old offer go.
        reconOffer = nil
        // Care comes first: only a message that gets no care reply can be
        // an offer, and the offer starts nothing until the person taps it.
        if lookInto != nil, !CareCheck.answersWithCare(conversation.turns),
           let topic = ReconIntent.topic(in: trimmed),
           let offered = try? conversation.appendingAgent(
               ReconWords.offer(topic, examples: reconReadsExamples, place: privacyPlace)) {
            conversation = offered
            reconOffer = ReconOffer(topic: topic, turnID: offered.turns.last?.id)
            unheardReply = offered.turns.last?.text
            return
        }
        isReplying = true
        replyGeneration += 1
        let generation = replyGeneration
        let snapshot = conversation
        let client = model
        let beat = replyBeat
        let sleep = sleep
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
            if !caring, waited < beat { await sleep(beat - waited) }
            // A reply that was stopped, or overtaken by a newer one, takes
            // nothing and changes nothing; only the newest reply settles.
            guard !Task.isCancelled, generation == replyGeneration else { return }
            // No reply means the person's line still waits for one.
            lastLineUnanswered = next == nil
            if let next {
                unheardReply = generation == leftGeneration ? nil
                    : next.turns.last.flatMap { $0.speaker == .agent ? $0.text : nil }
                conversation = next
            } else if let error, Self.nothingWasSent(error) {
                // Words that were not sent leave the conversation, so no
                // later request carries them. They go back to the composer,
                // ahead of anything typed since, which is never replaced.
                conversation = conversation.removingTurn(personID)
                // Gone from the chat, so sending them again adds them again.
                lastLineUnanswered = false
                returnedWords = trimmed
                draft = Self.draft(givingBack: trimmed, to: draft)
                failure = Self.failureLine(for: error)
            } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The failure line promises the words are back, ready to send.
                returnedWords = trimmed
                draft = trimmed
                failure = Self.failureLine(for: error)
            } else {
                // A newer draft is never replaced, so point at the bubble instead.
                failure = FirstConversation.couldNotAnswerKeptDraft
            }
            isReplying = false
        }
    }

    /// The person tapped Look into it. Starts it once, and says so. A chat
    /// that said it stays on this device keeps the recon here too. One
    /// already on that topic, from Today or another chat, isn't run twice.
    func acceptReconOffer() {
        guard let offer = reconOffer else { return }
        reconOffer = nil
        switch lookInto?(offer.topic, model.privacyPlace) ?? .couldNotStart {
        case .started: say(ReconWords.started)
        case .already(let line): say(line)
        case .couldNotStart: say(ReconWords.couldNotStart)
        }
    }

    /// Forget everything ran: the offer goes with no line said, so a tap
    /// can never start a recon on a topic from before it.
    func forgetReconOffer() {
        reconOffer = nil
    }

    /// The person tapped Not now. Nothing starts.
    func declineReconOffer() {
        guard reconOffer != nil else { return }
        reconOffer = nil
        say(ReconWords.offerDeclined)
    }

    /// Adds a line said on this device, waiting to be read aloud like any
    /// reply, so the answer to a tap is heard as well as seen.
    private func say(_ line: String) {
        guard let next = try? conversation.appendingAgent(line) else { return }
        unheardReply = next.turns.last?.text
        conversation = next
    }

    /// What to say when no reply came. Choosing not to send is not a failure.
    nonisolated static func failureLine(for error: Error?) -> String {
        if error as? MLXChatModelError == .tooLong { return OnDeviceModelWords.tooLong }
        if error as? MLXChatModelError == .interrupted { return OnDeviceModelWords.interrupted }
        return switch error as? CloudModelError {
        case .notSent: CloudWords.notSent
        // Taken away unanswered, so it never says the person chose.
        case .withdrawn: CloudWords.withdrawn
        case .off: CloudWords.turnedOff
        case .staysHere: CloudWords.staysHere
        case .notesUnreadable: CloudWords.notesUnreadable
        default: FirstConversation.couldNotAnswer
        }
    }

    /// True for a line that says the words are back in the composer, so it
    /// goes once the person clears them.
    nonisolated static func pointsAtTheDraft(_ failure: String) -> Bool {
        [FirstConversation.couldNotAnswer, CloudWords.notSent, CloudWords.withdrawn, CloudWords.turnedOff,
         CloudWords.notesUnreadable, OnDeviceModelWords.tooLong, OnDeviceModelWords.interrupted]
            .contains(failure)
    }

    /// True while the draft still starts with the words given back, whole,
    /// so a line that says they are still here is true. "Plan my week"
    /// still holds in "Plan my week, please" but not in "Plan my weekend".
    /// With no words given back, nothing holds.
    nonisolated static func stillHolds(_ words: String?, draft: String) -> Bool {
        guard let words, !words.isEmpty, draft.hasPrefix(words) else { return false }
        guard let next = draft.dropFirst(words.count).first, let last = words.last else { return true }
        return !(isWordCharacter(next) && isWordCharacter(last))
    }

    private nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
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
    /// after the bytes went, so the turn stays. A message too long for the
    /// on-device model was never read, so it goes back to be shortened.
    nonisolated static func nothingWasSent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error as? MLXChatModelError == .tooLong { return true }
        if error as? CloudTransportError == .headersNotShown { return true }
        return switch error as? CloudModelError {
        case .notSent, .withdrawn, .off, .staysHere, .notesUnreadable: true
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

    /// The reply nobody has heard yet, handed over once. Whoever takes it
    /// reads it aloud; nothing else clears it but a new send.
    func takeUnheardReply() -> String? {
        defer { unheardReply = nil }
        return unheardReply
    }

    /// A chat screen went off screen. Two can show this one controller at
    /// once, as when a size change swaps the layout, so the person has left
    /// only when the last one goes. The new screen may appear before the old
    /// one goes or just after, so the reply nobody heard is dropped only if
    /// no chat screen is back by the next pass of the main actor. One still
    /// coming lands quietly unless they come back first. A reply that lands
    /// while they are away stays in the chat but isn't read aloud later. A
    /// new send is heard as usual. Failures stay, since Today reads them
    /// above its own composer.
    func leftChat() {
        visibleChats = max(0, visibleChats - 1)
        guard visibleChats == 0 else { return }
        if isReplying { leftGeneration = replyGeneration }
        leaving?.cancel()
        // A send in between is new, and heard as usual.
        let generation = replyGeneration
        leaving = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, visibleChats == 0, generation == replyGeneration else { return }
            unheardReply = nil
        }
    }

    /// The check `leftChat` leaves for the next pass. Tests await it.
    private(set) var leaving: Task<Void, Never>?

    /// A chat screen is on screen again. A reply still coming is theirs to
    /// hear once more: it lands in front of them, so it is read like any other.
    func cameBack() {
        visibleChats += 1
        leftGeneration = nil
        leaving?.cancel()
        leaving = nil
    }

    /// The failure line nobody has heard yet, handed over once.
    func takeUnheardFailure() -> String? {
        defer { unheardFailure = nil }
        return unheardFailure
    }
}

/// What came of a tap on Look into it, as Today's runner decided it.
enum ReconTap: Equatable {
    case started
    /// One on that topic is already going or ready. The line says which.
    case already(String)
    case couldNotStart
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
    /// The offer as it was said, so focus waits until VoiceOver has read it.
    var question: String? = nil
    let onYes: () -> Void
    let onNo: () -> Void

    enum Choice: Hashable { case yes, no }

    /// Where VoiceOver goes once the question has been read, so a person who
    /// just heard it lands on its answers rather than hunting.
    static let arrivalFocus: Choice = .yes

    /// Where focus goes when VoiceOver finishes saying `finished`. Only
    /// once the question itself is done: moving focus sooner would cut it
    /// off, and the person would hear "Look into it" without the offer.
    /// Nil for any other line, so focus stays where the person left it.
    ///
    /// The announcement only has to hold the whole question, not equal it,
    /// so a line read with something before or after it, or with other
    /// spacing, still lands focus once the question is done.
    ///
    /// Only when it was read to the end: one cut off, as when the person
    /// swiped on, says it wasn't, and focus stays where they went.
    static func focusOnceRead(afterFinishing finished: String?, question: String?,
                              wasSuccessful: Bool?) -> Choice? {
        guard wasSuccessful == true, let finished = finished.map(tidy), let question = question.map(tidy),
              !question.isEmpty, finished.contains(question) else { return nil }
        return arrivalFocus
    }

    /// Spacing and case set aside, so only the words count.
    private static func tidy(_ line: String) -> String {
        line.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").lowercased()
    }

    /// What VoiceOver says each choice does.
    static func hint(_ choice: Choice) -> String {
        switch choice {
        case .yes: ReconWords.offerYesHint
        case .no: ReconWords.offerNoHint
        }
    }

    @AccessibilityFocusState private var focus: Choice?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xs) { buttons }
            VStack(alignment: .leading, spacing: Theme.Space.xs) { buttons }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconOffer")
        #if os(iOS)
        // Only after VoiceOver has finished reading the question. On the Mac
        // there is no such signal, so focus is left alone and the buttons
        // come next when the person moves on.
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) { note in
            let finished = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            let read = (note.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? NSNumber)?.boolValue
            if let choice = Self.focusOnceRead(afterFinishing: finished, question: question, wasSuccessful: read) {
                focus = choice
            }
        }
        #endif
    }

    @ViewBuilder
    private var buttons: some View {
        Button(ReconWords.offerYes, action: onYes)
            .buttonStyle(CardButtonStyle(kind: .primary))
            .accessibilityHint(Self.hint(.yes))
            .accessibilityFocused($focus, equals: .yes)
            .accessibilityIdentifier("reconOfferYes")
        Button(ReconWords.offerNo, action: onNo)
            .buttonStyle(CardButtonStyle(kind: .quiet))
            .accessibilityHint(Self.hint(.no))
            .accessibilityFocused($focus, equals: .no)
            .accessibilityIdentifier("reconOfferNo")
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
                .font(Theme.TypeScale.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.accent.opacity(Theme.accentWash), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .pointerHover(in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
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
                    .font(Theme.TypeScale.avatarInitial)
                    .foregroundStyle(Theme.onAccent)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ChatView(brand: Brand(name: "Preview"), model: LocalStubModel(), names: InMemoryAgentNameStore())
}
#else
public enum PebbleUISupport {
    public static let available = false
}
#endif
