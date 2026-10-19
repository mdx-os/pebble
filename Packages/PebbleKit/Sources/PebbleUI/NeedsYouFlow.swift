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
/// While a cloud preview waits for its answer, nothing is nudged: it
/// covers the screen, so the question couldn't be answered until it is.
///
/// The limit: while the app is suspended in the background nothing here
/// runs, so a nudge already shown stays in Notification Center after its
/// question times out. It goes at the next refresh after that, as the app
/// comes back, and every nudge from before goes as the app starts. Its
/// words name nothing, and opening it never makes anything answerable.
///
/// One per app, from `forApp`, shared by every window's Today: each window
/// says what it has pinned and whether it is in front, and a nudge is
/// posted only while no window is.
@MainActor
final class NeedsYouFlow: ObservableObject {
    let store: TaskStore
    let notifier: (any QuestionNotifying)?
    private let agentName: () -> String
    private let now: () -> Date

    /// A flow made by `forApp`, held weakly: the windows that use it keep
    /// it, and it goes when the last of them does.
    private struct Made {
        weak var flow: NeedsYouFlow?
    }

    /// Every flow `forApp` made, by the store it was made for. A flow holds
    /// its store, so while an entry's flow lives no other store can take
    /// that store's identity.
    private static var made: [ObjectIdentifier: Made] = [:]

    /// The app's one flow for `store`. A second window gets the same one,
    /// so it never takes away the first one's nudges or its taps. Another
    /// store, as in a test, gets a flow of its own.
    static func forApp(store: TaskStore, notifier: (any QuestionNotifying)?,
                       agentName: @escaping () -> String) -> NeedsYouFlow {
        made = made.filter { $0.value.flow != nil }
        if let flow = made[ObjectIdentifier(store)]?.flow, flow.store === store { return flow }
        let flow = NeedsYouFlow(store: store, notifier: notifier, agentName: agentName)
        made[ObjectIdentifier(store)] = Made(flow: flow)
        return flow
    }

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

    /// A question pinned now, the task that asked it, and the rule it was
    /// asked through, for its time left. Its nudge is made only as it is
    /// sent, so it says the name the person has chosen by then.
    private struct Waiting {
        let taskID: String
        let question: ConfirmationRequest
        let rule: AskFirst
        var id: String { QuestionNudge.nudgeID(for: question) }
    }

    /// What one window's Today has told the flow.
    private struct Window {
        var active = true
        var waiting: [Waiting] = []
        var previewWaiting = false
    }

    /// Every window, by its Today's token. A token is never used twice, so
    /// a window that closed late can't take another's place.
    private var windows: [UUID: Window] = [:]
    /// The window that came to the front last. Only it acts on a nudge.
    private var front: UUID?
    /// What each window does when Forget everything runs in any of them.
    private var forgetHooks: [UUID: @MainActor (Forgotten) -> Void] = [:]
    /// Some window is in front, so a waiting question is already on screen.
    var isActive: Bool { windows.isEmpty ? soloActive : windows.values.contains(where: \.active) }
    /// In front or not, before any window has said.
    private var soloActive = true
    /// The questions pinned now, in every window, each once.
    private var waiting: [Waiting] {
        var seen: Set<String> = []
        return windows.values.flatMap(\.waiting).filter { seen.insert($0.id).inserted }
    }
    /// A cloud preview waits for its answer in some window.
    private var previewWaiting: Bool { windows.values.contains(where: \.previewWaiting) }
    /// Every question nudged already, so none is nudged twice.
    private(set) var told: Set<String> = []
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

    /// The tasks whose questions are pinned in `window`'s Needs you, asked
    /// through `rule`. Only these are nudged: a question from another rule
    /// is never pinned, so never nudged.
    func pinned(_ tasks: [AgentTask], rule: AskFirst, from window: UUID) {
        windows[window, default: Window(active: soloActive)].waiting = tasks.compactMap { task in
            task.question.map { Waiting(taskID: task.id, question: $0, rule: rule) }
        }
        update()
    }

    /// A window closed. What it had pinned is no longer on any screen.
    func closed(_ window: UUID) {
        forgetHooks[window] = nil
        if front == window { front = nil }
        guard windows.removeValue(forKey: window) != nil else { return }
        update()
    }

    /// Runs `hook` in `window` whenever Forget everything runs, from any
    /// window, so none keeps what another forgot, and each says the same
    /// about what went.
    func onForget(in window: UUID, _ hook: @escaping @MainActor (Forgotten) -> Void) {
        forgetHooks[window] = hook
    }

    /// True when `window` should act on a nudge just opened: it is the one
    /// that came to the front last, or no window has said.
    func opens(in window: UUID) -> Bool {
        front == nil || front == window
    }

    /// Whether `window` brings a nudge just opened into view. Only the
    /// window in front does. One that can't show it now, as during the
    /// first run or while a cloud preview waits, lets it go, so Today never
    /// jumps to the card much later.
    func takesOpened(in window: UUID, canShow: Bool) -> Bool {
        guard focus != nil, opens(in: window) else { return false }
        guard canShow else {
            focus = nil
            return false
        }
        return true
    }

    /// Brings the card for `id` into view in `window`, a beat after its
    /// nudge was opened, then lets go. Only if it is still the one to bring
    /// in, so a nudge `takesOpened` let go in the meantime never scrolls
    /// Today or moves VoiceOver to a card behind the first run or a cover,
    /// and only while its question is still pinned.
    func bringIntoView(_ id: String, in window: UUID, scroll: (String) -> Void, focusCard: (String) -> Void) {
        guard focus == id, opens(in: window) else { return }
        guard isWaiting(id) else {
            focus = nil
            return
        }
        scroll(id)
        focusCard(id)
        focus = nil
    }

    /// A cloud preview in `window` started or stopped waiting for its
    /// answer. Once none waits, a question may nudge again.
    func preview(waiting: Bool, from window: UUID) {
        guard windows[window]?.previewWaiting != waiting else { return }
        windows[window, default: Window(active: soloActive)].previewWaiting = waiting
        postIfAway()
    }

    private func update() {
        let waiting = waiting
        let open = Set(waiting.map(\.id))
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
            // The offer has gone from under VoiceOver either way, so a line
            // is said either way.
            if granted { self.announce(NudgeWords.on) } else { self.sayNudgesAreOff(NudgeWords.offBySystem) }
            self.asking = nil
            self.postIfAway()
        }
    }

    /// No thanks to the offer. It is never shown again.
    func declineNudges() {
        offersNudges = false
        store.setNudges(.declined)
        sayNudgesAreOff(NudgeWords.off)
    }

    /// The offer goes from under VoiceOver, so the line that takes its
    /// place is said as well as shown.
    private func sayNudgesAreOff(_ line: String) {
        nudgeNote = line
        announce(line)
    }

    /// Waits for the system's answers, for tests.
    func settled() async {
        await asking?.value
        await checking?.value
    }

    /// A window came to the front or went away; with no window given,
    /// every one. In front, the questions are on screen, so their nudges
    /// go, and one taken away before it showed may nudge the next time.
    /// Once every window is away, each waiting question gets one, after a
    /// short wait.
    func scene(isActive active: Bool, from window: UUID? = nil) {
        if let window {
            windows[window, default: Window()].active = active
            if active { front = window } else if front == window { front = nil }
        } else {
            soloActive = active
            for id in windows.keys { windows[id]?.active = active }
        }
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

    /// The person opened a nudge: bring its task into view. Only a task
    /// whose question is pinned now; a tap for one that timed out, was
    /// answered, or was never pinned does nothing, so Today never jumps to
    /// a card that has nothing to ask. Either way nothing becomes
    /// answerable: a question opens only from its card, while it is still
    /// pinned.
    func opened(_ taskID: String) {
        guard isWaiting(taskID) else { return }
        focus = taskID
    }

    /// True while `taskID`'s question is pinned in some window.
    private func isWaiting(_ taskID: String) -> Bool {
        windows.values.contains { $0.waiting.contains { $0.taskID == taskID } }
    }

    /// What Forget everything took, as every window is told.
    struct Forgotten: Equatable {
        /// Something was there to forget: a task, a receipt or a saved task.
        var something = false
        /// The line kept on Today while a step said yes to may be done.
        var underway: String?
    }

    /// Forget everything: receipts and saved tasks go, and so does every
    /// nudge about a question, from this launch or before, and a nudge
    /// opened and not yet handed over. Every window is told what went, so
    /// none keeps what another forgot and all say the same.
    func forget(_ forgotten: Forgotten = Forgotten()) {
        notifier?.forget()
        posted = [:]
        told = []
        focus = nil
        store.forget()
        for hook in forgetHooks.values { hook(forgotten) }
    }

    private func postIfAway() {
        guard !isActive, !previewWaiting, store.nudges == .allowed, let notifier else { return }
        for item in waiting where !told.contains(item.id) {
            // Left for next time, when it will have less time still.
            guard let left = item.rule.timeLeft(item.question), left >= Self.leastTimeLeft else { continue }
            let nudge = QuestionNudge(question: item.question, taskID: item.taskID, agentName: agentName())
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
/// The few things a nudge needs from the system's notification center, so
/// tests can stand in for it. Shown notifications are given as their
/// requests, which is all that is read of them.
protocol NudgeCenter: AnyObject, Sendable {
    /// What the system allows now, without asking.
    func authorization() async -> UNAuthorizationStatus
    /// Asks the system, which shows its own question the first time.
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async
    func pending() async -> [UNNotificationRequest]
    func delivered() async -> [UNNotificationRequest]
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
}

/// The system's own notification center.
final class SystemNudgeCenter: NudgeCenter, @unchecked Sendable {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: UNNotificationRequest) async { try? await center.add(request) }
    func pending() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func delivered() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

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
    /// The center nudges go to. Only the app's own notifier, made the
    /// delegate at launch, has the system's; anywhere else, as in a test,
    /// there is none unless one is given.
    private var center: (any NudgeCenter)?

    override init() {}

    /// A notifier that uses `center`, for tests.
    init(center: any NudgeCenter) {
        self.center = center
    }

    /// True once there is a notification center to use.
    var installed: Bool { currentCenter != nil }

    private var currentCenter: (any NudgeCenter)? {
        lock.lock()
        defer { lock.unlock() }
        return center
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
        if center == nil { center = SystemNudgeCenter() }
        lock.unlock()
    }

    /// Through the center, like everything else here, so a notifier with
    /// none never reaches for the system's.
    public func permission() async -> NudgePermission {
        guard let center = currentCenter else { return .notDetermined }
        switch await center.authorization() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    public func requestPermission() async -> Bool {
        guard let center = currentCenter else { return false }
        return await center.requestAuthorization()
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
        guard let center = currentCenter else { return }
        let stamp = stamp(for: nudge.id)
        #if os(iOS)
        // Posted as the app goes to the background, so it asks for a moment
        // more, or it could be suspended before the system has the nudge.
        // Asked for here, while the move to the background is still being
        // handled, not after a hop. If the moment runs out first, it is
        // given back all the same.
        let moment = BackgroundMoment.begunHere()
        #endif
        let adding = Task { @MainActor in
            let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
            let request = UNNotificationRequest(identifier: nudge.id, content: Self.content(for: nudge), trigger: trigger)
            #if os(iOS)
            let moment = moment ?? BackgroundMoment.begun()
            #endif
            await center.add(request)
            self.takeBackIfCleared(nudge.id, postedAt: stamp)
            #if os(iOS)
            moment.end()
            #endif
        }
        lock.lock()
        lastPost = adding
        lock.unlock()
    }

    /// The last nudge on its way to the system, until it lands and has been
    /// taken back if it had to be. Tests wait on it.
    var posting: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return lastPost
    }
    private var lastPost: Task<Void, Never>?

    /// Goes up each time every nudge is taken away, and `generations` each
    /// time one is, so a nudge still on its way to the system then is taken
    /// away once it lands.
    private var round = 0
    private var generations: [String: Int] = [:]

    private func stamp(for id: String) -> (round: Int, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (round, generations[id, default: 0])
    }

    private func takeBackIfCleared(_ id: String, postedAt posted: (round: Int, generation: Int)) {
        guard stamp(for: id) != posted else { return }
        remove([id])
    }

    public func remove(_ ids: [String]) {
        guard let center = currentCenter else { return }
        lock.lock()
        for id in ids { generations[id, default: 0] += 1 }
        lock.unlock()
        center.removePending(ids)
        center.removeDelivered(ids)
    }

    /// Takes away both kinds, the ones still to come and the ones shown,
    /// and only in the questions' thread: anything else the app may show
    /// stays.
    public func removeAll() {
        guard let center = currentCenter else { return }
        lock.lock()
        round += 1
        lock.unlock()
        let clearing = Task {
            let pending = await center.pending().filter { $0.content.threadIdentifier == Self.thread }.map(\.identifier)
            if !pending.isEmpty { center.removePending(pending) }
            let shown = await center.delivered().filter { $0.content.threadIdentifier == Self.thread }.map(\.identifier)
            if !shown.isEmpty { center.removeDelivered(shown) }
        }
        lock.lock()
        lastClear = clearing
        lock.unlock()
    }

    /// The last `removeAll` under way, until both kinds are gone. Tests
    /// wait on it.
    var clearing: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return lastClear
    }
    private var lastClear: Task<Void, Never>?

    public func forget() {
        lock.lock()
        waitingOpen = nil
        lock.unlock()
        removeAll()
    }

    /// The hand over of a nudge opened before anything listened, while it
    /// is on its way. Nil when nothing was waiting. Tests wait on it.
    var handOver: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return handingOver
    }
    private var handingOver: Task<Void, Never>?

    public func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.lock()
        self.handler = handler
        let waiting = waitingOpen
        waitingOpen = nil
        handingOver = waiting.map { waiting in Task { @MainActor in handler(waiting) } }
        lock.unlock()
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

#if os(iOS)
/// A moment more of running in the background, ended once, by its owner
/// or by the system when the moment runs out.
@MainActor
private final class BackgroundMoment {
    private var id = UIBackgroundTaskIdentifier.invalid

    /// A moment begun now, when called on the main thread, as the flow
    /// always calls. Nil anywhere else, for the caller to begin one there.
    nonisolated static func begunHere() -> BackgroundMoment? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { begun() }
    }

    static func begun() -> BackgroundMoment {
        let moment = BackgroundMoment()
        moment.begin()
        return moment
    }

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "nudge") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
#endif

/// The one time offer, shown in Needs you while a question waits.
struct NudgeOffer: View {
    @ObservedObject var flow: NeedsYouFlow

    var body: some View {
        if flow.offersNudges {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label {
                    Text(NudgeWords.offerTitle)
                        .font(Theme.TypeScale.displayHeadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(Theme.accentSymbol)
                        .accessibilityHidden(true)
                }
                Text(NudgeWords.offerDetail)
                    .font(Theme.TypeScale.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.xs) { buttons }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) { buttons }
                }
                .padding(.top, 2)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("nudgeOffer")
        } else if let note = flow.nudgeNote {
            Text(note)
                .font(Theme.TypeScale.subheadline)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 92
    /// For tests: the rows' and the header's layout set by hand, so the
    /// layout a text size picks can be told from the others at that size.
    var rowsStack: Bool?
    var headerStacks: Bool?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
    }

    /// At accessibility sizes the label, the example marker and the time
    /// each get a line, so none is squeezed. The marker is what says that
    /// nothing really happened, so it must always be read whole.
    static func stacksHeader(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    @ViewBuilder
    private var header: some View {
        let label = Label {
            Text(ReceiptWords.label)
        } icon: {
            Image(systemName: FeedCard.symbol(.receipt))
                .foregroundStyle(Theme.accentSymbol)
        }
        .font(Theme.TypeScale.footnote.weight(.semibold))
        .foregroundStyle(Theme.secondaryText)
        let marker = Text(FeedWords.exampleMarker)
            .font(Theme.TypeScale.caption.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
        let when = Text(time)
            .font(Theme.TypeScale.footnote)
            .foregroundStyle(Theme.secondaryText)
        if headerStacks ?? Self.stacksHeader(at: typeSize) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                label
                    .fixedSize(horizontal: false, vertical: true)
                if receipt.isSample { marker.fixedSize(horizontal: false, vertical: true) }
                when
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                label
                if receipt.isSample { marker }
                Spacer(minLength: Theme.Space.xs)
                when
            }
        }
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                header
                Text(receipt.title)
                    .font(Theme.TypeScale.displayHeadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(receipt.line)
                    .font(Theme.TypeScale.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            // The receipt as the UI tests find it: one element, its words
            // the summary VoiceOver reads.
            .accessibilityIdentifier("receipt")
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(rows, id: \.label) { row in
                    LabeledRow(stacked: rowsStack ?? ConfirmationSheet.stacksLabels(at: typeSize), labelWidth: labelWidth,
                               spacing: Theme.Space.s) {
                        Text(row.label)
                            .foregroundStyle(Theme.secondaryText)
                    } value: {
                        Text(row.value)
                            .foregroundStyle(.primary)
                    }
                    .font(Theme.TypeScale.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
            // Says which receipt it clears, so with several on Today the
            // buttons aren't all just "Clear". Voice Control still takes
            // the word on the button.
            Button(TaskWords.dismissTitle, action: onClear)
                .buttonStyle(CardButtonStyle(kind: .quiet))
                .accessibilityLabel(receipt.clearLabel)
                .accessibilityInputLabels([Text(TaskWords.dismissTitle), Text(receipt.clearLabel)])
                .accessibilityHint(ReceiptWords.clearHint)
                .accessibilityIdentifier("clearReceipt")
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receiptCard")
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
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
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
