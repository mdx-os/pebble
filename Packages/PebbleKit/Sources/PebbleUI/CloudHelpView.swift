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

    public let endpoint: URL?
    public let review: CloudReview
    private let store: any CloudHelpStoring
    private let memory: MemoryStore?
    private let auth: any CloudAuth
    private let makeTransport: @Sendable () -> any CloudTransport

    public init(
        store: any CloudHelpStoring,
        endpoint: URL?,
        memory: MemoryStore?,
        review: CloudReview = CloudReview(),
        auth: any CloudAuth = NoCloudAuth(),
        transport: @escaping @Sendable () -> any CloudTransport = { URLSessionCloudTransport() }
    ) {
        self.store = store
        self.endpoint = endpoint
        self.memory = memory
        self.review = review
        self.auth = auth
        self.makeTransport = transport
        settings = store.load()
    }

    /// False when no address is set up. The setting then stays off.
    public var isAvailable: Bool { endpoint != nil }

    /// The model for a new chat: `local` unless the cloud is on.
    public func chatModel(local: any ModelClient) -> any ModelClient {
        ModelChoice.model(settings: settings, endpoint: endpoint, local: local) { url in
            let store = self.store
            let memory = self.memory
            return CloudModel(
                endpoint: url, transport: makeTransport(), reviewer: review, auth: auth,
                // Read fresh for each reply, on this device, so new notes
                // and private words count right away.
                redactor: { Redactor(memory: memory?.notes() ?? [], privateWords: store.load().privateWords) },
                isOn: { store.load().isOn }
            )
        }
    }

    /// The toggle. Turning on asks first; turning off never does.
    func setOn(_ on: Bool) {
        if on {
            if isAvailable, !settings.isOn { asksToTurnOn = true }
        } else {
            turnOff()
        }
    }

    /// The yes to the turn on question.
    func confirmTurnOn() {
        asksToTurnOn = false
        guard isAvailable else { return }
        update { $0.isOn = true }
    }

    func declineTurnOn() {
        asksToTurnOn = false
    }

    func turnOff() {
        update { $0.isOn = false }
        // Anything waiting for a yes is not sent.
        review.answer(.cancel)
    }

    func addPrivateWord() {
        var next = settings
        if next.addPrivateWord(newPrivateWord) {
            settings = next
            store.save(next)
            newPrivateWord = ""
        }
    }

    func removePrivateWord(_ word: String) {
        update { $0.removePrivateWord(word) }
    }

    private func update(_ change: (inout CloudHelpSettings) -> Void) {
        var next = settings
        change(&next)
        settings = next
        store.save(next)
    }
}

/// Holds a preview on screen until the person sends it or not.
///
/// `CloudModel` waits here before every request. The sheet reads `pending`,
/// shows its exact bytes, and answers. Going away without an answer, or the
/// reply being stopped, counts as not sending.
@MainActor
public final class CloudReview: ObservableObject, CloudReviewing {
    @Published public private(set) var pending: CloudPreview?
    private var waiting: CheckedContinuation<CloudConsent, Never>?

    public init() {}

    public func review(_ preview: CloudPreview) async -> CloudConsent {
        if Task.isCancelled { return .cancel }
        // Only one question at a time; an older one is not sent.
        answer(.cancel)
        let id = preview.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                pending = preview
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// The person's answer to what is showing.
    public func answer(_ consent: CloudConsent) {
        guard let waiting else { return }
        self.waiting = nil
        pending = nil
        waiting.resume(returning: consent)
    }

    private func cancel(_ id: UUID) {
        if pending?.id == id { answer(.cancel) }
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
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $help.asksToTurnOn) {
            CloudTurnOnSheet(onYes: { help.confirmTurnOn() }, onNo: { help.declineTurnOn() })
        }
    }

    private var detail: String {
        if !help.isAvailable { return CloudWords.unavailable }
        return help.settings.isOn ? CloudWords.onDetail : CloudWords.offDetail
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
                    .onSubmit { help.addPrivateWord() }
                Button { help.addPrivateWord() } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle())
                        .pointerHover(in: Circle())
                }
                .buttonStyle(.plain)
                .help(CloudWords.privateAdd)
                .accessibilityLabel(CloudWords.privateAdd)
                .disabled(help.newPrivateWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
            ForEach(help.settings.privateWords, id: \.self) { word in
                HStack {
                    Label(word, systemImage: "eye.slash")
                        .font(.body)
                    Spacer(minLength: 8)
                    Button { help.removePrivateWord(word) } label: {
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
        .padding(16)
        .card(scheme)
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

/// "Here is exactly what leaves your device": the request's own bytes, with
/// what was taken out marked, and a choice to send them or not.
struct CloudPreviewSheet: View {
    let preview: CloudPreview
    let onSend: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// What the payload card shows: the very bytes that will be sent.
    static func shownText(_ preview: CloudPreview) -> String { preview.request.text }

    static func hiddenLine(_ preview: CloudPreview) -> String {
        let parts = Redaction.Kind.allCases.compactMap { kind in
            preview.hidden[kind].map { kind.counted($0) }
        }
        return parts.isEmpty ? CloudWords.previewNothingHidden : CloudWords.previewHidden(parts)
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
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(CloudWords.previewDestination(preview.request.url.host ?? ""), systemImage: "arrow.up.forward.circle")
                    Label(Self.hiddenLine(preview), systemImage: "eye.slash")
                }
                .font(.subheadline.weight(.medium))
                Text(highlighted)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .card(scheme)
                    .accessibilityIdentifier("cloudPayload")
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

    /// The payload with each mask tinted, so what was taken out stands out.
    private var highlighted: AttributedString {
        var text = AttributedString(Self.shownText(preview))
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
        content.sheet(
            item: Binding(get: { review.pending }, set: { if $0 == nil { review.answer(.cancel) } })
        ) { preview in
            CloudPreviewSheet(preview: preview,
                              onSend: { review.answer(.send) },
                              onCancel: { review.answer(.cancel) })
        }
    }
}
#endif
