import Foundation
import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// Everything the Today screen shows and does, kept apart from the view so
/// tests can drive it.
///
/// Questions are answered only through `ConfirmationSheet`, with the rule
/// that asked them. Nothing here can approve anything.
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var feed: Feed
    /// The question open in the confirmation sheet.
    @Published var reviewing: ConfirmationRequest?
    /// The result open to read.
    @Published var reading: FeedItem?
    /// A summary whose sources are open to read.
    @Published var readingSources: ReconSummary?
    /// A summary whose points are open to choose one to remember.
    @Published var choosingPoint: ReconSummary?
    /// Points kept in memory from this screen, by `rememberKey`.
    @Published private(set) var remembered: Set<String> = []
    /// The summary, and so the task, each kept point came from.
    private var rememberedFrom: [String: String] = [:]
    /// What happened to the last Remember tap, such as "Saved. It stays on this device."
    @Published private(set) var rememberStatus: String?

    let needsYou: NeedsYou
    /// Runs "look into this" as tasks. The same object as `tasks` when set.
    let recon: ReconRunner?
    /// Where a point goes when the person taps Remember. Nothing is saved any other way.
    private let memory: MemoryStore?
    /// Chooses how the next summary is put together: on this device, or
    /// through the cloud's preview when the person turned the cloud on.
    var summarizer: @MainActor () -> any ReconSummarizer = { LocalReconSummarizer() }
    /// Long work shown on live task cards. Nil when nothing is running. Its
    /// questions reach the feed only when it asks through the rule of
    /// `needsYou`.
    let tasks: (any TaskEngine)?
    /// Moves a scripted engine's clock with real time, for the live showcase.
    let drivesTasks: Bool
    private let sources: [any FeedSource]
    private let calendar: Calendar
    let now: () -> Date
    private var watching: TaskObservation?
    private var announcer = TaskAnnouncer()
    /// The newest snapshot taken in, so one that arrives late is dropped.
    private var seen = -1
    /// Live progress for each task's card, by id. Kept out of `feed`, so a
    /// tick redraws only the card it belongs to.
    private var progress: [String: LiveProgress] = [:]
    /// The tasks as the feed holds them, without progress, to tell a real
    /// change from a tick.
    private var cards: [AgentTask] = []
    /// Ids of every task, so `isSample` needn't ask the engine.
    private var taskIDs: Set<String> = []
    /// What each task's card is in the middle of, by id: its Change course
    /// field, the words in it, and where focus goes. Kept here, not in the
    /// card, so a card moving to another section keeps it.
    private var cardStates: [String: TaskCardState] = [:]
    /// Which section each task's card was in at the last build.
    private var sections: [String: String] = [:]
    /// The task as it was when a note went on its card. The note goes once
    /// the task moves on.
    private var notedAs: [String: AgentTask] = [:]
    /// Which task asked each question opened from a task card, so a yes goes
    /// back where it came from. Only while the question may still be used.
    private var askedBy: [UUID: String] = [:]
    /// Every question ever opened from a task card, by the task that asked,
    /// kept after redirect, stop, close or forget take it from `askedBy`. A
    /// yes that comes late is then still known as the task's, and never
    /// falls through to `NeedsYou`. Holds only ids, nothing a task said.
    private var taskAsked: [UUID: String] = [:]
    /// Kept on Today after Forget everything, while a step the person said
    /// yes to may have happened. Names nothing the task held.
    @Published private(set) var forgotUnderway: String?
    /// True from forgetting every task until a new one starts, so the
    /// memory screen can say the tasks are gone.
    @Published private(set) var tasksForgotten = false
    private let clock: () -> ContinuousClock.Instant
    /// Says a line to VoiceOver. Tests replace it to hear what would be said.
    var announce: @MainActor (TaskAnnouncer.Line) -> Void = FeedModel.post

    init(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)? = nil,
         drivesTasks: Bool = false, memory: MemoryStore? = nil, calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() },
         clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.sources = sources
        self.needsYou = needsYou
        self.tasks = tasks
        self.recon = tasks as? ReconRunner
        self.memory = memory
        self.drivesTasks = drivesTasks
        self.calendar = calendar
        self.now = now
        self.clock = clock
        feed = Feed.build(from: sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        let list = tasks?.tasks ?? []
        track(list)
        sections = Self.sections(of: feed)
        _ = announcer.lines(for: list, at: clock())
        watching = tasks?.observe { [weak self] snapshot in
            // Engines tell us on whatever thread they run. Hop to the main
            // one, without a wait when already there. A hop doesn't promise
            // order, so `tasksChanged` drops a snapshot older than one it took.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.tasksChanged(snapshot) }
            } else {
                Task { @MainActor in self?.tasksChanged(snapshot) }
            }
        }
    }

    var isSample: Bool { sources.contains { $0.isSample } || tasks?.isSample == true }

    /// True when this card came from an example source or a scripted engine.
    func isSample(_ item: FeedItem) -> Bool {
        if let tasks, tasks.isSample, taskIDs.contains(item.id) { return true }
        return sources.contains { $0.isSample && $0.items(now: now()).contains { $0.id == item.id } }
    }

    /// The live progress a task's card reads. Ticks change it, never `feed`.
    func liveProgress(_ id: String) -> LiveProgress {
        if let live = progress[id] { return live }
        let live = LiveProgress(tasks?.tasks.first { $0.id == id }?.progress ?? .indeterminate)
        progress[id] = live
        return live
    }

    /// What a task's card is in the middle of. The same object for as long
    /// as the task is here, whichever section its card is in.
    func cardState(_ id: String) -> TaskCardState {
        if let state = cardStates[id] { return state }
        let state = TaskCardState()
        cardStates[id] = state
        return state
    }

    /// True while there is any task to forget.
    var hasTasks: Bool { !taskIDs.isEmpty }

    /// True only while this task's question is pinned in Needs you, the one
    /// place its Approve can open the sheet. A question asked through
    /// another rule, or one the rule closed before the engine noticed,
    /// shows the waiting line with no button.
    func canApprove(_ task: AgentTask) -> Bool {
        guard let question = task.question, !rule.isClosed(question) else { return false }
        return feed.needsYou.contains { $0.task?.question?.id == question.id }
    }

    /// The rule for every question in the sheet, a task's included.
    var rule: AskFirst { needsYou.rule }

    /// Builds the feed again. Questions that timed out drop away here.
    func refresh() {
        tasks?.refresh()
        rebuild()
    }

    private func rebuild() {
        let next = Feed.build(from: sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        if next != feed { feed = next }
        followCards()
    }

    /// Each task card's section: Needs you, Working on it, or a time group.
    static func sections(of feed: Feed) -> [String: String] {
        var out: [String: String] = [:]
        for item in feed.needsYou where item.task != nil { out[item.id] = "needsYou" }
        for item in feed.working where item.task != nil { out[item.id] = "working" }
        for group in feed.groups {
            for item in group.items where item.task != nil { out[item.id] = "group:\(group.id)" }
        }
        return out
    }

    /// A card that moves to another section is a new view, so its field
    /// and focus are carried over here. A task that ended closes its field,
    /// since half typed words have nowhere to go. Either way, if the person
    /// was on the card, VoiceOver goes to its summary in the new place.
    private func followCards() {
        let next = Self.sections(of: feed)
        defer { sections = next }
        for (id, state) in cardStates {
            let ended = cards.first { $0.id == id }.map { !$0.isActive } ?? false
            let moved = sections[id] != nil && next[id] != nil && sections[id] != next[id]
            if ended && state.redirecting {
                state.closeField()
            } else if moved && (state.redirecting || state.hasVoiceOver) {
                state.pendingKeyboard = state.redirecting && state.typing
                state.pendingFocus = .summary
            }
        }
    }

    /// Moves a scripted engine along, for the live showcase and for recons
    /// played on the scripted engine.
    func tick(_ seconds: TimeInterval) {
        if let recon {
            recon.advance(by: seconds)
        } else {
            (tasks as? LocalFakeEngine)?.advance(by: seconds)
        }
    }

    func tasksChanged(_ snapshot: TaskSnapshot) {
        guard snapshot.sequence > seen else { return }
        seen = snapshot.sequence
        if track(snapshot.tasks) { rebuild() }
        for line in announcer.lines(for: snapshot.tasks, at: clock()) { announce(line) }
    }

    /// Moves each card's live progress along. True when anything but
    /// progress changed, so the feed needs building again.
    @discardableResult
    private func track(_ list: [AgentTask]) -> Bool {
        for task in list {
            if let live = progress[task.id], live.value != task.progress { live.value = task.progress }
        }
        let ids = Set(list.map(\.id))
        progress = progress.filter { ids.contains($0.key) }
        cardStates = cardStates.filter { ids.contains($0.key) }
        // A result open to read whose task went away, as when the oldest
        // ended tasks are let go, closes with it.
        if let reading, taskIDs.contains(reading.id), !ids.contains(reading.id) { self.reading = nil }
        // So do a summary's sources and its points, and what was kept from it.
        let before = taskIDs
        closeSummaries { before.contains($0) && !ids.contains($0) }
        taskIDs = ids
        if !ids.isEmpty && tasksForgotten { tasksForgotten = false }
        let next = list.map(\.card)
        defer { cards = next }
        // A note stays only until its task moves on.
        for task in next where notedAs[task.id] != nil && notedAs[task.id] != task {
            notedAs[task.id] = nil
            cardStates[task.id]?.note = nil
        }
        notedAs = notedAs.filter { ids.contains($0.key) }
        return next != cards
    }

    /// What a card's button does. Talking is handed to the screen around
    /// the feed, which owns the chat. Only a question pinned by `NeedsYou`
    /// opens the question sheet.
    func perform(_ item: FeedItem, talk: (String) -> Void) {
        switch item.action {
        case .review(let request):
            if feed.needsYou.contains(where: { $0.request?.id == request.id }) { reviewing = request }
        case .open: reading = item
        case .talk(let line): talk(line)
        case .task(let task):
            if task.question != nil { review(task) } else { open(task) }
        case .lookInto(let topic):
            // Without a runner, the chat offers it instead, still one tap away.
            if recon == nil || !lookInto(topic) { talk(ReconWords.askLine(topic)) }
        case nil: break
        }
    }

    // MARK: Looking into something

    /// Starts looking into `topic`, after the person's tap. False when
    /// nothing started, as for words of crisis.
    @discardableResult
    func lookInto(_ topic: String) -> Bool {
        guard let recon, recon.lookInto(topic, with: summarizer()) != nil else { return false }
        refresh()
        return true
    }

    /// The summary a finished recon card shows.
    func summary(for task: AgentTask) -> ReconSummary? {
        recon?.summary(for: task.id)
    }

    /// A recon reads for one topic, so its card offers Stop but not Change course.
    func canRedirect(_ task: AgentTask) -> Bool {
        recon?.isRecon(task.id) != true
    }

    /// Opens the chat with a follow-up ready. Nothing is sent until the person sends it.
    func followUp(_ summary: ReconSummary, talk: (String) -> Void) {
        talk(ReconWords.followUpDraft(summary.topic))
    }

    static func rememberKey(_ summary: ReconSummary, _ point: ReconPoint) -> String {
        "\(summary.id)/\(point.id)"
    }

    func isRemembered(_ point: ReconPoint, in summary: ReconSummary) -> Bool {
        remembered.contains(Self.rememberKey(summary, point))
    }

    /// Keeps one point in memory, with where it came from, through the same
    /// store the memory screen uses. Only a tap on Remember this calls it.
    @discardableResult
    func remember(_ point: ReconPoint, in summary: ReconSummary) -> Bool {
        guard summary.points.contains(point), !isRemembered(point, in: summary) else { return false }
        guard let memory else {
            rememberStatus = MemoryWords.couldNotOpen
            return false
        }
        let publisher = point.sourceIDs.first.flatMap(summary.source)?.publisher ?? ""
        do {
            switch try memory.remember(summary.note(for: point), source: .lookedUp(publisher)) {
            case .saved:
                remembered.insert(Self.rememberKey(summary, point))
                rememberedFrom[Self.rememberKey(summary, point)] = summary.id
                rememberStatus = MemoryWords.saved
                return true
            case .tooLong:
                rememberStatus = MemoryWords.tooLong
            case .needsWords, .notFound:
                rememberStatus = MemoryWords.needsWords
            }
        } catch is MemoryStore.Unavailable {
            rememberStatus = MemoryWords.unavailable
        } catch is MemoryStore.Unreadable {
            rememberStatus = MemoryWords.unreadable
        } catch {
            rememberStatus = MemoryWords.couldNotOpen
        }
        return false
    }

    func clearRememberStatus() {
        rememberStatus = nil
    }

    /// Closes the sources and points of every summary whose task id matches,
    /// and lets go of which of its points were kept, since the card is gone.
    private func closeSummaries(where gone: (String) -> Bool) {
        if let open = readingSources, gone(open.id) { readingSources = nil }
        if let open = choosingPoint, gone(open.id) { choosingPoint = nil }
        let goneKeys = rememberedFrom.filter { gone($0.value) }.keys
        guard !goneKeys.isEmpty else { return }
        for key in goneKeys { rememberedFrom[key] = nil }
        remembered.subtract(goneKeys)
    }

    // MARK: Task cards

    /// Approve opens the same question sheet as any other question, with the
    /// rule of `needsYou`. Only the engine's own task, with its question
    /// pinned in Needs you, opens it. Only a yes there, checked by
    /// `AskFirst`, lets the task go on.
    ///
    /// An Approve left on screen after its question timed out, with nothing
    /// to build the feed again, looks again here: the task settles, and its
    /// card says the question timed out, so the tap is never lost.
    func review(_ task: AgentTask) {
        guard let live = current(task), let question = live.question else { return }
        guard canApprove(live) else {
            if rule.isClosed(question) {
                refresh()
                note(TaskWords.questionTimedOut, on: live.id)
            }
            return
        }
        askedBy[question.id] = live.id
        taskAsked[question.id] = live.id
        reviewing = question
    }

    /// New instructions. Never needs a yes. Any open question is withdrawn.
    @discardableResult
    func redirect(_ task: AgentTask, with words: String) -> Bool {
        let done = tasks?.redirect(task.id, with: words) ?? false
        if let question = task.question { askedBy[question.id] = nil }
        if let reviewing, reviewing.id == task.question?.id { self.reviewing = nil }
        refresh()
        return done
    }

    /// Stops at once. Never needs a yes.
    func stop(_ task: AgentTask) {
        tasks?.stop(task.id)
        if let question = task.question { askedBy[question.id] = nil }
        if let reviewing, reviewing.id == task.question?.id { self.reviewing = nil }
        refresh()
    }

    func retry(_ task: AgentTask) {
        tasks?.retry(task.id)
        refresh()
    }

    /// Takes an ended card away, and everything the task held.
    func dismiss(_ task: AgentTask) {
        guard tasks?.dismiss(task.id) == true else { return }
        if reading?.id == task.id { reading = nil }
        closeSummaries { $0 == task.id }
        refresh()
    }

    /// Forget everything: every task goes, with its steps and the words the
    /// person gave it, and anything still going stops. Any open task question
    /// is withdrawn and its sheet closed.
    ///
    /// A step the person said yes to may be under way, so a short line
    /// stays on Today to say it may be done. It names nothing the task held.
    @discardableResult
    func forgetTasks() -> ClearedTasks {
        guard let tasks else { return .none }
        if let reviewing, askedBy[reviewing.id] != nil || tasks.tasks.contains(where: { $0.question?.id == reviewing.id }) {
            self.reviewing = nil
        }
        if let reading, taskIDs.contains(reading.id) { self.reading = nil }
        // Every summary goes with its recon, so its sheets close too.
        closeSummaries { _ in true }
        rememberStatus = nil
        askedBy.removeAll()
        let cleared = tasks.clear()
        refresh()
        if cleared.forgotten > 0 { tasksForgotten = true }
        if let line = cleared.underwayLine {
            forgotUnderway = line
            announce(TaskAnnouncer.Line(text: line, urgent: true))
        }
        return cleared
    }

    /// The person has read the line kept after forgetting.
    func dismissForgotUnderway() {
        forgotUnderway = nil
    }

    /// The finished result, in the same reader as other results.
    func open(_ task: AgentTask) {
        guard let result = task.result else { return }
        reading = FeedItem(id: task.id, kind: .ready, time: task.updatedAt, title: task.title,
                           body: task.step, action: .open(result))
    }

    private func current(_ task: AgentTask) -> AgentTask? {
        tasks?.tasks.first { $0.id == task.id }
    }

    /// The sheet said yes. The card goes and the approval is handed back to
    /// where the question came from: the task whose card opened it, which
    /// checks it with `AskFirst`, or else `NeedsYou`. A task's yes never
    /// falls through to `NeedsYou`, even if the task has moved on.
    ///
    /// A yes the task couldn't use did nothing, so its card says so rather
    /// than leave the person wondering. A late one says so in its history.
    func approved(_ approval: Approval) {
        var refusedBy: String?
        if let id = askedBy.removeValue(forKey: approval.id) {
            if tasks?.resume(id, with: approval) ?? .refused == .refused { refusedBy = id }
        } else if let id = taskAsked[approval.id] {
            // The task moved on before this yes came. It does nothing, and
            // never goes to `NeedsYou`.
            refusedBy = id
        } else {
            needsYou.approved(approval)
        }
        reviewing = nil
        refresh()
        if let refusedBy { note(TaskWords.yesNotUsed, on: refusedBy) }
    }

    /// Puts a line on a task's card, and says it, until the task moves on.
    private func note(_ line: String, on id: String) {
        guard let task = cards.first(where: { $0.id == id }) else { return }
        cardState(id).note = line
        notedAs[id] = task
        announce(TaskAnnouncer.Line(text: line, urgent: true))
    }

    /// The sheet closed without a yes, by Not now, Close, or going away.
    /// The sheet has already withdrawn the question.
    func closedQuestion(_ request: ConfirmationRequest) {
        askedBy[request.id] = nil
        needsYou.dismissed(request)
        tasks?.questionClosed(request)
        if reviewing?.id == request.id { reviewing = nil }
        refresh()
    }

    /// Posts a line to VoiceOver: politely for a new step, so it waits its
    /// turn, and at the usual priority when the person is needed or a task ends.
    static func post(_ line: TaskAnnouncer.Line) {
        var text = AttributedString(line.text)
        text.accessibilitySpeechAnnouncementPriority = line.urgent ? .default : .low
        AccessibilityNotification.Announcement(text).post()
    }

    /// "8:52 AM" today, "Yesterday", then the day of the week in the past
    /// week, then the date. Any day but today says which day.
    func timeLabel(for time: Date) -> String {
        let today = now()
        if calendar.isDate(time, inSameDayAs: today) {
            return time.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(time, inSameDayAs: yesterday) {
            return FeedWords.yesterday
        }
        if time < today, let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: today)),
           time >= weekAgo {
            return time.formatted(.dateTime.weekday(.wide))
        }
        return time.formatted(.dateTime.month(.abbreviated).day())
    }

    var dateLine: String {
        now().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// The home screen after the first run: a calm feed of what the agent did,
/// made and noticed, with anything that needs a yes pinned on top.
struct FeedView: View {
    @ObservedObject var model: FeedModel
    let look: AgentLook
    let onTalk: (String) -> Void
    let onChat: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Two cards side by side once each can be at least this wide. Grows
    /// with the text size, so large text gets one roomy column.
    @ScaledMetric(relativeTo: .body) private var cardMinimum: CGFloat = 320
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = Theme.feedWidth

    static let cardSpacing: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.dateLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        // Said first, so no example is ever taken for real work.
                        if model.isSample && !model.feed.isEmpty {
                            Text(FeedWords.sampleNote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("sampleNote")
                        }
                    }
                    .padding(.bottom, -12)
                    if let line = model.forgotUnderway {
                        ForgotUnderwayNotice(line: line, onDismiss: model.dismissForgotUnderway)
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if model.feed.isEmpty {
                        empty
                            .transition(.opacity)
                    }
                    let columns = Self.columns(
                        for: Self.contentWidth(in: proxy.size.width, column: columnWidth),
                        minimum: cardMinimum, accessibilityText: typeSize.isAccessibilitySize)
                    if model.feed.showsNeedsYou {
                        section(FeedWords.needsYouHeading, detail: FeedWords.needsYouDetail,
                                items: model.feed.needsYou, columns: columns)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("needsYou")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if model.feed.showsWorking {
                        section(TaskWords.workingHeading, detail: TaskWords.workingDetail,
                                items: model.feed.working, columns: columns)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("working")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    ForEach(model.feed.groups) { group in
                        section(group.title, detail: nil, items: group.items, columns: columns)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableColumn(columnWidth)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.9),
                           value: model.feed)
            }
        }
        .background(Backdrop())
        .navigationTitle(FeedWords.title)
        .task {
            // Questions time out on their own, so look again now and then.
            // Stops when the screen goes away.
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
        // Scripted tasks are played in real time by `HomeView`, so they go
        // on while the person is in the chat or memory.
    }

    /// The room the cards have: the window's width, held to the reading
    /// column, less the gutters `readableColumn` adds.
    static func contentWidth(in width: CGFloat, column: CGFloat) -> CGFloat {
        max(0, min(width, column) - 2 * Theme.gutter)
    }

    /// How many cards fit side by side, each at least `minimum` wide. One
    /// plain column at accessibility text sizes or when even one card at
    /// `minimum` would not fit, and never more than two.
    static func columnCount(for width: CGFloat, minimum: CGFloat, accessibilityText: Bool) -> Int {
        guard !accessibilityText, minimum > 0 else { return 1 }
        let fit = Int((width + cardSpacing) / (minimum + cardSpacing))
        return min(2, max(1, fit))
    }

    /// Flexible columns share whatever width there is, so a card is never
    /// wider than the screen, whatever the text size.
    static func columns(for width: CGFloat, minimum: CGFloat, accessibilityText: Bool) -> [GridItem] {
        let count = columnCount(for: width, minimum: minimum, accessibilityText: accessibilityText)
        return Array(repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top), count: count)
    }

    private func section(_ title: String, detail: String?, items: [FeedItem], columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(items) { item in
                    Group {
                        if let task = item.task, let summary = model.summary(for: task) {
                            ReconCard(summary: summary, time: model.timeLabel(for: item.time),
                                      gathered: ReconWords.gathered(summary.gatheredAt, now: model.now()),
                                      isSample: model.isSample(item),
                                      onOpenSources: { model.readingSources = summary },
                                      onFollowUp: { model.followUp(summary, talk: onTalk) },
                                      onRemember: { model.choosingPoint = summary },
                                      onDismiss: { model.dismiss(task) })
                        } else if let task = item.task {
                            // Keyed by the task's id, reading live progress
                            // from the model, so a tick redraws only this card.
                            TaskCard(task: task, time: model.timeLabel(for: item.time),
                                     progress: model.liveProgress(task.id),
                                     state: model.cardState(task.id),
                                     canApprove: model.canApprove(task),
                                     isSample: model.isSample(item),
                                     canRedirect: model.canRedirect(task),
                                     onApprove: { model.review(task) },
                                     onRedirect: { model.redirect(task, with: $0) },
                                     onStop: { model.stop(task) },
                                     onRetry: { model.retry(task) },
                                     onOpen: { model.open(task) },
                                     onDismiss: { model.dismiss(task) })
                        } else {
                            FeedCard(item: item, time: model.timeLabel(for: item.time)) {
                                model.perform(item, talk: onTalk)
                            }
                        }
                    }
                    .transition(Motion.arrival(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            CharacterView(look: look, size: 72)
            Text(FeedWords.emptyTitle)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(FeedWords.empty)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.readableWidth)
            Button(FeedWords.emptyActionTitle, action: onChat)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .padding(.top, 4)
                .pointerHover(in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .contain)
    }
}

/// One card. A card with something to do is one button: VoiceOver reads the
/// kind, the title, the body and the time as one thought, then what the
/// button does.
struct FeedCard: View {
    let item: FeedItem
    let time: String
    let perform: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let action = item.action {
            Button(action: perform) {
                content(actionTitle: action.title)
            }
            .buttonStyle(SoftPressStyle())
            .pointerHover(in: shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityHint(action.hint)
            // Voice Control users can say the words they see on the card.
            .accessibilityInputLabels([Text(action.title), Text(item.title)])
            .accessibilityAddTraits(.isButton)
        } else {
            content(actionTitle: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    private var asks: Bool { item.kind == .needsYou }

    var spoken: String {
        [item.spokenKind, item.title, item.body, time].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func content(actionTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(item.spokenKind)
                } icon: {
                    Image(systemName: Self.symbol(item.kind))
                        .foregroundStyle(Theme.accent)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(asks ? Theme.onAccent : Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(asks ? Theme.accent : Theme.accent.opacity(0.14), in: Capsule())
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: shape)
        .overlay(shape.stroke(asks ? Theme.accent.opacity(0.55) : Theme.hairline(scheme), lineWidth: asks ? 1.5 : 1))
        .contentShape(shape)
    }

    static func symbol(_ kind: FeedItem.Kind) -> String {
        switch kind {
        case .did: "checkmark.circle.fill"
        case .ready: "doc.text.fill"
        case .noticed: "lightbulb.fill"
        case .needsYou: "hand.raised.fill"
        // Never drawn: a task item is always a `TaskCard`, which picks its
        // symbol by state. Here only so the switch is complete.
        case .task: "circle.fill"
        }
    }
}

/// What stays on Today after Forget everything, while a step the person
/// said yes to may have happened. One plain line and a way to put it away.
struct ForgotUnderwayNotice: View {
    let line: String
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button(TaskWords.forgotUnderwayDismissTitle, action: onDismiss)
                .buttonStyle(CardButtonStyle(kind: .quiet))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline(scheme)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("forgotUnderway")
    }
}

/// A finished result, opened from its card.
struct FeedReader: View {
    let item: FeedItem
    let time: String
    /// True when the card was an example, so the reader says so too.
    var isSample = false
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        if case .open(let text) = item.action { return text }
        return item.body
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isSample {
                        Text(FeedWords.sampleLabel)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .accessibilityIdentifier("sampleLabel")
                    }
                    Label(item.spokenKind, systemImage: FeedCard.symbol(item.kind))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableColumn(Theme.readableWidth)
            }
            .background(Backdrop())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FeedWords.doneTitle) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
