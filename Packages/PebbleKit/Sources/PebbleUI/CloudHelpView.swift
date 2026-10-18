import Foundation
import PebbleCore
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI

/// The person's cloud setting, and the model each new chat gets from it.
///
/// Off by default. While it is off, or while there is no address to reach,
/// every chat gets the on-device model and no cloud code runs: the
/// transport is only made when a chat is started with the setting on.
@MainActor
public final class CloudHelp: ObservableObject {
    @Published public private(set) var settings: CloudHelpSettings
    /// The turn on question is showing.
    @Published var asksToTurnOn = false
    @Published var newPrivateWord = ""
    /// What to say about the last change that couldn't be made. Every new
    /// line, even one the same as before, bumps statusCount so it is spoken
    /// again.
    @Published private(set) var status: String? {
        didSet { if status != nil { statusCount += 1 } }
    }
    @Published private(set) var statusCount = 0
    /// The flag the setting's own words read, the same one every line
    /// outside a chat reads. `HomeView` works it out from the open chat's
    /// model and the next one's (see `PrivacyPlace`) and keeps this up to
    /// date. Until then it makes no promise.
    @Published var place: PrivacyPlace = .mayLeaveDevice

    public let endpoint: URL?
    /// False when the file that keeps the setting and the private words
    /// couldn't be opened at launch. Nothing typed here could be kept, so
    /// the setting stays off and says so.
    public let storeOpened: Bool
    /// The same store the memory screen uses, so the redactor always reads
    /// the notes as they are now.
    let memory: MemoryStore?
    private let store: any CloudHelpStoring
    private let auth: any CloudAuth
    private let makeTransport: @Sendable () -> any CloudTransport
    /// The file a setting that couldn't be opened would have read.
    private let unopenedFile: (@Sendable () throws -> any CloudHelpStoring)?
    /// Every chat's preview gate, so turning the cloud off closes them all.
    private let reviews = NSHashTable<CloudReview>.weakObjects()
    /// How many chats have asked for a model, so tests can see that a
    /// rebuilt home screen asks for none.
    private(set) var chatModelsAsked = 0
    /// Sign-in after the person's yes. Tests wait on it. Cancelled when the
    /// cloud goes off, so a sign-in under way never finishes after that.
    private(set) var signingIn: Task<Void, Never>?
    /// Set when the person turns the cloud off, and cleared only by their
    /// yes to turning it on again. While set, nothing is sent from any
    /// chat whatever the saved file says, so a save that fails can never
    /// leave it on.
    private let switchedOff = SwitchedOff()

    public convenience init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        auth: any CloudAuth = NoCloudAuth(),
        transport: @escaping @Sendable () -> any CloudTransport = { URLSessionCloudTransport() }
    ) {
        self.init(store: store, endpoint: endpoint, memory: memory, auth: auth, transport: transport,
                  storeOpened: true, unopenedFile: nil)
    }

    private init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        auth: any CloudAuth,
        transport: @escaping @Sendable () -> any CloudTransport,
        storeOpened: Bool,
        unopenedFile: (@Sendable () throws -> any CloudHelpStoring)?
    ) {
        self.store = store
        self.endpoint = endpoint
        self.storeOpened = storeOpened
        self.memory = memory
        self.auth = auth
        self.makeTransport = transport
        self.unopenedFile = unopenedFile
        settings = storeOpened ? store.loadOrOff() : .off
    }

    /// The setting when its file couldn't be opened at launch. It reads as
    /// off and can't be turned on, so no private word is ever typed into
    /// something that would quietly forget it, and no chat uses the cloud.
    ///
    /// `file` reaches the file it would have read, so private words kept
    /// there from an earlier launch can still be erased. See
    /// `eraseWordsWithoutNotes`.
    public static func couldNotOpen(endpoint: URL?, memory: MemoryStore?,
                                    file: (@Sendable () throws -> any CloudHelpStoring)? = nil) -> CloudHelp {
        CloudHelp(store: InMemoryCloudHelpStore(), endpoint: endpoint, memory: memory, auth: NoCloudAuth(),
                  transport: { URLSessionCloudTransport() }, storeOpened: false, unopenedFile: file)
    }

    /// Erases the private words when the notes won't open, as the memory
    /// screen in their place does along with the tasks. A setting opened
    /// at launch erases them as Forget everything does. One that couldn't
    /// be opened erases the whole file it would have read, if that can be
    /// reached now; with no file it reads as off next time too. True when
    /// no private words are kept any more.
    func eraseWordsWithoutNotes() -> Bool {
        if storeOpened { return (try? forgetPrivateWords()) != nil }
        // Nothing to reach means nothing was ever kept, as in tests.
        guard let unopenedFile else { return true }
        return (try? unopenedFile().erase()) != nil
    }

    /// False when no address is set up, or the setting's file couldn't be
    /// opened. The setting then stays off.
    public var isAvailable: Bool { endpoint != nil && storeOpened }

    /// The address, only while the setting can be used. Every choice of
    /// model goes through this, so an unopened file means no cloud.
    private var usableEndpoint: URL? { storeOpened ? endpoint : nil }

    /// True when a new chat would use the cloud model.
    public var usesCloudForNewChats: Bool {
        ModelChoice.usesCloud(settings: settings, endpoint: usableEndpoint)
    }

    /// Whether a new chat's model runs on this device, without making it.
    public func runsOnDevice(local: any ModelClient) -> Bool {
        privacyPlace(local: local).staysOnDevice
    }

    /// The `privacyPlace` of the model a new chat would get, without making
    /// it. See `PrivacyPlace` for how this joins the open chat's.
    public func privacyPlace(local: any ModelClient) -> PrivacyPlace {
        privacyPlace(local: local, settings: settings)
    }

    /// The same, for `settings` about to be set, as `$settings` sends them.
    func privacyPlace(local: any ModelClient, settings: CloudHelpSettings) -> PrivacyPlace {
        ModelChoice.privacyPlace(settings: settings, endpoint: usableEndpoint, local: local)
    }

    /// The model for a new chat: `local` unless the cloud is on. A cloud
    /// chat asks the person through `review`, which belongs to that chat
    /// alone, so one window's preview never shows in another.
    public func chatModel(local: any ModelClient, review: CloudReview) -> any ModelClient {
        chatModelsAsked += 1
        return ModelChoice.model(settings: settings, endpoint: usableEndpoint, local: local) { url in
            reviews.add(review)
            let store = self.store
            let memory = self.memory
            let switchedOff = self.switchedOff
            return CloudModel(
                endpoint: url, transport: makeTransport(), reviewer: review, auth: auth,
                // Read fresh for each reply, on this device, so new notes
                // and private words count right away. Notes or words that
                // can't be read mean nothing is sent.
                redactor: {
                    guard let memory else { throw MemoryStore.Unavailable() }
                    switch memory.contents() {
                    case .notes(let notes): return Redactor(memory: notes, privateWords: try store.load().privateWords)
                    case .unreadable: throw MemoryStore.Unreadable()
                    case .unavailable: throw MemoryStore.Unavailable()
                    }
                },
                // On only when the file says so and the person hasn't
                // switched it off since.
                isOn: { !switchedOff.value && store.loadOrOff().isOn }
            )
        }
    }

    /// Reads the settings again, as after the device was locked at launch.
    /// A switch off that couldn't be saved before is saved now, if it can be.
    func refresh() {
        guard storeOpened, var fresh = try? store.load() else { return }
        if switchedOff.value, fresh.isOn {
            fresh.isOn = false
            try? store.save(fresh)
        }
        settings = fresh
    }

    /// The toggle. Turning on asks first; turning off never does.
    func setOn(_ on: Bool) {
        if on {
            if isAvailable, !settings.isOn { asksToTurnOn = true }
        } else {
            turnOff()
        }
    }

    /// The yes to the turn on question. Sign-in, if there is any, starts
    /// only now, after the yes.
    func confirmTurnOn() {
        asksToTurnOn = false
        guard isAvailable else { return }
        let wasSwitchedOff = switchedOff.value
        switchedOff.value = false
        guard update({ $0.isOn = true }).isDone else {
            // Still off, and still off for chats already open.
            switchedOff.value = wasSwitchedOff
            settings.isOn = false
            status = CloudWords.onNotSaved
            return
        }
        status = nil
        let auth = auth
        signingIn?.cancel()
        signingIn = Task { await auth.signIn() }
    }

    func declineTurnOn() {
        asksToTurnOn = false
    }

    /// Off at once for every chat, before anything is saved. Then it is
    /// saved, tried twice; if that fails the file is erased, since no file
    /// reads as off on the next launch. Only if even that fails could it
    /// read as on next time, and the person is told so.
    func turnOff() {
        switchedOff.value = true
        settings.isOn = false
        stopEverythingUnderWay()
        if update({ $0.isOn = false }).isDone || update({ $0.isOn = false }).isDone {
            status = nil
        } else if (try? store.erase()) != nil {
            settings = .off
            status = CloudWords.offButCleared
        } else {
            status = CloudWords.offForNow
        }
    }

    /// Anything a cloud chat has under way stops: every preview waiting for
    /// a yes is not sent, and a sign-in still going is cancelled (see
    /// `CloudAuth.signIn`).
    private func stopEverythingUnderWay() {
        for review in reviews.allObjects { review.cancelPending() }
        signingIn?.cancel()
        signingIn = nil
    }

    /// A preview waiting for a yes was redacted with the private words as
    /// they were. Once they change it is no longer what would be hidden, so
    /// it is withdrawn and nothing goes; the next send shows a fresh one.
    private func withdrawPreviews() {
        for review in reviews.allObjects { review.cancelPending() }
    }

    func addPrivateWord() {
        let word = newPrivateWord
        switch update({ _ = $0.addPrivateWord(word) }) {
        case .saved: newPrivateWord = ""; status = nil; withdrawPreviews()
        case .unchanged: break
        case .unreadable: status = CloudWords.privateUnreadable
        case .notSaved: status = CloudWords.privateNotSaved
        }
    }

    func removePrivateWord(_ word: String) {
        switch update({ $0.removePrivateWord(word) }) {
        case .saved: status = nil; withdrawPreviews()
        case .unchanged: break
        case .unreadable: status = CloudWords.privateUnreadable
        case .notSaved: status = CloudWords.privateNotSaved
        }
    }

    /// What Forget everything erased of the cloud setting.
    enum Forgot: Equatable {
        /// The private words, with the setting left as it was.
        case privateWords
        /// The whole setting, to be sure the words went, so the cloud is
        /// off now when it was on, or might have been.
        case privateWordsAndCloud
    }

    /// Erases the private words, as Forget everything does, and any word
    /// half typed into the field. The setting itself stays as it was,
    /// unless the words can't be read or saved without them: then the
    /// whole file is erased, which also turns the cloud off, and the answer
    /// says so. Throws only when even that fails.
    @discardableResult
    func forgetPrivateWords() throws -> Forgot {
        newPrivateWord = ""
        let current = try? store.load()
        if var current {
            current.privateWords = []
            if switchedOff.value { current.isOn = false }
            if (try? store.save(current)) != nil {
                let hadWords = !settings.privateWords.isEmpty
                settings = current
                // What waits was hidden with words that are gone now.
                if hadWords { withdrawPreviews() }
                return .privateWords
            }
        }
        // Unread, it may have said on.
        let mightHaveBeenOn = current?.isOn ?? true
        try store.erase()
        settings = .off
        guard mightHaveBeenOn, !switchedOff.value else {
            withdrawPreviews()
            return .privateWords
        }
        // Off for chats already open, as a switch off is.
        switchedOff.value = true
        stopEverythingUnderWay()
        return .privateWordsAndCloud
    }

    enum Outcome {
        case saved, unchanged, unreadable, notSaved
        /// The file now says what was asked.
        var isDone: Bool { self == .saved || self == .unchanged }
    }

    /// Changes the saved settings, read fresh so words saved elsewhere or
    /// unreadable at launch are never written over. A switch off made in
    /// this session is kept in whatever is saved.
    private func update(_ change: (inout CloudHelpSettings) -> Void) -> Outcome {
        guard let before = try? store.load() else { return .unreadable }
        var next = before
        if switchedOff.value { next.isOn = false }
        change(&next)
        guard next != before else {
            settings = next
            return .unchanged
        }
        do {
            try store.save(next)
        } catch {
            return .notSaved
        }
        settings = next
        return .saved
    }
}

/// The session's switch off, read by every chat off the main actor.
final class SwitchedOff: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Holds a chat's preview on screen until the person sends it or not.
///
/// `CloudModel` waits here before every request. The sheet reads `pending`,
/// shows its exact bytes, and answers for that preview by its id. Going
/// away without an answer, the chat screen leaving, or the reply being
/// stopped all count as not sending.
@MainActor
public final class CloudReview: ObservableObject, CloudReviewing {
    @Published public private(set) var pending: CloudPreview?
    private var waiting: CheckedContinuation<CloudConsent, Never>?
    private var watchers: [CheckedContinuation<CloudPreview, Never>] = []

    public init() {}

    public func review(_ preview: CloudPreview) async -> CloudConsent {
        if Task.isCancelled { return .cancel }
        // Only one question at a time; an older one is not sent.
        cancelPending()
        let id = preview.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                pending = preview
                let watchers = self.watchers
                self.watchers = []
                for watcher in watchers { watcher.resume(returning: preview) }
            }
        } onCancel: {
            Task { @MainActor in self.answer(.cancel, for: id) }
        }
    }

    /// The person's answer to the preview with `id`, the one they saw. An
    /// answer meant for any other preview is ignored, so a tap can never
    /// send something that wasn't on screen.
    public func answer(_ consent: CloudConsent, for id: UUID) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        let waiting = self.waiting
        self.waiting = nil
        waiting?.resume(returning: consent)
    }

    /// Sends nothing for whatever is waiting.
    public func cancelPending() {
        if let id = pending?.id { answer(.cancel, for: id) }
    }

    /// Waits until a preview is on screen, with no timing involved. For tests.
    package func shown() async -> CloudPreview {
        if let pending { return pending }
        return await withCheckedContinuation { watchers.append($0) }
    }

    /// Puts a preview on screen with nothing waiting on it, for screenshots.
    package func show(_ preview: CloudPreview) {
        pending = preview
    }
}

/// The cloud setting: off by default, with the words always hidden.
public struct CloudHelpView: View {
    @ObservedObject var help: CloudHelp
    @Environment(\.colorScheme) private var scheme

    public init(help: CloudHelp) {
        self.help = help
    }

    /// The add button, at least the size a finger needs.
    static let addButtonSize: CGFloat = 44

    public var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(CloudWords.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    switchCard
                    privateWordsCard
                    if let status = help.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { help.refresh() }
        // Counted, so the same line twice in a row is spoken twice.
        .onChange(of: help.statusCount) {
            if let status = help.status { AccessibilityNotification.Announcement(status).post() }
        }
        .sheet(isPresented: $help.asksToTurnOn) {
            CloudTurnOnSheet(onYes: { help.confirmTurnOn() }, onNo: { help.declineTurnOn() })
        }
    }

    /// What the setting says under its switch.
    static func detail(for help: CloudHelp) -> String {
        if !help.storeOpened { return CloudWords.couldNotOpen }
        if !help.isAvailable { return CloudWords.unavailable }
        return help.usesCloudForNewChats ? CloudWords.onDetail : CloudWords.offDetail(help.place)
    }

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { help.settings.isOn }, set: { help.setOn($0) })) {
                Label(CloudWords.toggleTitle, systemImage: help.settings.isOn ? "cloud.fill" : "lock.fill")
                    .font(.body.weight(.semibold))
            }
            .tint(Theme.accentText)
            .disabled(!help.isAvailable)
            .accessibilityIdentifier("cloudToggle")
            Text(Self.detail(for: help))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .card(scheme)
    }

    private var privateWordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CloudWords.privateTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(CloudWords.privateDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                PrivateWordField(word: $help.newPrivateWord) { help.addPrivateWord() }
                AddPrivateWordButton(size: Self.addButtonSize) { help.addPrivateWord() }
                    .disabled(!Self.canAdd(help.newPrivateWord))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(Theme.fieldTint), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
            PrivateWordList(words: help.settings.privateWords) { help.removePrivateWord($0) }
        }
        .padding(16)
        .card(scheme)
    }

    /// Only words can be added, not blank space.
    static func canAdd(_ word: String) -> Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The round add button beside the private word field. With nothing typed
/// it can't be pressed, and it looks it: a quiet gray outline on the field
/// itself, rather than the accent it has when ready. A gray fill stacked on
/// the field would sink the gray below 4.5 to 1 in dark.
struct AddPrivateWordButton: View {
    let size: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.headline)
                .foregroundStyle(Self.symbolStyle(enabled: isEnabled))
                .frame(width: size, height: size)
                .background(Self.fill(enabled: isEnabled), in: Circle())
                .overlay(Circle().stroke(isEnabled ? Color.clear : Theme.hairline(scheme)))
                .pointerHover(in: Circle())
        }
        .buttonStyle(.plain)
        .help(CloudWords.privateAdd)
        .accessibilityLabel(CloudWords.privateAdd)
    }

    static func symbolStyle(enabled: Bool) -> AnyShapeStyle {
        enabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.secondaryText)
    }

    static func fill(enabled: Bool) -> AnyShapeStyle {
        // Disabled, it shows the field it sits in: secondaryText on "field
        // on the card", a pair `Theme.textPairs` already checks.
        enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear)
    }
}

/// What the system hides on screens marked private: nothing while the app
/// is in use, and everything marked private once it isn't, so the app
/// switcher's picture never shows private words or a payload.
func privateRedaction(_ phase: ScenePhase) -> RedactionReasons {
    phase == .active ? [] : .privacy
}

/// Where a new private word is typed. What is half typed is as private as
/// the list, so it hides the same way.
struct PrivateWordField: View {
    @Binding var word: String
    let onSubmit: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextField(CloudWords.privatePlaceholder, text: $word)
            .textFieldStyle(.plain)
            // The keyboard never learns or suggests private words.
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(onSubmit)
            // Hidden wherever the system hides private things, and in the
            // app switcher.
            .privacySensitive()
            .redacted(reason: privateRedaction(scenePhase))
    }
}

/// The words always hidden, each with a way to stop hiding it.
struct PrivateWordList: View {
    let words: [String]
    let onRemove: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(words, id: \.self) { word in
                HStack {
                    Label(word, systemImage: "eye.slash")
                        .font(.body)
                    Spacer(minLength: 8)
                    Button { onRemove(word) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .help(CloudWords.privateRemove(word))
                    .accessibilityLabel(CloudWords.privateRemove(word))
                }
            }
        }
        // Hidden wherever the system hides private things, and in the app
        // switcher.
        .privacySensitive()
        .redacted(reason: privateRedaction(scenePhase))
    }
}

/// The row on the memory screen that opens the cloud setting. It is the only
/// way in; see `HomeView.memoryScreen` for when memory can't open.
struct CloudHelpRow: View {
    @ObservedObject var help: CloudHelp
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink {
            CloudHelpView(help: help)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: help.settings.isOn ? "cloud.fill" : "lock.fill")
                    .foregroundStyle(Theme.accentSymbol)
                    .frame(width: 24)
                    // Decoration: "On" or "Off" beside it says the same.
                    .accessibilityHidden(true)
                Text(CloudWords.rowTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(help.settings.isOn ? CloudWords.rowOn : CloudWords.rowOff)
                    .foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .card(scheme)
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerHover(in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityIdentifier("cloudRow")
    }
}

/// The question before the cloud is turned on, saying in plain words what
/// changes.
struct CloudTurnOnSheet: View {
    let onYes: () -> Void
    let onNo: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent, in: Circle())
                    .accessibilityHidden(true)
                Text(CloudWords.askQuestion)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(CloudWords.askPoints.enumerated()), id: \.offset) { index, point in
                        Label {
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Self.symbols[index % Self.symbols.count])
                                .foregroundStyle(Theme.accentSymbol)
                        }
                        .font(.body)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(scheme)
                VStack(spacing: 6) {
                    Button(CloudWords.askYes, action: onYes)
                        .buttonStyle(PrimaryButtonStyle())
                    Button(CloudWords.askNo, action: onNo)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private static let symbols = ["cloud", "eye", "eye.slash", "arrow.triangle.2.circlepath", "person.crop.circle",
                                  "key", "lock", "network", "heart", "arrow.uturn.backward"]
}

/// "Here is exactly what leaves your device": the whole request, its
/// address, headers and body, with what was taken out marked, and a choice
/// to send it or not.
struct CloudPreviewSheet: View {
    let preview: CloudPreview
    let onSend: () -> Void
    let onCancel: () -> Void

    /// What the payload card shows: the very request that will be sent.
    static func shownText(_ preview: CloudPreview) -> String { preview.request.shownText }

    static func hiddenLine(_ preview: CloudPreview) -> String {
        let parts = Redaction.Kind.allCases.compactMap { kind in
            preview.hidden[kind].map { kind.counted($0) }
        }
        return parts.isEmpty ? CloudWords.previewNothingHidden : CloudWords.previewHidden(parts)
    }

    /// What VoiceOver reads instead of the raw text: where it goes, the
    /// labels, then each message by who said it, with masks read as
    /// "hidden name" and the like.
    static func spokenLines(_ preview: CloudPreview) -> [String] {
        let request = preview.request
        var lines = [CloudWords.spokenAddress(request.url.absoluteString)]
        // A fixed label is read in full. Any other is sign-in, whose value
        // is a secret: VoiceOver says only how long it is, so it is never
        // spoken aloud.
        let labels = request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { name, value in
            CloudHeaders.fixed[name] == value
                ? "\(name), \(value)" : CloudWords.spokenSignIn(name, characters: value.count)
        }
        if !labels.isEmpty { lines.append(CloudWords.spokenLabels(labels)) }
        if let payload = try? JSONDecoder().decode(CloudPayload.self, from: request.body) {
            lines += payload.messages.map {
                CloudWords.spokenMessage(role: $0.role, text: Redaction.Kind.spoken($0.text))
            }
        } else {
            lines.append(Redaction.Kind.spoken(request.text))
        }
        return lines
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CloudWords.previewTitle)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(CloudWords.previewDetail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(CloudWords.previewDestination(preview.request.url.host ?? ""), systemImage: "arrow.up.forward.circle")
                    Label(Self.hiddenLine(preview), systemImage: "eye.slash")
                }
                .font(.subheadline.weight(.medium))
                CloudPayloadCard(preview: preview)
                VStack(spacing: 6) {
                    Button(CloudWords.previewSend, action: onSend)
                        .buttonStyle(PrimaryButtonStyle())
                    Button(CloudWords.previewCancel, action: onCancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// The request itself, as plain text, with what was taken out marked.
/// VoiceOver reads it message by message instead of as raw text.
///
/// The text can't be selected or copied. A sign-in label's value is shown
/// so the person sees everything that goes, but it is one long press from
/// the clipboard, and from there Universal Clipboard, if it can be selected.
struct CloudPayloadCard: View {
    let preview: CloudPreview
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text(highlighted)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card(scheme)
            // Hidden wherever the system hides private things, and in the
            // app switcher.
            .privacySensitive()
            .redacted(reason: privateRedaction(scenePhase))
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    ForEach(Array(CloudPreviewSheet.spokenLines(preview).enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
            .accessibilityIdentifier("cloudPayload")
    }

    /// The request with each mask tinted, so what was taken out stands out.
    private var highlighted: AttributedString {
        var text = AttributedString(CloudPreviewSheet.shownText(preview))
        for kind in Redaction.Kind.allCases {
            var start = text.startIndex
            while let range = text[start...].range(of: kind.mask) {
                text[range].backgroundColor = Theme.accent.opacity(Theme.maskWash(scheme))
                text[range].font = .system(.footnote, design: .monospaced).weight(.bold)
                start = range.upperBound
            }
        }
        return text
    }
}

extension View {
    /// Shows `review`'s preview over this screen. Closing it any way but
    /// Send means nothing is sent.
    ///
    /// `blocked` is true while another sheet or a question is open; only
    /// one sheet can show at a time, so the preview waits, unsent, until it
    /// closes. `waiting` is told whenever a preview is pending, shown or
    /// not, so `HomeCover` can count it as covering the screen.
    @ViewBuilder
    func cloudPreview(_ review: CloudReview?, blocked: Bool = false, waiting: Binding<Bool>? = nil) -> some View {
        if let review {
            modifier(CloudPreviewPresenter(review: review, blocked: blocked, waiting: waiting))
        } else {
            self.onAppear { waiting?.wrappedValue = false }
        }
    }

    /// The usual card surface.
    func card(_ scheme: ColorScheme) -> some View {
        background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
    }
}

struct CloudPreviewPresenter: ViewModifier {
    @ObservedObject var review: CloudReview
    let blocked: Bool
    let waiting: Binding<Bool>?

    /// The preview to put on screen now: none while something else is open.
    static func shown(_ pending: CloudPreview?, blocked: Bool) -> CloudPreview? {
        blocked ? nil : pending
    }

    func body(content: Content) -> some View {
        // Swiping the sheet away only ever cancels, which is always safe.
        // Send is tied to the preview that sheet showed. A preview held back
        // by another sheet is never cancelled for it.
        content.sheet(
            item: Binding(get: { Self.shown(review.pending, blocked: blocked) },
                          set: { if $0 == nil, !blocked { review.cancelPending() } })
        ) { preview in
            CloudPreviewSheet(preview: preview,
                              onSend: { review.answer(.send, for: preview.id) },
                              onCancel: { review.answer(.cancel, for: preview.id) })
        }
        .onChange(of: review.pending?.id, initial: true) { _, id in
            waiting?.wrappedValue = id != nil
        }
    }
}
#endif
