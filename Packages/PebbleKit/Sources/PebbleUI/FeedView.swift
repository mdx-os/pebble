import Foundation
import PebbleCore
#if canImport(SwiftUI)
import Combine
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
    /// A summary whose points are open to choose one to remember. Opening
    /// it looks again at which kept points are still in the notes. An
    /// example's points can't be kept, so its choice never opens.
    @Published var choosingPoint: ReconSummary? {
        didSet {
            guard let summary = choosingPoint else { return }
            guard canRemember(summary) else { choosingPoint = nil; return }
            refreshRemembered()
        }
    }
    /// Points kept in memory from this screen, by `rememberKey`.
    @Published private(set) var remembered: Set<String> = []
    /// The summary, and so the task, each kept point came from.
    private var rememberedFrom: [String: String] = [:]
    /// The note each kept point became, so a note deleted on the memory
    /// screen no longer shows its point as kept.
    private var rememberedAs: [String: UUID] = [:]
    /// Watches the cloud setting, so a change withdraws Today's preview.
    private var cloudWatch: AnyCancellable?
    /// What happened to the last Remember tap, such as "Saved. It stays on this device."
    @Published private(set) var rememberStatus: String? {
        didSet { if rememberStatus != nil { rememberTold += 1 } }
    }
    /// Goes up each time `rememberStatus` is set, so the same words twice,
    /// such as a second "Saved", are still said.
    @Published private(set) var rememberTold = 0

    let needsYou: NeedsYou
    /// Runs "look into this" as tasks. The same object as `tasks` when set.
    let recon: ReconRunner?
    /// Where a point goes when the person taps Remember. Nothing is saved any other way.
    private let memory: MemoryStore?
    /// Chooses how the next summary is put together: on this device, or
    /// through the cloud's preview when the person turned the cloud on.
    var summarizer: @MainActor () -> any ReconSummarizer = { LocalReconSummarizer() }
    /// The preview gate for a summary put together in the cloud. It belongs
    /// to Today alone, as each cloud chat's belongs to that chat, and
    /// `HomeView` shows it over whichever screen is in front.
    let cloudReview = CloudReview()
    /// Long work shown on live task cards. Nil when nothing is running. Its
    /// questions reach the feed only when it asks through the rule of
    /// `needsYou`.
    let tasks: (any TaskEngine)?
    /// Moves a scripted engine's clock with real time, for the live showcase.
    let drivesTasks: Bool
    /// Where the person's words go, passed down from the model so copy that
    /// mentions the device never drifts from it. `HomeView` keeps it up to
    /// date as chats start and the cloud setting changes.
    @Published var place: PrivacyPlace
    private let sources: [any FeedSource]
    /// This model's watch on `needsYou`, ended when the model goes, so a
    /// closed window leaves nothing behind.
    private var observation: NeedsYou.Observation?
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
    /// Each card's summary, or none, as of the last snapshot taken in, so
    /// drawing the feed never walks the engine's tasks once per card.
    private var summaries: [String: ReconSummary?] = [:]
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
         drivesTasks: Bool = false, place: PrivacyPlace, memory: MemoryStore? = nil,
         calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() },
         clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        let recon = tasks as? ReconRunner
        // A card offers to look into something only when its tap can start
        // it. Otherwise it offers to talk about it, which is what the tap does.
        self.sources = recon?.canLookInto == true ? sources : sources.map { AsksInChat(source: $0) }
        self.needsYou = needsYou
        self.tasks = tasks
        self.recon = recon
        self.memory = memory
        self.drivesTasks = drivesTasks
        self.place = place
        self.calendar = calendar
        self.now = now
        self.clock = clock
        feed = Feed.build(from: self.sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
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
        // A question asked, answered or withdrawn shows at once, wherever
        // the person is. A question that times out is caught by `keepFresh`.
        // Each model watches for itself, so every window's Today updates.
        // A task's question is asked through the rule, not `NeedsYou`, so
        // its card moves with the engine's own snapshots above.
        //
        // The change can come from inside a view update, such as a sheet's
        // yes. Publishing then is undefined behavior in SwiftUI, so the
        // refresh always waits for the next turn of the main actor.
        let hops = pendingRefreshes
        observation = needsYou.observe { [weak self] in
            hops.add { self?.refresh() }
        }
    }

    /// Refreshes asked for by `needsYou` and not yet run.
    private let pendingRefreshes = PendingRefreshes()

    /// Returns once every refresh `needsYou` has asked for so far has run,
    /// so tests wait for exactly that and nothing rests on timing.
    func settled() async {
        await pendingRefreshes.last?.value
    }

    /// Plain, not isolated: the observation and `needsYou` are Sendable and
    /// `stopObserving` takes its own lock, so this runs safely anywhere.
    /// The task watch ends on its own as `watching` is released.
    deinit {
        if let observation { needsYou.stopObserving(observation) }
    }

    /// True when anything on Today is an example, so the note at the top says so.
    var isSample: Bool {
        needsYou.isSample || sources.contains { $0.isSample } || taskIDs.contains { tasks?.isSample($0) == true }
    }

    /// True when this card came from an example source, a scripted engine,
    /// or a recon that read sample sources. Asked per task, so one example
    /// never makes real work look like one.
    func isSample(_ item: FeedItem) -> Bool {
        if let tasks, taskIDs.contains(item.id) { return tasks.isSample(item.id) }
        if item.kind == .needsYou { return needsYou.isSample }
        return sources.contains { $0.isSample && $0.items(now: now()).contains { $0.id == item.id } }
    }

    /// True when a question in the sheet is an example: one of the sample
    /// questions, or one an example task asked, so the sheet says so too.
    func isSample(_ request: ConfirmationRequest) -> Bool {
        if needsYou.isSample { return true }
        guard let tasks, let id = taskAsked[request.id] else { return false }
        return tasks.isSample(id)
    }

    /// True while a card in Working on it is live, so the scripted clock
    /// needs to move. Nothing ticks while nothing is going.
    var ticks: Bool { drivesTasks && !feed.working.isEmpty }

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
        summaries = [:]
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
        summaries = [:]
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

    /// How often `keepFresh` looks again. Questions time out after
    /// `AskFirst.defaultWindow`, so a card is gone within this of its end.
    static let refreshInterval: Duration = .seconds(10)

    /// Keeps the feed current for as long as the caller runs it: the home
    /// screen runs it from its root, so the Needs you count beside Today
    /// drops when a question times out even while the chat or the memory is
    /// showing. `sleep` is passed in so tests can move a clock instead of
    /// waiting. Ends when the task is cancelled or `sleep` throws.
    func keepFresh(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            refresh()
            do { try await sleep(Self.refreshInterval) } catch { return }
        }
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
            // A second tap while the first is under way, or once it is
            // ready, starts nothing more: the card for it is already here,
            // and VoiceOver hears so, rather than nothing at all.
            if isLookingInto(topic) {
                announce(TaskAnnouncer.Line(text: ReconWords.alreadyOn, urgent: false))
                return
            }
            // Without a runner, the chat offers it instead, still one tap away.
            if recon == nil || !lookInto(topic) { talk(ReconWords.askLine(topic)) }
        case nil: break
        }
    }

    // MARK: Looking into something

    /// Starts looking into `topic`, after the person's tap. False when
    /// nothing started, as for words of crisis.
    ///
    /// `onDevice` is true when it was asked from a chat that promised to stay
    /// on this device. That promise holds: the summary is put together here,
    /// whatever the cloud setting is now.
    @discardableResult
    func lookInto(_ topic: String, onDevice: Bool = false) -> Bool {
        let summarizer: any ReconSummarizer = onDevice ? LocalReconSummarizer() : summarizer()
        guard let recon, recon.lookInto(topic, with: summarizer) != nil else { return false }
        refresh()
        return true
    }

    /// True while the only pages to read are examples, so the chat's offer says so.
    var readsExamples: Bool { recon?.provider.isSample == true }

    /// True when a tap on Look into it could start anything. Only then may
    /// a chat offer it.
    var canLookInto: Bool { recon?.canLookInto == true }

    /// Withdraws Today's preview each time the cloud setting changes, as
    /// when another window turned it off. A Send could no longer go out,
    /// so the person is never left being asked.
    func follow(cloudSettings: AnyPublisher<CloudHelpSettings, Never>) {
        // On the main thread it is withdrawn then and there, so a Send
        // tapped right after can't go. A change published on any other
        // thread hops to the main one first, and never traps.
        cloudWatch = cloudSettings.dropFirst().removeDuplicates()
            .sink { @Sendable [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.cloudReview.cancelPending() }
                } else {
                    Task { @MainActor in self?.cloudReview.cancelPending() }
                }
            }
    }

    /// True when a recon for `topic` is going or done on Today. One that
    /// stopped or failed can be started again. Case doesn't count, so "the
    /// pool" from a card and "The pool" from the chat are one topic.
    func isLookingInto(_ topic: String) -> Bool {
        guard let recon, let title = ReconTask(topic: topic)?.title else { return false }
        return recon.tasks.contains {
            $0.title.caseInsensitiveCompare(title) == .orderedSame && ($0.isActive || $0.state == .done)
                && recon.isRecon($0.id)
        }
    }

    /// The summary a finished recon card shows. Asked of the runner once
    /// per card for each snapshot.
    func summary(for task: AgentTask) -> ReconSummary? {
        if let known = summaries[task.id] { return known }
        let summary = recon?.summary(for: task.id)
        summaries[task.id] = summary
        return summary
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

    /// True when the summary's points may go in the notes. Never for one
    /// read from example pages, so made up news is never kept as real.
    func canRemember(_ summary: ReconSummary) -> Bool {
        recon?.keepsPoints(summary.id) == true
    }

    /// Keeps one point in memory, with where it came from, through the same
    /// store the memory screen uses. Only a tap on Remember this calls it,
    /// and never for an example.
    @discardableResult
    func remember(_ point: ReconPoint, in summary: ReconSummary) -> Bool {
        guard canRemember(summary), summary.points.contains(point), !isRemembered(point, in: summary) else { return false }
        guard let memory else {
            rememberStatus = MemoryWords.couldNotOpen
            return false
        }
        do {
            // A point worded in the cloud says so in the note, and its
            // label names no publisher (see `ReconSummary.note(for:)`).
            switch try memory.remember(summary.note(for: point), source: summary.memorySource(for: point)) {
            case .saved(let note):
                remembered.insert(Self.rememberKey(summary, point))
                rememberedFrom[Self.rememberKey(summary, point)] = summary.id
                rememberedAs[Self.rememberKey(summary, point)] = note.id
                rememberStatus = MemoryWords.saved(place)
                return true
            case .tooLong:
                // Not the composer's "shorten it": the person didn't write this.
                rememberStatus = ReconWords.pointTooLong
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

    /// Lets go of kept points whose notes are gone, as when the person
    /// deleted one on the memory screen, so the point can be kept again.
    /// Notes that can't be read right now change nothing.
    func refreshRemembered() {
        guard let memory, !rememberedAs.isEmpty, case .notes(let notes) = memory.contents() else { return }
        let kept = Set(notes.map(\.id))
        let goneKeys = rememberedAs.filter { !kept.contains($0.value) }.keys
        guard !goneKeys.isEmpty else { return }
        forgetKept(Set(goneKeys))
    }

    /// Closes the sources and points of every summary whose task id matches,
    /// and lets go of which of its points were kept, since the card is gone.
    /// The notes themselves stay: they are the person's (see
    /// `ReconWords.rememberDetail`).
    private func closeSummaries(where gone: (String) -> Bool) {
        if let open = readingSources, gone(open.id) { readingSources = nil }
        if let open = choosingPoint, gone(open.id) { choosingPoint = nil }
        let goneKeys = rememberedFrom.filter { gone($0.value) }.keys
        guard !goneKeys.isEmpty else { return }
        forgetKept(Set(goneKeys))
    }

    private func forgetKept(_ keys: Set<String>) {
        for key in keys {
            rememberedFrom[key] = nil
            rememberedAs[key] = nil
        }
        remembered.subtract(keys)
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
        // Asked before clearing: a summary going through the cloud may have
        // sent what it read already, and that can't be called back.
        let inCloud = (recon?.summariesMayLeaveDevice ?? 0) > 0
        // A preview still waiting goes at once, with its sheet, so a Send
        // tapped on it later sends nothing from a recon that is forgotten.
        // Clearing cancels the work too, but that answers only on a later
        // turn of the main actor.
        cloudReview.cancelPending()
        let cleared = tasks.clear()
        refresh()
        if cleared.forgotten > 0 { tasksForgotten = true }
        let lines = [cleared.underwayLine, inCloud ? ReconWords.forgotWhileInCloud : nil].compactMap { $0 }
        if !lines.isEmpty {
            let line = lines.joined(separator: " ")
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
    ///
    /// A task's question goes to its engine first, before anything can
    /// build the feed again: a refresh in between, from a `NeedsYou` hook
    /// or the sheet's `onDismiss`, would otherwise find the question closed
    /// and settle it as it saw fit. Only a question `NeedsYou` asked is
    /// handed to `NeedsYou`.
    func closedQuestion(_ request: ConfirmationRequest) {
        let asking = askedBy.removeValue(forKey: request.id) ?? taskAsked[request.id]
        if asking != nil {
            tasks?.questionClosed(request)
        } else {
            needsYou.dismissed(request)
        }
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

/// A feed source whose Look into it cards become Talk about it, with the
/// same line ready in the chat, for a Today that can't start one. Its
/// cards then never promise to start what the tap can't.
struct AsksInChat: FeedSource {
    let source: any FeedSource

    var isSample: Bool { source.isSample }

    func items(now: Date) -> [FeedItem] {
        source.items(now: now).map { item in
            guard case .lookInto(let topic) = item.action else { return item }
            return FeedItem(id: item.id, kind: item.kind, time: item.time, title: item.title, body: item.body,
                            action: .talk(ReconWords.askLine(topic)))
        }
    }
}

/// The refreshes a `FeedModel` has queued for the main actor, kept as one
/// chain: each waits for the one before, so only the newest is held and
/// waiting for it waits for them all. The watch on `NeedsYou` may call from
/// any thread, so the chain takes its own lock.
private final class PendingRefreshes: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: Task<Void, Never>?

    func add(_ refresh: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        let before = newest
        newest = Task { @MainActor in
            await before?.value
            refresh()
        }
        lock.unlock()
    }

    var last: Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return newest
    }
}

/// The home screen after the first run: a calm feed of what the agent did,
/// made and noticed, with anything that needs a yes pinned on top.
struct FeedView: View {
    @ObservedObject var model: FeedModel
    let look: AgentLook
    let onTalk: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            .foregroundStyle(Theme.secondaryText)
                        // Said first, so no example is ever taken for real work.
                        if model.isSample && !model.feed.isEmpty {
                            Text(FeedWords.sampleNote(model.place))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
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
        // Kept fresh by `FeedModel.keepFresh`, which the home screen runs
        // whether Today is showing or not, so the sidebar's count is true too.
        // Its `refresh` also has the engine notice task questions that timed out.
        // Scripted tasks are played in real time by `HomeView`, so a recon
        // goes on while the person is in the chat or memory.
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
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(items) { item in
                    Group {
                        if let task = item.task, let summary = model.summary(for: task) {
                            ReconCard(summary: summary, time: model.timeLabel(for: item.time),
                                      gathered: ReconWords.gathered(summary.gatheredAt, now: model.now()),
                                      isSample: model.isSample(item),
                                      canRemember: model.canRemember(summary),
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
                            FeedCard(item: item, time: model.timeLabel(for: item.time), isSample: model.isSample(item)) {
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
            // The composer below is the one thing to do, so there is no
            // button here.
            Text(FeedWords.empty)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.readableWidth)
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
    /// True for an example card, so VoiceOver says so before anything else.
    var isSample = false
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
            // Not redundant: `children: .ignore` makes a new element without
            // the button's trait. The UI tests find these cards as buttons.
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
        [isSample ? FeedWords.exampleMarker : "", item.spokenKind, item.title, item.body, time]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func content(actionTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(item.spokenKind)
                } icon: {
                    Image(systemName: Self.symbol(item.kind))
                        .foregroundStyle(Theme.accentSymbol)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Text(time)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(item.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(asks ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.accentText))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(asks ? Theme.accent : Theme.accent.opacity(Theme.accentWash), in: Capsule())
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

/// Over an example opened to read or answer, so it is never taken for
/// real work.
struct ExampleLabel: View {
    var body: some View {
        Text(FeedWords.sampleLabel)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(Theme.fieldTint), in: Capsule())
            .accessibilityIdentifier("sampleLabel")
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
                        ExampleLabel()
                    }
                    Label(item.spokenKind, systemImage: FeedCard.symbol(item.kind))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(item.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
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
                    DoneButton(title: FeedWords.doneTitle) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
