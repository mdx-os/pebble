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
    /// What to say about the last change that couldn't be made.
    @Published private(set) var status: String?

    public let endpoint: URL?
    /// The same store the memory screen uses, so the redactor always reads
    /// the notes as they are now.
    let memory: MemoryStore?
    private let store: any CloudHelpStoring
    private let auth: any CloudAuth
    private let makeTransport: @Sendable () -> any CloudTransport
    /// Every chat's preview gate, so turning the cloud off closes them all.
    private let reviews = NSHashTable<CloudReview>.weakObjects()
    /// Sign-in after the person's yes. Tests wait on it.
    private(set) var signingIn: Task<Void, Never>?

    public init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        auth: any CloudAuth = NoCloudAuth(),
        transport: @escaping @Sendable () -> any CloudTransport = { URLSessionCloudTransport() }
    ) {
        self.store = store
        self.endpoint = endpoint
        self.memory = memory
        self.auth = auth
        self.makeTransport = transport
        settings = store.loadOrOff()
    }

    /// False when no address is set up. The setting then stays off.
    public var isAvailable: Bool { endpoint != nil }

    /// True when a new chat would use the cloud model.
    public var usesCloudForNewChats: Bool {
        ModelChoice.usesCloud(settings: settings, endpoint: endpoint)
    }

    /// Whether a new chat's model runs on this device, without making it.
    public func runsOnDevice(local: any ModelClient) -> Bool {
        ModelChoice.runsOnDevice(settings: settings, endpoint: endpoint, local: local)
    }

    /// The model for a new chat: `local` unless the cloud is on. A cloud
    /// chat asks the person through `review`, which belongs to that chat
    /// alone, so one window's preview never shows in another.
    public func chatModel(local: any ModelClient, review: CloudReview) -> any ModelClient {
        ModelChoice.model(settings: settings, endpoint: endpoint, local: local) { url in
            reviews.add(review)
            let store = self.store
            let memory = self.memory
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
                isOn: { store.loadOrOff().isOn }
            )
        }
    }

    /// Reads the settings again, as after the device was locked at launch.
    func refresh() {
        if let fresh = try? store.load() { settings = fresh }
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
        guard isAvailable, update({ $0.isOn = true }) else { return }
        let auth = auth
        signingIn = Task { await auth.signIn() }
    }

    func declineTurnOn() {
        asksToTurnOn = false
    }

    func turnOff() {
        // Settings that can't be read already count as off, so this never
        // waits on a save to stop sending.
        if !update({ $0.isOn = false }) { settings.isOn = false }
        // Anything waiting for a yes is not sent.
        for review in reviews.allObjects { review.cancelPending() }
    }

    func addPrivateWord() {
        let word = newPrivateWord
        if update({ _ = $0.addPrivateWord(word) }) { newPrivateWord = "" }
    }

    func removePrivateWord(_ word: String) {
        update { $0.removePrivateWord(word) }
    }

    /// Erases the private words, as Forget everything does. The setting
    /// itself stays as it was.
    func forgetPrivateWords() throws {
        if var current = try? store.load() {
            current.privateWords = []
            try store.save(current)
            settings = current
        } else {
            try store.erase()
            settings = .off
        }
    }

    /// Changes the saved settings, read fresh so words saved elsewhere or
    /// unreadable at launch are never written over. Returns false when
    /// nothing changed.
    @discardableResult
    private func update(_ change: (inout CloudHelpSettings) -> Void) -> Bool {
        guard var next = try? store.load() else {
            status = CloudWords.privateUnreadable
            return false
        }
        let before = next
        change(&next)
        guard next != before else {
            settings = next
            return false
        }
        do {
            try store.save(next)
        } catch {
            status = CloudWords.privateUnreadable
            return false
        }
        settings = next
        status = nil
        return true
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
                            .foregroundStyle(.secondary)
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
        .onChange(of: help.status) { _, status in
            if let status { AccessibilityNotification.Announcement(status).post() }
        }
        .sheet(isPresented: $help.asksToTurnOn) {
            CloudTurnOnSheet(onYes: { help.confirmTurnOn() }, onNo: { help.declineTurnOn() })
        }
    }

    private var detail: String {
        if !help.isAvailable { return CloudWords.unavailable }
        return help.usesCloudForNewChats ? CloudWords.onDetail : CloudWords.offDetail
    }

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { help.settings.isOn }, set: { help.setOn($0) })) {
                Label(CloudWords.toggleTitle, systemImage: help.settings.isOn ? "cloud.fill" : "lock.fill")
                    .font(.body.weight(.semibold))
            }
            .tint(Theme.accent)
            .disabled(!help.isAvailable)
            .accessibilityIdentifier("cloudToggle")
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                TextField(CloudWords.privatePlaceholder, text: $help.newPrivateWord)
                    .textFieldStyle(.plain)
                    // The keyboard never learns or suggests private words.
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { help.addPrivateWord() }
                Button { help.addPrivateWord() } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: Self.addButtonSize, height: Self.addButtonSize)
                        .background(Theme.accent, in: Circle())
                        .pointerHover(in: Circle())
                }
                .buttonStyle(.plain)
                .help(CloudWords.privateAdd)
                .accessibilityLabel(CloudWords.privateAdd)
                .disabled(help.newPrivateWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
            PrivateWordList(words: help.settings.privateWords) { help.removePrivateWord($0) }
        }
        .padding(16)
        .card(scheme)
    }
}

/// What the system hides on screens marked private: nothing while the app
/// is in use, and everything marked private once it isn't, so the app
/// switcher's picture never shows private words or a payload.
func privateRedaction(_ phase: ScenePhase) -> RedactionReasons {
    phase == .active ? [] : .privacy
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
                            .foregroundStyle(.secondary)
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

/// The row on the memory screen that opens the cloud setting.
struct CloudHelpRow: View {
    @ObservedObject var help: CloudHelp
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink {
            CloudHelpView(help: help)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: help.settings.isOn ? "cloud.fill" : "lock.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(CloudWords.rowTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(help.settings.isOn ? CloudWords.rowOn : CloudWords.rowOff)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
                                .foregroundStyle(Theme.accent)
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

    private static let symbols = ["cloud", "eye", "eye.slash", "lock", "heart", "arrow.uturn.backward"]
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
        let labels = request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key), \($0.value)" }
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
                        .foregroundStyle(.secondary)
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
struct CloudPayloadCard: View {
    let preview: CloudPreview
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Text(highlighted)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
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
                text[range].backgroundColor = Theme.accent.opacity(scheme == .dark ? 0.45 : 0.28)
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
    @ViewBuilder
    func cloudPreview(_ review: CloudReview?) -> some View {
        if let review {
            modifier(CloudPreviewPresenter(review: review))
        } else {
            self
        }
    }

    /// The usual card surface.
    func card(_ scheme: ColorScheme) -> some View {
        background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
    }
}

private struct CloudPreviewPresenter: ViewModifier {
    @ObservedObject var review: CloudReview

    func body(content: Content) -> some View {
        // Swiping the sheet away only ever cancels, which is always safe.
        // Send is tied to the preview that sheet showed.
        content.sheet(
            item: Binding(get: { review.pending }, set: { if $0 == nil { review.cancelPending() } })
        ) { preview in
            CloudPreviewSheet(preview: preview,
                              onSend: { review.answer(.send, for: preview.id) },
                              onCancel: { review.answer(.cancel, for: preview.id) })
        }
    }
}
#endif
