import Foundation
import PebbleCore
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(SwiftUI)
import SwiftUI

/// What happens around a question pinned in Needs you: the nudge when the
/// person is away, the one time offer to send nudges at all, the receipts
/// kept after a yes, and keeping all of it while the app is closed.
///
/// Nothing here can approve anything. A question is answered only in
/// `ConfirmationSheet`, with the rule that asked it.
///
/// Nudges are opt in. The offer shows only once a question is waiting,
/// never at launch, and the system's own question comes only after the
/// person says yes to the offer. A nudge says only that the agent has a
/// question, so a lock screen shows nothing of what it is. Each question is
/// nudged once at most, only while the app is in the background, and the
/// nudge goes as soon as the question closes.
@MainActor
final class NeedsYouFlow: ObservableObject {
    let store: TaskStore
    let notifier: (any QuestionNotifying)?
    private let agentName: () -> String

    /// True while the offer to send nudges is on Today.
    @Published private(set) var offersNudges = false
    /// A line after No thanks, or after the system said no, kept while a
    /// question still waits.
    @Published private(set) var nudgeNote: String?
    /// The task to bring into view, from a nudge the person opened.
    @Published var focus: String?

    /// The app is in front, so a waiting question is already on screen.
    private(set) var isActive = true
    /// The questions pinned now, as nudges.
    private var waiting: [QuestionNudge] = []
    /// Every question nudged already, so none is nudged twice.
    private var told: Set<String> = []
    /// Nudges posted and not yet taken away.
    private var posted: Set<String> = []
    /// The system's answer, while it is being asked.
    private var asking: Task<Void, Never>?

    init(store: TaskStore, notifier: (any QuestionNotifying)?, agentName: @escaping () -> String) {
        self.store = store
        self.notifier = notifier
        self.agentName = agentName
        notifier?.onOpen { [weak self] id in self?.opened(id) }
    }

    /// The tasks whose questions are pinned in Needs you. Only these are
    /// nudged: a question from another rule is never pinned, so never nudged.
    func pinned(_ tasks: [AgentTask]) {
        waiting = tasks.compactMap { task in
            task.question.map { QuestionNudge(question: $0, taskID: task.id, agentName: agentName()) }
        }
        let open = Set(waiting.map(\.id))
        let closed = posted.subtracting(open)
        if !closed.isEmpty {
            notifier?.remove(Array(closed))
            posted.subtract(closed)
        }
        // Not while the system's own question is up: the offer was answered.
        let offers = notifier != nil && asking == nil && !waiting.isEmpty && store.nudges == .notAsked
        if offersNudges != offers { offersNudges = offers }
        if waiting.isEmpty && nudgeNote != nil { nudgeNote = nil }
        postIfAway()
    }

    /// Yes to the offer. Only now does the system ask.
    func allowNudges() {
        guard let notifier, asking == nil else { return }
        offersNudges = false
        asking = Task { [weak self] in
            let granted = await notifier.requestPermission()
            guard let self else { return }
            self.store.setNudges(granted ? .allowed : .denied)
            if !granted { self.nudgeNote = NudgeWords.off }
            self.asking = nil
            self.postIfAway()
        }
    }

    /// No thanks to the offer. It is never shown again.
    func declineNudges() {
        offersNudges = false
        store.setNudges(.declined)
        nudgeNote = NudgeWords.off
    }

    /// Waits for the system's answer to the offer, for tests.
    func settled() async {
        await asking?.value
    }

    /// The app came to the front or went away. In front, the questions are
    /// on screen, so their nudges go. Away, waiting questions get one each.
    func scene(isActive active: Bool) {
        isActive = active
        if active {
            if !posted.isEmpty {
                notifier?.remove(Array(posted))
                posted = []
            }
        } else {
            postIfAway()
        }
    }

    /// The person opened a nudge: bring its task into view.
    func opened(_ taskID: String) {
        focus = taskID
    }

    /// Forget everything: receipts and saved tasks go, and so do the nudges.
    func forget() {
        if !posted.isEmpty { notifier?.remove(Array(posted)) }
        posted = []
        store.forget()
    }

    private func postIfAway() {
        guard !isActive, store.nudges == .allowed, let notifier else { return }
        for nudge in waiting where !told.contains(nudge.id) {
            told.insert(nudge.id)
            posted.insert(nudge.id)
            notifier.post(nudge)
        }
    }
}

#if canImport(UserNotifications)
/// Nudges through the system's local notifications. Nothing leaves the
/// device: a nudge is made and shown here.
///
/// The app makes this the notification center's delegate at launch, so a
/// nudge opened from the lock screen reaches Today even on a cold start.
public final class LocalQuestionNotifier: NSObject, QuestionNotifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = LocalQuestionNotifier()

    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (String) -> Void)?
    /// A nudge opened before anything listened.
    private var waitingOpen: String?

    /// Where a nudge's task id is kept. The only thing it carries.
    static let taskKey = "task"

    /// Becomes the delegate. Call once, as the app starts.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func permission() async -> NudgePermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// What a nudge shows: only that the agent has a question. No body, so
    /// a lock screen, a watch or a mirrored screen never shows what it is.
    static func content(for nudge: QuestionNudge) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = ""
        content.sound = .default
        content.threadIdentifier = "questions"
        content.targetContentIdentifier = nudge.taskID
        content.userInfo = [taskKey: nudge.taskID]
        return content
    }

    public func post(_ nudge: QuestionNudge) {
        let request = UNNotificationRequest(identifier: nudge.id, content: Self.content(for: nudge), trigger: nil)
        #if os(iOS)
        // Posted as the app goes to the background, so it asks for a moment
        // more, or it could be suspended before the system has the nudge.
        Task { @MainActor in
            let moment = UIApplication.shared.beginBackgroundTask(withName: "nudge")
            try? await UNUserNotificationCenter.current().add(request)
            UIApplication.shared.endBackgroundTask(moment)
        }
        #else
        UNUserNotificationCenter.current().add(request) { _ in }
        #endif
    }

    public func remove(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock()
        self.handler = handler
        let waiting = waitingOpen
        waitingOpen = nil
        lock.unlock()
        if let waiting { Task { @MainActor in handler(waiting) } }
    }

    /// The task a nudge's tap opens, or nil when it isn't one of ours.
    static func taskID(in userInfo: [AnyHashable: Any]) -> String? {
        userInfo[taskKey] as? String
    }

    func open(_ taskID: String) {
        lock.lock()
        let handler = handler
        if handler == nil { waitingOpen = taskID }
        lock.unlock()
        if let handler { Task { @MainActor in handler(taskID) } }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// With the app in front the question is already pinned on Today, so
    /// nothing more is shown.
    ///
    /// The completion forms, not the async ones: the system must hear back
    /// on the thread it called on, and an async method answers from
    /// another, which stops the app as it opens.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = Self.taskID(in: response.notification.request.content.userInfo) { open(id) }
        completionHandler()
    }
}
#endif

/// The one time offer, shown in Needs you while a question waits.
struct NudgeOffer: View {
    @ObservedObject var flow: NeedsYouFlow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if flow.offersNudges {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(NudgeWords.offerTitle)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(Theme.accentSymbol)
                        .accessibilityHidden(true)
                }
                Text(NudgeWords.offerDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("nudgeOffer")
        } else if let note = flow.nudgeNote {
            Text(note)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nudgeNote")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(NudgeWords.allowTitle) { flow.allowNudges() }
            .buttonStyle(CardButtonStyle(kind: .primary))
        Button(NudgeWords.declineTitle) { flow.declineNudges() }
            .buttonStyle(CardButtonStyle(kind: .quiet))
    }
}

/// What the person said yes to, and what came of it, with Clear.
struct ReceiptCard: View {
    let receipt: Receipt
    let time: String
    let onClear: () -> Void
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 92

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    /// The summary for VoiceOver. An example says so first.
    var spoken: String {
        [receipt.isSample ? FeedWords.exampleMarker : "", ReceiptWords.label, receipt.title, receipt.line, time]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The rows under the summary: where it went, what went, and what it did.
    var rows: [(label: String, value: String)] {
        var out: [(String, String)] = [(ConfirmationWords.whereLabel, receipt.handle),
                                       (ConfirmationSheet.detailsLabel(receipt.kind), receipt.details)]
        if let price = receipt.price { out.append((ConfirmationWords.priceLabel, price.formatted())) }
        if let outcome = receipt.outcomeLine { out.append((ConfirmationWords.happensLabel, outcome)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label {
                        Text(ReceiptWords.label)
                    } icon: {
                        Image(systemName: FeedCard.symbol(.receipt))
                            .foregroundStyle(Theme.accentSymbol)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    if receipt.isSample {
                        Text(FeedWords.exampleMarker)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(receipt.title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(receipt.line)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: labelWidth, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
            Button(TaskWords.dismissTitle, action: onClear)
                .buttonStyle(CardButtonStyle(kind: .quiet))
                .accessibilityHint(ReceiptWords.clearHint)
                .accessibilityIdentifier("clearReceipt")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: shape)
        .overlay(shape.stroke(Theme.hairline(scheme), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receipt")
    }
}
#endif
