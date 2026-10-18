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
/// question, so a lock screen shows nothing of what it is. A nudge waits
/// `nudgeDelay` after the app goes away, so a quick switch to another app
/// and back sends nothing, and a question about to time out isn't nudged
/// at all. Each question is nudged at most once while the app runs, and
/// the nudge goes as soon as the question closes. A question asked again
/// after the app opens is a new question, so it may be nudged once more.
@MainActor
final class NeedsYouFlow: ObservableObject {
    let store: TaskStore
    let notifier: (any QuestionNotifying)?
    private let agentName: () -> String
    private let now: () -> Date

    /// How long the app is away before a waiting question nudges.
    static let nudgeDelay: TimeInterval = 30
    /// A question with less time left than this isn't nudged: it would
    /// time out about as the person got back to it.
    static let leastTimeLeft: TimeInterval = 90

    /// True while the offer to send nudges is on Today.
    @Published private(set) var offersNudges = false
    /// A line after No thanks, or after the system said no, kept while a
    /// question still waits.
    @Published private(set) var nudgeNote: String?
    /// The task to bring into view, from a nudge the person opened.
    @Published var focus: String?

    /// Says a line to VoiceOver. Tests replace it to hear what would be said.
    var announce: @MainActor (String) -> Void = NeedsYouFlow.post

    /// The app is in front, so a waiting question is already on screen.
    private(set) var isActive = true
    /// The questions pinned now, each with the nudge it would get.
    private var waiting: [(nudge: QuestionNudge, question: ConfirmationRequest)] = []
    /// The rule the pinned questions were asked through, for their time left.
    private var rule: AskFirst?
    /// Every question nudged already, so none is nudged twice.
    private var told: Set<String> = []
    /// Nudges posted and not yet taken away, with when each was posted.
    private var posted: [String: Date] = [:]
    /// The system's answer, while it is being asked.
    private var asking: Task<Void, Never>?
    /// A look at what the system allows now, after the app comes back.
    private var checking: Task<Void, Never>?

    init(store: TaskStore, notifier: (any QuestionNotifying)?, agentName: @escaping () -> String,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.notifier = notifier
        self.agentName = agentName
        self.now = now
        // A nudge left from before this launch points at a question that is
        // gone or asked again, so none is kept.
        notifier?.removeAll()
        notifier?.onOpen { [weak self] id in self?.opened(id) }
    }

    /// The tasks whose questions are pinned in Needs you, asked through
    /// `rule`. Only these are nudged: a question from another rule is never
    /// pinned, so never nudged.
    func pinned(_ tasks: [AgentTask], rule: AskFirst) {
        self.rule = rule
        waiting = tasks.compactMap { task in
            task.question.map { (QuestionNudge(question: $0, taskID: task.id, agentName: agentName()), $0) }
        }
        let open = Set(waiting.map(\.nudge.id))
        let closed = Set(posted.keys).subtracting(open)
        if !closed.isEmpty {
            notifier?.remove(Array(closed))
            for id in closed { posted[id] = nil }
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
            if !granted { self.sayNudgesAreOff() }
            self.asking = nil
            self.postIfAway()
        }
    }

    /// No thanks to the offer. It is never shown again.
    func declineNudges() {
        offersNudges = false
        store.setNudges(.declined)
        sayNudgesAreOff()
    }

    /// The offer goes from under VoiceOver, so the line that takes its
    /// place is said as well as shown.
    private func sayNudgesAreOff() {
        nudgeNote = NudgeWords.off
        announce(NudgeWords.off)
    }

    /// Waits for the system's answers, for tests.
    func settled() async {
        await asking?.value
        await checking?.value
    }

    /// The app came to the front or went away. In front, the questions are
    /// on screen, so their nudges go, and one taken away before it showed
    /// may nudge the next time. Away, each waiting question gets one, after
    /// a short wait.
    func scene(isActive active: Bool) {
        isActive = active
        if active {
            if !posted.isEmpty {
                notifier?.remove(Array(posted.keys))
                let time = now()
                for (id, at) in posted where time.timeIntervalSince(at) < Self.nudgeDelay { told.remove(id) }
                posted = [:]
            }
            recheckPermission()
        } else {
            postIfAway()
        }
    }

    /// Nudges may have been turned on or off in Settings while the app was
    /// away. Only what the system decided is followed; No thanks stands.
    private func recheckPermission() {
        guard let notifier, asking == nil, checking == nil,
              store.nudges == .allowed || store.nudges == .denied else { return }
        checking = Task { [weak self] in
            let permission = await notifier.permission()
            guard let self else { return }
            switch (self.store.nudges, permission) {
            case (.denied, .allowed):
                self.store.setNudges(.allowed)
                self.nudgeNote = nil
            case (.allowed, .denied):
                self.store.setNudges(.denied)
            default:
                break
            }
            self.checking = nil
        }
    }

    /// The person opened a nudge: bring its task into view.
    func opened(_ taskID: String) {
        focus = taskID
    }

    /// Forget everything: receipts and saved tasks go, and so does every
    /// nudge about a question, from this launch or before.
    func forget() {
        notifier?.removeAll()
        posted = [:]
        store.forget()
    }

    private func postIfAway() {
        guard !isActive, store.nudges == .allowed, let notifier else { return }
        for (nudge, question) in waiting where !told.contains(nudge.id) {
            // Left for next time, when it will have less time still.
            guard let left = rule?.timeLeft(question), left >= Self.leastTimeLeft else { continue }
            told.insert(nudge.id)
            posted[nudge.id] = now()
            notifier.post(nudge, after: Self.nudgeDelay)
        }
    }

    static func post(_ line: String) {
        AccessibilityNotification.Announcement(line).post()
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
    private var isInstalled = false

    /// True once `install` ran, so there is a notification center to use.
    var installed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInstalled
    }

    /// Where a nudge's task id is kept. The only thing it carries.
    static let taskKey = "task"
    /// The thread every nudge about a question is posted in, and the only
    /// one this app's nudges are taken from.
    static let thread = "questions"

    /// Becomes the delegate. Call once, as the app starts.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
        lock.lock()
        isInstalled = true
        lock.unlock()
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
        content.threadIdentifier = thread
        content.targetContentIdentifier = nudge.taskID
        content.userInfo = [taskKey: nudge.taskID]
        return content
    }

    public func post(_ nudge: QuestionNudge, after delay: TimeInterval) {
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        let request = UNNotificationRequest(identifier: nudge.id, content: Self.content(for: nudge), trigger: trigger)
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

    public func removeAll() {
        // Only the app's own notifier, made the delegate at launch, has a
        // notification center; anywhere else, as in a test, there is none.
        guard installed else { return }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.filter { $0.content.threadIdentifier == Self.thread }.map(\.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
        }
        UNUserNotificationCenter.current().getDeliveredNotifications { shown in
            let ids = shown.map(\.request).filter { $0.content.threadIdentifier == Self.thread }.map(\.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
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

    /// With the app in front a question is already pinned on Today, so its
    /// nudge shows nothing more. Anything else shows as it would anyway.
    ///
    /// The completion forms, not the async ones: the system must hear back
    /// on the thread it called on, and an async method answers from
    /// another, which stops the app as it opens.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentation(inThread: notification.request.content.threadIdentifier))
    }

    /// How a notification shows while the app is in front.
    static func presentation(inThread thread: String) -> UNNotificationPresentationOptions {
        thread == Self.thread ? [] : [.banner, .list, .sound]
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
    @Environment(\.dynamicTypeSize) private var typeSize
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
                    LabeledRow(stacked: ConfirmationSheet.stacksLabels(at: typeSize), labelWidth: labelWidth,
                               spacing: 10) {
                        Text(row.label)
                            .foregroundStyle(Theme.secondaryText)
                    } value: {
                        Text(row.value)
                            .foregroundStyle(.primary)
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

/// A label and its value: side by side, the label in a column of its own,
/// or the label over the value when the text is so large a column would
/// leave the value a sliver.
struct LabeledRow<Label: View, Value: View>: View {
    let stacked: Bool
    let labelWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let label: () -> Label
    @ViewBuilder let value: () -> Value

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                label()
                    .fixedSize(horizontal: false, vertical: true)
                value()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: spacing) {
                label()
                    .frame(width: labelWidth, alignment: .leading)
                value()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
