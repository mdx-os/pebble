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
    /// Tasks the engine can start that aren't going now, offered on Today.
    @Published private(set) var offers: [TaskRequest] = []
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
    /// Work done while the app was closed. Its cards join the feed as a
    /// source, and Today runs whatever is due each time it refreshes, so a
    /// summary the system never woke the app for is made once it opens.
    let background: BackgroundRunner?
    private var backgroundWatch: BackgroundRunner.Observation?
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
    /// Yeses a task has gone on with, by question id, so the same yes
    /// handed over again is known and quietly ignored. Ids only, and gone
    /// with Forget everything.
    private(set) var usedYes: Set<UUID> = []
    /// Kept on Today after Forget everything, while a step the person said
    /// yes to may have happened. Names nothing the task held.
    @Published private(set) var forgotUnderway: String?
    /// True from forgetting every task until a new one starts, so the
    /// memory screen can say the tasks are gone.
    @Published private(set) var tasksForgotten = false
    /// Goes up by one each time the engine's file of tasks appears or
    /// goes, so the memory screen can look again at what Forget everything
    /// would erase. Not on every step, so a running task doesn't make it
    /// read the notes again each time.
    @Published private(set) var tasksSeen = 0
    /// `tasksStored` when `tasksSeen` last went up.
    private var storedWhenSeen = false
    /// Kept on Today after a file that couldn't be read was cleared, until
    /// the person has read it.
    @Published private(set) var clearedUnreadable: String?
    /// Kept on Today when the engine couldn't start a task from its offer,
    /// until the person has read it or a task starts.
    @Published private(set) var couldNotStart: String?
    private let clock: () -> ContinuousClock.Instant
    /// Says a line to VoiceOver. Tests replace it to hear what would be said.
    var announce: @MainActor (TaskAnnouncer.Line) -> Void = FeedModel.post

    /// Nudges, receipts, and keeping tasks while the app is closed. Nil
    /// when nothing is kept.
    let flow: NeedsYouFlow?
    /// This model's watch on the flow's store, ended when the model goes.
    private var storeObservation: TaskStore.Observation?
    /// The flow's store, held here too so `deinit` can stop watching it.
    private let store: TaskStore?
    /// The engine whose tasks the store keeps, when it can keep them. A
    /// runner over such an engine keeps its tasks, a recon's apart.
    private let keeper: (any KeepsTasks)?
    /// This window, as the flow knows it. Made fresh for each model and
    /// never used again, unlike an address a later model may be given.
    let window = UUID()

    init(sources: [any FeedSource], needsYou: NeedsYou, tasks: (any TaskEngine)? = nil,
         drivesTasks: Bool = false, place: PrivacyPlace, memory: MemoryStore? = nil,
         flow: NeedsYouFlow? = nil, background: BackgroundRunner? = nil, calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() },
         clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        let recon = tasks as? ReconRunner
        // A card offers to look into something only when its tap can start
        // it. Otherwise it offers to talk about it, which is what the tap does.
        let offered = recon?.canLookInto == true ? sources : sources.map { AsksInChat(source: $0) }
        self.sources = offered + (flow.map { [ReceiptFeed(store: $0.store)] } ?? [])
            + (background.map { [BackgroundFeed(runner: $0, calendar: calendar)] } ?? [])
        self.background = background
        if let recon {
            keeper = recon.engine is any KeepsTasks ? recon : nil
        } else {
            keeper = tasks as? any KeepsTasks
        }
        self.needsYou = needsYou
        self.tasks = tasks
        self.recon = recon
        self.memory = memory
        self.drivesTasks = drivesTasks
        self.place = place
        self.flow = flow
        self.store = flow?.store
        self.calendar = calendar
        self.now = now
        self.clock = clock
        // Tasks kept while the app was closed come back first, before
        // anything is shown. A question is asked again with the deadline it
        // had; a yes is never brought back.
        if let flow, let keeper {
            flow.store.restore(into: keeper, now: now())
        }
        feed = Feed.build(from: self.sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        offers = Self.offers(from: tasks)
        if store?.clearedUnreadable == true { clearedUnreadable = ReceiptWords.unreadableCleared }
        flow?.pinned(Self.pinnedTasks(in: feed), rule: needsYou.rule, from: window)
        let list = tasks?.tasks ?? []
        track(list)
        sections = Self.sections(of: feed)
        _ = announcer.lines(for: list, at: clock())
        storedWhenSeen = tasksStored
        let hops = pendingRefreshes
        watching = tasks?.observe { [weak self] snapshot in
            // Engines tell us on whatever thread they run. Hop to the main
            // one, without a wait when already there. `tasksChanged` drops a
            // snapshot older than one it took. A hop joins the same chain as
            // the refreshes below, so `settled` waits for it too.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.tasksChanged(snapshot) }
            } else {
                hops.add { self?.tasksChanged(snapshot) }
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
        observation = needsYou.observe { [weak self] in
            hops.add { self?.refresh() }
        }
        // A card made in the background, or the cards forgotten, show at once.
        backgroundWatch = background?.observe { [weak self] in
            hops.add { self?.rebuild() }
        }
        // A receipt made or cleared shows at once, the same way, and so do
        // tasks a late read of the store found.
        storeObservation = store?.observe { [weak self] in
            hops.add { self?.storeChanged() }
        }
        // Forget everything in another window forgets here too.
        flow?.onForget(in: window) { [weak self] in self?.forgotten($0) }
    }

    /// Returns once every hop queued so far has run, without holding this
    /// model, so a test can let the model go and still wait.
    var drain: @MainActor () async -> Void {
        let hops = pendingRefreshes
        return { await hops.last?.value }
    }

    /// The store changed. Tasks a late read found are picked up by the
    /// engine at once, as they would have been at launch, so a step said
    /// yes to that was under way still gets its card and its receipt.
    private func storeChanged() {
        if let store, let keeper, store.hasLateTasks { store.keep(keeper, now: now()) }
        if store?.clearedUnreadable == true, clearedUnreadable == nil { clearedUnreadable = ReceiptWords.unreadableCleared }
        followStored()
        rebuild()
    }

    /// Moves `tasksSeen` on when the file of tasks appears or goes, by the
    /// engine's change or the store's.
    private func followStored() {
        let stored = tasksStored
        if stored != storedWhenSeen {
            storedWhenSeen = stored
            tasksSeen += 1
        }
    }

    /// The tasks whose questions are pinned in Needs you: the only ones the
    /// flow may nudge about.
    static func pinnedTasks(in feed: Feed) -> [AgentTask] {
        feed.needsYou.compactMap(\.task).filter { $0.question != nil }
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
        if let backgroundWatch { background?.stopObserving(backgroundWatch) }
        if let storeObservation, let store { store.stopObserving(storeObservation) }
        // The flow is the app's, so it is told this window has gone.
        if let flow {
            let window = window
            Task { @MainActor in flow.closed(window) }
        }
    }

    /// This window came to the front or went away.
    func scene(isActive: Bool) {
        flow?.scene(isActive: isActive, from: window)
    }

    /// A cloud preview in this window started or stopped waiting.
    func preview(waiting: Bool) {
        flow?.preview(waiting: waiting, from: window)
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
        if let receipt = item.receipt { return receipt.isSample }
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

    /// VoiceOver goes to a task card's summary, as when its nudge was
    /// opened. Nothing for a task that isn't here.
    func focusCard(_ id: String) {
        guard taskIDs.contains(id) else { return }
        cardState(id).pendingFocus = .summary
    }

    /// True while there is any task to forget.
    var hasTasks: Bool { !taskIDs.isEmpty }

    /// True while Forget everything has anything here to take: a task, a
    /// receipt, or a task kept from before with no engine to pick it up.
    var hasSomethingToForget: Bool {
        hasTasks || store?.holdsSomething == true
    }

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

    /// Builds the feed again. Questions that timed out drop away here, and
    /// background work that is due runs, with the person here.
    func refresh() {
        tasks?.refresh()
        if inFront { background?.runDue(now: now(), conditions: .foreground) }
        rebuild()
    }

    /// True while the app is active, so the person is here and the device
    /// unlocked. `keepFresh` may tick once more as the app leaves the
    /// screen, perhaps as it locks; background work then waits for the
    /// platform's own run, which knows whether it is locked. False until
    /// the scene says it is active, since a scene may be built during a
    /// launch in the background, while locked.
    var inFront = false

    private func rebuild() {
        summaries = [:]
        let next = Feed.build(from: sources, needsYou: needsYou, tasks: tasks, now: now(), calendar: calendar)
        if next != feed { feed = next }
        let offered = Self.offers(from: tasks)
        if offered != offers { offers = offered }
        closeSummaryGone()
        followCards()
        flow?.pinned(Self.pinnedTasks(in: feed), rule: rule, from: window)
    }

    /// What the engine can start, less any already going, so a task is
    /// never offered twice at once.
    static func offers(from tasks: (any TaskEngine)?) -> [TaskRequest] {
        guard let tasks else { return [] }
        let going = Set(tasks.tasks.filter(\.isActive).map(\.title))
        return tasks.builtIns.filter { !going.contains($0.title) }
    }

    /// Starts one of the engine's own tasks from its offer on Today. The
    /// offer goes once its task is going, taking VoiceOver's place with it,
    /// so the task's first step is said at once.
    /// The engine reads what it keeps first, if it hasn't yet. One that
    /// still couldn't start it leaves a line here, never silence.
    func start(_ request: TaskRequest) {
        guard let tasks, tasks.builtIns.contains(request) else { return }
        let id = tasks.start(request)
        refresh()
        guard let task = tasks.tasks.first(where: { $0.id == id }) else {
            couldNotStart = TaskWords.couldNotStart
            announce(TaskAnnouncer.Line(text: TaskWords.couldNotStart, urgent: true))
            return
        }
        couldNotStart = nil
        if let line = announcer.started(task, at: clock()) { announce(line) }
    }

    /// The person has read that a task couldn't start.
    func dismissCouldNotStart() {
        couldNotStart = nil
    }

    /// Asks the tasks whether a forgotten or changed note's words stayed in
    /// anything they kept. The engine follows the notes itself, and the
    /// memory screen calls `notesChanged()` next, so nothing is read again
    /// here.
    func forgetQuotes(of note: MemoryNote) -> QuotesForgotten {
        tasks?.forgetQuotes(of: note) ?? .notQuoted
    }

    /// After the memory screen changes a note. The engine has already
    /// looked at the notes on the store's own word, so the feed is only
    /// built again.
    func notesChanged() {
        rebuild()
    }

    /// True while the engine, or the store it shares, keeps a file of
    /// tasks, so Forget everything is offered even with no notes left.
    var tasksStored: Bool { tasks?.hasStoredFile == true || store?.hasFile == true }

    /// A summary open to read whose card is gone, as after Forget
    /// everything in another window, closes with it.
    private func closeSummaryGone() {
        guard let reading, reading.id.hasPrefix(BackgroundFeed.idPrefix) else { return }
        let cards = background?.results ?? []
        if !cards.contains(where: { $0.itemID == reading.id }) { self.reading = nil }
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
        // Kept at every real change, so closing the app at any moment loses
        // nothing. Only what changed is written.
        if let flow, let keeper { flow.store.keep(keeper, now: now()) }
        followStored()
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
        // A result open to read whose words are gone closes too, as when the
        // note it showed is forgotten. One whose words changed, as when a
        // forget took one line of a digest, shows the words as they are now.
        if let reading, let task = list.first(where: { $0.id == reading.id }) {
            if let result = task.result {
                if reading.action != .open(result) { open(task) }
            } else {
                self.reading = nil
            }
        }
        // A question its task let go of, as when a note it drew from
        // changed, closes its sheet too.
        if let reviewing, let id = taskAsked[reviewing.id],
           list.first(where: { $0.id == id })?.question?.id != reviewing.id {
            self.reviewing = nil
        }
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
            switch start(lookingInto: topic) {
            case .started: break
            case .already(let line):
                // A second tap while the first is under way, or once it is
                // ready, starts nothing more: the card for it is already
                // here, and VoiceOver hears so, rather than nothing at all.
                announce(TaskAnnouncer.Line(text: line, urgent: false))
            case .couldNotStart:
                // The chat offers it instead, still one tap away.
                talk(ReconWords.askLine(topic))
            }
        case .receipt(let receipt): clearReceipt(receipt)
        case nil: break
        }
    }

    // MARK: Looking into something

    /// Starts looking into `topic`, after the person's tap. False when
    /// nothing new started: one on that topic is already going or ready,
    /// or nothing could start, as for words of crisis.
    @discardableResult
    func lookInto(_ topic: String, place: PrivacyPlace = .mayLeaveDevice) -> Bool {
        start(lookingInto: topic, place: place) == .started
    }

    /// Starts looking into `topic`, after the person's tap, and says what
    /// came of it. The runner itself decides whether one on that topic is
    /// already going, so two taps at once, here and in a chat, start one.
    ///
    /// `place` is the asking chat's model's place. A chat that promised to
    /// stay on this device keeps that promise: the summary is put together
    /// here, whatever the cloud setting is now. If the one already going may
    /// be put into words in the cloud, the line says so.
    func start(lookingInto topic: String, place: PrivacyPlace = .mayLeaveDevice) -> ReconTap {
        guard let recon else { return .couldNotStart }
        let summarizer: any ReconSummarizer = place.staysOnDevice ? LocalReconSummarizer() : summarizer()
        switch recon.start(lookingInto: topic, with: summarizer) {
        case .started:
            refresh()
            return .started
        case .already(let id, let mayUseCloud):
            return .already(alreadyLine(id: id, mayUseCloud: mayUseCloud, place: place))
        case .notStarted:
            return .couldNotStart
        }
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
        // Duplicates go before the first is dropped, so saving the settings
        // as they already were changes nothing.
        cloudWatch = cloudSettings.removeDuplicates().dropFirst()
            .sink { @Sendable [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.cloudReview.cancelPending() }
                } else {
                    Task { @MainActor in self?.cloudReview.cancelPending() }
                }
            }
    }

    /// True when a recon for `topic` is going or done on Today. One that
    /// stopped or failed can be started again. Asked of the runner, so the
    /// feed and every chat agree on what counts as the same topic.
    func isLookingInto(_ topic: String) -> Bool {
        recon?.activeRecon(for: topic) != nil
    }

    /// What to say when `topic` is already going or ready, or nil when a
    /// tap may start it. For a chat whose `place` stays on this device, if
    /// the one already going may be put into words in the cloud, the line
    /// says so, so that promise stays true.
    func alreadyLine(for topic: String, place: PrivacyPlace = .mayLeaveDevice) -> String? {
        guard let recon, let id = recon.activeRecon(for: topic) else { return nil }
        return alreadyLine(id: id, mayUseCloud: recon.mayUseCloud(id), place: place)
    }

    /// The line for one already going or ready, from what the runner said
    /// of it. One still being started is going.
    private func alreadyLine(id: String?, mayUseCloud: Bool, place: PrivacyPlace) -> String {
        if let id, recon?.tasks.first(where: { $0.id == id })?.state == .done { return ReconWords.alreadyReady }
        return place.staysOnDevice && mayUseCloud ? ReconWords.alreadyOnWithCloud : ReconWords.alreadyOn
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
            // label names no publisher (see `ReconSummary.note(for:)`). The
            // store itself refuses an example's point.
            switch try memory.remember(point, from: summary) {
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
            case .notKept:
                // Only an example's point, which never gets this far.
                rememberStatus = nil
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

    // MARK: Receipts

    /// Takes a receipt away for good. Its card goes from under VoiceOver,
    /// so what went is said.
    func clearReceipt(_ receipt: Receipt) {
        let cleared = flow?.store.clearReceipt(receipt.id) == true
        rebuild()
        if cleared { announce(TaskAnnouncer.Line(text: receipt.clearedLine, urgent: true)) }
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

    /// Stops at once. Never needs a yes. A recon's preview still waiting
    /// goes then and there, with its sheet, so a Send tapped on it after
    /// Stop sends nothing. Stopping cancels its work too, but that answers
    /// only on a later turn of the main actor.
    func stop(_ task: AgentTask) {
        cloudReview.withdraw(run: task.id)
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
    ///
    /// Receipts, saved tasks and nudges go too, with or without an engine
    /// and with or without a task, and every other window forgets with
    /// this one and shows the same lines. Only this one says them aloud,
    /// so VoiceOver hears them once.
    @discardableResult
    func forgetTasks() -> ClearedTasks {
        let hadReceipts = store?.holdsSomething == true
        // Asked before clearing: a summary going through the cloud may have
        // sent what it read already, and that can't be called back. Only
        // one past the person's yes: one still reading, taking details out
        // or waiting on its preview has sent nothing.
        let inCloud = (recon?.summariesPastAYes ?? 0) > 0
        forgetting = true
        defer { forgetting = false }
        forgotten(.init())
        let cleared = tasks?.clear() ?? .none
        let line = Self.forgetLine(cleared.underwayLine, inCloud: inCloud)
        // Said forgotten only once the file has gone too, so nothing says
        // they are forgotten while they may come back.
        let what = NeedsYouFlow.Forgotten(something: (cleared.forgotten > 0 || hadReceipts) && cleared.erased,
                                          underway: line)
        if let flow { flow.forget(what) } else { forgotten(what) }
        refresh()
        if let line {
            announce(TaskAnnouncer.Line(text: line, urgent: true))
        }
        return cleared
    }

    /// True while this window's own Forget everything runs, so the call
    /// back from the flow doesn't clear its tasks a second time.
    private var forgetting = false

    /// Run with every Forget everything, here or in another window, so a
    /// chat wired to this Today lets go of what it holds for a recon. Each
    /// says false once its chat has gone, and is let go then.
    private var forgetHooks: [@MainActor () -> Bool] = []

    func whenForgotten(_ hook: @escaping @MainActor () -> Bool) {
        forgetHooks.append(hook)
    }

    /// The line kept on Today after forgetting: a step said yes to that may
    /// be done, and a summary that may have gone to the cloud already.
    static func forgetLine(_ underway: String?, inCloud: Bool) -> String? {
        let lines = [underway, inCloud ? ReconWords.forgotWhileInCloud : nil].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Forget everything, from the memory screen: every task goes, as in
    /// `forgetTasks`. The memory screen forgets the background work just
    /// before, so it can say if its file couldn't be erased; here a summary
    /// still open to read closes, and Today shows the cards gone.
    @discardableResult
    func forgetEverything() -> ClearedTasks {
        if let reading, reading.id.hasPrefix(BackgroundFeed.idPrefix) { self.reading = nil }
        let cleared = forgetTasks()
        rebuild()
        return cleared
    }

    /// What this window lets go of when Forget everything runs here or in
    /// another window: a task's question or result open here closes, and
    /// the ids of yeses go. A late yes for a forgotten task is still
    /// refused through `taskAsked`, so these ids have nothing left to guard.
    /// The lines about what went show here as in the window it ran in.
    private func forgotten(_ what: NeedsYouFlow.Forgotten) {
        if let reviewing, askedBy[reviewing.id] != nil || taskAsked[reviewing.id] != nil
            || tasks?.tasks.contains(where: { $0.question?.id == reviewing.id }) == true {
            self.reviewing = nil
        }
        if let reading, taskIDs.contains(reading.id) { self.reading = nil }
        // Every summary goes with its recon, so its sheets close too.
        closeSummaries { _ in true }
        rememberStatus = nil
        // A preview still waiting goes at once, with its sheet, so a Send
        // tapped on it later sends nothing from a recon that is forgotten.
        // Clearing cancels the work too, but that answers only on a later
        // turn of the main actor.
        cloudReview.cancelPending()
        forgetHooks = forgetHooks.filter { $0() }
        askedBy.removeAll()
        usedYes.removeAll()
        var something = what.something
        var underway = what.underway
        if !forgetting, let tasks {
            // Forgotten in another window. This window's own recons go too,
            // and if one of them may have reached the cloud, the line says so.
            let inCloud = (recon?.summariesPastAYes ?? 0) > 0
            let cleared = tasks.clear()
            if cleared.forgotten > 0 && cleared.erased { something = true }
            let own = Self.forgetLine(cleared.underwayLine, inCloud: inCloud)
            if let own, underway?.contains(own) != true {
                underway = [underway, own].compactMap { $0 }.joined(separator: " ")
            }
        }
        rebuild()
        if something { tasksForgotten = true }
        if let line = underway { forgotUnderway = line }
        // What it said went is forgotten too.
        clearedUnreadable = nil
    }

    /// The person has read the line kept after forgetting.
    func dismissForgotUnderway() {
        forgotUnderway = nil
    }

    /// The person has read that a file that couldn't be read was cleared.
    func dismissClearedUnreadable() {
        clearedUnreadable = nil
        store?.saidUnreadableCleared()
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
        if usedYes.contains(approval.id) {
            // The same yes again, as from a second tap. The first one
            // stands and went through; this one does nothing and says nothing.
        } else if let id = askedBy.removeValue(forKey: approval.id) {
            switch tasks?.resume(id, with: approval) ?? .refused {
            case .proceeding:
                usedYes.insert(approval.id)
                // Kept now, not at the next change: if the app closes in
                // between, the step is known to be under way and is never
                // asked about or run again.
                if let flow, let keeper { flow.store.keep(keeper, now: now()) }
            case .notKept:
                // Spent, so a second tap is quiet too. The card says why
                // nothing was kept.
                usedYes.insert(approval.id)
                if let flow, let keeper { flow.store.keep(keeper, now: now()) }
            case .refused: refusedBy = id
            case .timedOut: break
            }
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
    /// The room between Today's sections. Fixed, not scaled, so it is the
    /// same at every text size.
    static let sectionSpacing: CGFloat = 28
    /// How much closer the nudge offer sits under Needs you than sections
    /// do. Always less than `sectionSpacing`, so at any text size the two
    /// still have room between them and never overlap.
    static let offerTuck: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
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
                    if let line = model.clearedUnreadable {
                        ForgotUnderwayNotice(line: line, onDismiss: model.dismissClearedUnreadable,
                                             identifier: "clearedUnreadable")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if let line = model.couldNotStart {
                        ForgotUnderwayNotice(line: line, onDismiss: model.dismissCouldNotStart,
                                             identifier: "couldNotStart")
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
                    if let flow = model.flow {
                        // Offered only once a question is waiting, never at launch.
                        NudgeOffer(flow: flow)
                            .padding(.top, model.feed.showsNeedsYou ? -Self.offerTuck : 0)
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if model.feed.showsWorking {
                        section(TaskWords.workingHeading, detail: TaskWords.workingDetail,
                                items: model.feed.working, columns: columns)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("working")
                            .transition(Motion.arrival(reduceMotion: reduceMotion))
                    }
                    if !model.offers.isEmpty {
                        offers(columns: columns)
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
            .background {
                if let flow = model.flow {
                    FocusScroller(flow: flow, window: model.window, scroller: scroller,
                                  reduceMotion: reduceMotion) { id in
                        model.focusCard(id)
                    }
                }
            }
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
                        } else if let receipt = item.receipt {
                            ReceiptCard(receipt: receipt, time: model.timeLabel(for: item.time)) {
                                model.clearReceipt(receipt)
                            }
                        } else {
                            FeedCard(item: item, time: model.timeLabel(for: item.time), isSample: model.isSample(item)) {
                                model.perform(item, talk: onTalk)
                            }
                        }
                    }
                    // So a nudge opened from the lock screen can bring its card into view.
                    .id(item.id)
                    .transition(Motion.arrival(reduceMotion: reduceMotion))
                }
            }
        }
    }

    /// What the engine can start, one card each.
    private func offers(columns: [GridItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DigestWords.offerHeading)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(DigestWords.offerDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(model.offers, id: \.title) { request in
                    TaskOfferCard(request: request) { model.start(request) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offers")
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
        // Never drawn here either: a receipt is a `ReceiptCard`, which uses it.
        case .receipt: "checkmark.seal.fill"
        }
    }
}

/// A task the agent can start, offered on Today. One button: VoiceOver
/// hears the title, then that it starts.
struct TaskOfferCard: View {
    let request: TaskRequest
    let start: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    }

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 10) {
                // The section above says what this is, so the card leads
                // with the task itself.
                Label {
                    Text(request.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentSymbol)
                }
                Text(DigestWords.startTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(Theme.accentWash), in: Capsule())
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card(scheme), in: shape)
            .overlay(shape.stroke(Theme.hairline(scheme), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(SoftPressStyle())
        .pointerHover(in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(request.title)
        .accessibilityHint(DigestWords.startHint)
        // Voice Control users can say the title they see. "Start" alone
        // would name every offer once there is more than one.
        .accessibilityInputLabels([Text(request.title), Text(DigestWords.startInputLabel(request.title))])
        // Not redundant: `children: .ignore` makes a new element without
        // the button's trait. Without it the UI tests can't find the offer
        // as a button.
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("offer")
    }
}

/// Brings a task's card into view when its nudge is opened, and VoiceOver
/// with it, then lets go.
struct FocusScroller: View {
    @ObservedObject var flow: NeedsYouFlow
    /// This window. Only the window in front acts.
    let window: UUID
    let scroller: ScrollViewProxy
    let reduceMotion: Bool
    /// Hands VoiceOver to the card's summary.
    let focusCard: (String) -> Void

    var body: some View {
        Color.clear
            .onChange(of: flow.focus, initial: true) { _, id in
                guard let id, flow.opens(in: window) else { return }
                // A beat later, once Today is in front and the card in place.
                // The flow looks again then, since the home screen may have
                // let the nudge go in between.
                Task { @MainActor in
                    flow.bringIntoView(id, in: window, scroll: { id in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                            scroller.scrollTo(id, anchor: .top)
                        }
                    }, focusCard: focusCard)
                }
            }
            .accessibilityHidden(true)
    }
}

/// What stays on Today after Forget everything, while a step the person
/// said yes to may have happened, after a file that couldn't be read was
/// cleared, or when a task couldn't start. One plain line and a way to put
/// it away.
struct ForgotUnderwayNotice: View {
    let line: String
    let onDismiss: () -> Void
    var identifier = "forgotUnderway"
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
        .accessibilityIdentifier(identifier)
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
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
