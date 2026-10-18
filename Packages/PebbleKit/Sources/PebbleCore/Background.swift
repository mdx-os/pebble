import Foundation

// Work the agent does on its own while the app is closed, and the cards it
// leaves in Today. The runner here decides and remembers; the platform
// (`PebbleBackground`) only gives it time and says what the moment is like.
//
// The runner never sends, buys or shares. Its one job reads what is
// already here. Anything consequential is asked through `AskFirst` and
// waits in Needs you (`BackgroundRunner.propose`).

/// The identifiers the system knows the background tasks by. The app's
/// Info.plist lists the first two, from project.yml, or the system refuses
/// them. `BackgroundTests` checks they match.
public enum BackgroundIdentifiers {
    /// A short run in the morning, as `BGAppRefreshTask`.
    public static let refresh = "com.mdxos.pebble.background.refresh"
    /// A longer run the system may give overnight, as `BGProcessingTask`.
    public static let processing = "com.mdxos.pebble.background.processing"
    /// The Mac's `NSBackgroundActivityScheduler`. Needs no listing.
    public static let mac = "com.mdxos.pebble.background.mac"
}

/// One kind of work the runner can do.
public enum BackgroundJobKind: String, Codable, Sendable, CaseIterable {
    /// What was waiting in Needs you and what finished overnight, counted
    /// from what is really here. Nothing is made up.
    case morningSummary

    /// About how long a run takes. A run starts only with at least this
    /// much time left, so it is never cut off halfway.
    public var expectedSeconds: TimeInterval { 2 }
}

/// Why a job didn't run when it was due. Kept on the job, so the card it
/// makes later can say so.
public enum BackgroundHold: String, Codable, Sendable, CaseIterable {
    /// The device was locked, so the file the results go in couldn't be opened.
    case locked
    /// Low Power Mode was on, so the runner left it to save battery.
    case lowPower
    /// The system's time ran out first.
    case outOfTime
}

/// A job waiting for its time. Holds no words of the person's.
public struct BackgroundJob: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: BackgroundJobKind
    /// It runs at the first chance from here on.
    public var due: Date
    /// Why the last chance passed it by, if one did.
    public var held: BackgroundHold?

    public init(id: UUID = UUID(), kind: BackgroundJobKind, due: Date, held: BackgroundHold? = nil) {
        self.id = id
        self.kind = kind
        self.due = due
        self.held = held
    }
}

/// What the moment is like when the runner gets time.
public struct BackgroundConditions: Sendable, Equatable {
    public enum Moment: Sendable, Equatable {
        /// The person has the app open.
        case foreground
        /// The system gave the app time while it was closed.
        case background
    }

    public var moment: Moment
    public var lowPower: Bool
    /// True while the device is locked and protected files can't be opened.
    public var locked: Bool
    /// When the system takes the time back. Nil when there is no limit.
    public var deadline: Date?

    public init(moment: Moment, lowPower: Bool = false, locked: Bool = false, deadline: Date? = nil) {
        self.moment = moment
        self.lowPower = lowPower
        self.locked = locked
        self.deadline = deadline
    }

    /// The app is open and in front: unlocked, with no time limit. Low
    /// Power Mode doesn't hold back a run here, since the person is here
    /// and the summary only counts what is on screen anyway.
    public static let foreground = BackgroundConditions(moment: .foreground)
}

/// What to do with one job at one moment.
public enum BackgroundDecision: Sendable, Equatable {
    /// Its time hasn't come.
    case notYet(Date)
    case run
    /// Due, but not now, for this reason.
    case hold(BackgroundHold)
    /// The day it was for is over. It says so on a card and moves on.
    case missed
}

/// Every scheduling decision, as pure functions of the clock and the
/// moment, so tests drive them with any time they like.
public enum BackgroundPlan {
    /// The hour the morning summary is due.
    public static let morningHour = 7
    /// How soon to ask for time again after a run was held back.
    public static let retryAfterHold: TimeInterval = 15 * 60
    /// Cards older than this go.
    public static let keepResultsFor: TimeInterval = 7 * 24 * 60 * 60
    /// And never more than this many.
    public static let maxResults = 14

    /// The first morning at `morningHour` after `now`.
    public static func nextMorning(after now: Date, calendar: Calendar) -> Date {
        let today = morning(of: now, calendar: calendar)
        if today > now { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now + 86_400
        return morning(of: tomorrow, calendar: calendar)
    }

    /// `morningHour` on the day of `date`.
    public static func morning(of date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: date) ?? date
    }

    /// The last moment a job can still run: the end of the day it is due.
    /// A morning summary made the next day would be about the wrong morning.
    public static func lastChance(for job: BackgroundJob, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: job.due)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? job.due + 86_400
    }

    /// Whether `job` runs now. Held back while locked, and in the
    /// background while Low Power Mode is on or there isn't the time to
    /// finish. Missed once its day is over, whatever the moment.
    public static func decide(_ job: BackgroundJob, now: Date, conditions: BackgroundConditions,
                              calendar: Calendar) -> BackgroundDecision {
        if now < job.due { return .notYet(job.due) }
        if now >= lastChance(for: job, calendar: calendar) { return .missed }
        if conditions.locked { return .hold(.locked) }
        if conditions.moment == .background {
            if conditions.lowPower { return .hold(.lowPower) }
            if let deadline = conditions.deadline, deadline.timeIntervalSince(now) < job.kind.expectedSeconds {
                return .hold(.outOfTime)
            }
        }
        return .run
    }

    /// When to ask the system for time next: the soonest job's due time,
    /// or a little later for one already due and held back. Nil with
    /// nothing queued, so the ask is cancelled.
    public static func nextWake(for queue: [BackgroundJob], now: Date) -> Date? {
        queue.map { $0.due > now ? $0.due : now + retryAfterHold }.min()
    }

    /// Where a missed job goes next: this morning if today's is still to
    /// come or still today, so it runs now if it can.
    static func afterMissing(now: Date, calendar: Calendar) -> Date {
        morning(of: now, calendar: calendar)
    }
}

/// What a morning summary found. Only counts and times, so nothing a task
/// held or a question asked is kept here, and forgetting tasks leaves no
/// words of theirs behind in a summary.
public struct MorningSummary: Codable, Sendable, Equatable {
    /// Questions open in Needs you and tasks waiting on the person.
    public let waiting: Int
    /// Tasks that finished since `since`.
    public let finished: Int
    /// Tasks that couldn't finish since `since`.
    public let couldNotFinish: Int
    /// Counted from here: the summary before, or the evening before.
    public let since: Date
    /// Why it was made later than it was due, if it was held back.
    public let late: BackgroundHold?

    public init(waiting: Int, finished: Int, couldNotFinish: Int, since: Date, late: BackgroundHold?) {
        self.waiting = waiting
        self.finished = finished
        self.couldNotFinish = couldNotFinish
        self.since = since
        self.late = late
    }

    /// Counts what is really here: the open questions, and the tasks.
    /// A task counts as finished only if it ended between `since` and `now`.
    public static func count(questions: [FeedItem], tasks: [AgentTask], since: Date, now: Date,
                             late: BackgroundHold?) -> MorningSummary {
        let window = since...now
        let ended = tasks.filter { !$0.isActive && window.contains($0.updatedAt) }
        return MorningSummary(
            waiting: questions.filter { $0.kind == .needsYou }.count + tasks.filter { $0.state == .waitingOnYou }.count,
            finished: ended.filter { $0.state == .done }.count,
            couldNotFinish: ended.filter { $0.state == .failed }.count,
            since: since, late: late)
    }

    public var isQuiet: Bool { waiting == 0 && finished == 0 && couldNotFinish == 0 }
}

/// Something a run left for Today.
public struct BackgroundResult: Codable, Sendable, Equatable, Identifiable {
    public enum Content: Codable, Sendable, Equatable {
        case morningSummary(MorningSummary)
        /// A job whose day ended before it could run.
        case missed(kind: BackgroundJobKind, due: Date, held: BackgroundHold?)
    }

    public let id: UUID
    public let madeAt: Date
    public let content: Content

    public init(id: UUID = UUID(), madeAt: Date, content: Content) {
        self.id = id
        self.madeAt = madeAt
        self.content = content
    }

    /// The card in Today. Words are made here, when shown, from
    /// `BackgroundWords`, so the file holds no copy that could go stale.
    public func item(calendar: Calendar = .current, locale: Locale = .current) -> FeedItem {
        let id = "background:\(id.uuidString)"
        switch content {
        case .morningSummary(let summary):
            let body = BackgroundWords.summaryBody(summary)
            guard !summary.isQuiet else {
                return FeedItem(id: id, kind: .did, time: madeAt, title: BackgroundWords.summaryTitle, body: body)
            }
            return FeedItem(id: id, kind: .ready, time: madeAt, title: BackgroundWords.summaryTitle, body: body,
                            action: .open(BackgroundWords.summaryDetail(summary, now: madeAt, calendar: calendar,
                                                                        locale: locale)))
        case .missed(_, let due, let held):
            return FeedItem(id: id, kind: .noticed, time: madeAt,
                            title: BackgroundWords.missedTitle(due, calendar: calendar, locale: locale),
                            body: BackgroundWords.missed(held))
        }
    }
}

/// Everything the runner keeps: the queue and the cards. Holds counts,
/// times and kinds only.
public struct BackgroundState: Codable, Sendable, Equatable {
    public var queue: [BackgroundJob]
    public var results: [BackgroundResult]
    /// When the last morning summary was made, so the next counts from there.
    public var lastSummary: Date?

    public init(queue: [BackgroundJob] = [], results: [BackgroundResult] = [], lastSummary: Date? = nil) {
        self.queue = queue
        self.results = results
        self.lastSummary = lastSummary
    }

    public static let empty = BackgroundState()
}

/// Whether background work is on. Off until the person turns it on.
public protocol BackgroundSwitch: Sendable {
    var isOn: Bool { get }
    func set(_ on: Bool)
}

/// The switch, saved in `UserDefaults`. Readable while the device is
/// locked, so a run in the night knows whether it may go ahead.
public struct UserDefaultsBackgroundSwitch: BackgroundSwitch, @unchecked Sendable {
    public static let key = "pebble.background.on"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isOn: Bool { defaults.bool(forKey: Self.key) }
    public func set(_ on: Bool) { defaults.set(on, forKey: Self.key) }
}

/// A switch held in memory, for tests and screenshots.
public final class InMemoryBackgroundSwitch: BackgroundSwitch, @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    public init(on: Bool = false) {
        self.on = on
    }

    public var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    public func set(_ on: Bool) {
        lock.lock()
        self.on = on
        lock.unlock()
    }
}

/// The runner's file, next to the notes: in the same folder, left out of
/// backups, and written with complete file protection on iPhone and iPad,
/// so it can't be opened while the device is locked. The runner holds its
/// work back then rather than weaken that.
public final class BackgroundStore: @unchecked Sendable {
    /// The file is there but can't be opened right now, as while locked.
    public struct Unavailable: Error, Equatable {}

    public let fileURL: URL
    private let lock = NSLock()

    /// Package access: the app uses `onDevice()`. Tests and screenshots
    /// point a store at a scratch file.
    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: BackgroundStore?

    /// The one store, in the notes' folder.
    public static func onDevice(fileManager: FileManager = .default) throws -> BackgroundStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let folder = try MemoryStore.folder(fileManager: fileManager)
        let store = BackgroundStore(fileURL: folder.appendingPathComponent("background.json"))
        shared = store
        return store
    }

    public var hasStoredFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: stagingURL.path)
    }

    /// What was kept. Empty with no file. A file that can't be decoded,
    /// as from a newer version, starts over: it holds only counts and
    /// times the runner made, nothing of the person's own.
    public func load() throws -> BackgroundState {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { throw Unavailable() }
        return (try? JSONDecoder().decode(BackgroundState.self, from: data)) ?? .empty
    }

    public func save(_ state: BackgroundState) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try removeStaged()
        #if os(macOS)
        try data.write(to: stagingURL, options: [.withoutOverwriting])
        #else
        try data.write(to: stagingURL, options: [.withoutOverwriting, .completeFileProtection])
        #endif
        guard rename(stagingURL.path, fileURL.path) == 0 else {
            try? removeStaged()
            throw Unavailable()
        }
    }

    /// Removes the file and any staged copy.
    public func forget() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeStaged()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func removeStaged() throws {
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
    }
}

/// Runs the queue when the platform gives it time, and turns finished runs
/// into cards for Today through `feed`.
///
/// It reads questions from `needsYou` and tasks from `tasks`, the same ones
/// Today shows, and only counts them. It never approves, sends, buys or
/// shares. `propose` is the one way to ask for something, and it asks
/// through `AskFirst`.
///
/// What it keeps lives in `store`, which can't be opened while the device
/// is locked. Until it can, the runner holds what changed in memory and
/// writes it at the next chance.
public final class BackgroundRunner: @unchecked Sendable {
    public let store: BackgroundStore
    public let needsYou: NeedsYou?
    public let tasks: (any TaskEngine)?
    private let toggle: any BackgroundSwitch
    private let calendar: Calendar
    private let sample: Bool

    private let lock = NSLock()
    private var state = BackgroundState.empty
    /// True once the file has been read. Until then nothing is written, so
    /// a locked file is never written over with an empty queue.
    private var loaded = false
    /// Changes not yet written, as while the device was locked.
    private var unsaved = false
    /// Holds made before the file could be read, by job kind, so the card
    /// can still say why once it can.
    private var heldBeforeLoad: [BackgroundJobKind: BackgroundHold] = [:]
    /// Set when the system takes its time back. Anything not yet run waits.
    private var timeUp = false
    private var observers: [Observation: @Sendable () -> Void] = [:]

    /// `sample` marks the cards as examples, for the showcase. A runner
    /// reading scripted tasks or sample questions is an example too.
    public init(store: BackgroundStore, toggle: any BackgroundSwitch, needsYou: NeedsYou? = nil,
                tasks: (any TaskEngine)? = nil, calendar: Calendar = .current, sample: Bool = false) {
        self.store = store
        self.toggle = toggle
        self.needsYou = needsYou
        self.tasks = tasks
        self.calendar = calendar
        self.sample = sample
    }

    /// True when the cards are examples, so Today labels them.
    public var isSample: Bool { sample || needsYou?.isSample == true || tasks?.isSample == true }

    // MARK: Watching

    public struct Observation: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Calls `hook` after the queue or the cards change. Never with the lock held.
    public func observe(_ hook: @escaping @Sendable () -> Void) -> Observation {
        let observation = Observation()
        lock.lock()
        observers[observation] = hook
        lock.unlock()
        return observation
    }

    public func stopObserving(_ observation: Observation) {
        lock.lock()
        observers[observation] = nil
        lock.unlock()
    }

    private func didChange() {
        lock.lock()
        let hooks = Array(observers.values)
        lock.unlock()
        for hook in hooks { hook() }
    }

    // MARK: On and off

    public var isOn: Bool { toggle.isOn }

    /// Turns background work on, with the morning summary due at the next
    /// morning. Turning it on again changes nothing.
    public func turnOn(now: Date) {
        toggle.set(true)
        change { state in
            guard !state.queue.contains(where: { $0.kind == .morningSummary }) else { return }
            state.queue.append(BackgroundJob(kind: .morningSummary,
                                             due: BackgroundPlan.nextMorning(after: now, calendar: calendar)))
        }
    }

    /// Turns it off. The queue goes, so nothing more runs. Cards already
    /// made stay until they are forgotten.
    public func turnOff() {
        toggle.set(false)
        change { $0.queue.removeAll() }
    }

    // MARK: Reading

    /// Every job waiting for its time.
    public var queue: [BackgroundJob] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return state.queue
    }

    /// Every card, newest first.
    public var results: [BackgroundResult] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return state.results.sorted { $0.madeAt > $1.madeAt }
    }

    /// When the platform should give the runner time next. Nil while off
    /// or with nothing queued.
    public func nextWake(now: Date) -> Date? {
        guard isOn else { return nil }
        return BackgroundPlan.nextWake(for: queue, now: now)
    }

    /// The cards, as a source for Today.
    public var feed: BackgroundFeed { BackgroundFeed(runner: self) }

    // MARK: Running

    /// The system is taking its time back. Whatever hasn't run waits for
    /// the next chance, and its card will say it ran out of time.
    public func timeIsUp() {
        lock.lock()
        timeUp = true
        lock.unlock()
    }

    /// Runs every job that is due and may run now. Returns the cards made.
    ///
    /// Called by the platform with the moment it reports, and by Today
    /// whenever it refreshes, so a summary the system never woke the app
    /// for is made as soon as the person opens it.
    @discardableResult
    public func runDue(now: Date, conditions: BackgroundConditions) -> [BackgroundResult] {
        guard isOn else { return [] }
        // Read outside the runner's lock: `NeedsYou` and the engine take
        // their own, and may call back.
        let questions = needsYou?.items(now: now) ?? []
        let taskList = tasks?.tasks ?? []

        lock.lock()
        // The time this run was given ends with it. A later run starts fresh.
        defer {
            lock.lock()
            timeUp = false
            lock.unlock()
        }
        loadIfNeeded()
        guard loaded else {
            // The file can't be opened, so neither can anything be written.
            // Remember why, for the card that comes later.
            if conditions.locked || conditions.moment == .background {
                for kind in BackgroundJobKind.allCases { heldBeforeLoad[kind] = .locked }
            }
            lock.unlock()
            return []
        }
        var made: [BackgroundResult] = []
        var changed = false
        for index in state.queue.indices {
            var job = state.queue[index]
            if job.held == nil, let held = heldBeforeLoad[job.kind], job.due <= now { job.held = held }
            // At most twice: a missed job moves to this morning and may run now.
            for _ in 0..<2 {
                var decision = BackgroundPlan.decide(job, now: now, conditions: conditions, calendar: calendar)
                if decision == .run, timeUp { decision = .hold(.outOfTime) }
                switch decision {
                case .notYet:
                    break
                case .hold(let reason):
                    if job.held != reason { job.held = reason; changed = true }
                case .missed:
                    made.append(BackgroundResult(madeAt: now, content: .missed(kind: job.kind, due: job.due, held: job.held)))
                    job.due = BackgroundPlan.afterMissing(now: now, calendar: calendar)
                    job.held = nil
                    changed = true
                    continue
                case .run:
                    made.append(run(job, now: now, questions: questions, tasks: taskList))
                    job.due = BackgroundPlan.nextMorning(after: now, calendar: calendar)
                    job.held = nil
                    changed = true
                }
                break
            }
            state.queue[index] = job
        }
        heldBeforeLoad = [:]
        if !made.isEmpty {
            state.results += made
            changed = true
        }
        let pruned = Self.prune(state.results, now: now)
        if pruned != state.results { state.results = pruned; changed = true }
        if changed { unsaved = true }
        saveIfNeeded()
        lock.unlock()
        if changed { didChange() }
        return made
    }

    /// One job's run, with the lock held.
    private func run(_ job: BackgroundJob, now: Date, questions: [FeedItem], tasks: [AgentTask]) -> BackgroundResult {
        switch job.kind {
        case .morningSummary:
            // Overnight: since the last summary, or the evening before this one was due.
            let since = state.lastSummary ?? job.due - 12 * 60 * 60
            let summary = MorningSummary.count(questions: questions, tasks: tasks, since: since, now: now,
                                               late: job.held)
            state.lastSummary = now
            return BackgroundResult(madeAt: now, content: .morningSummary(summary))
        }
    }

    /// Newest first, the last week only, and never too many.
    static func prune(_ results: [BackgroundResult], now: Date) -> [BackgroundResult] {
        let kept = results
            .filter { now.timeIntervalSince($0.madeAt) <= BackgroundPlan.keepResultsFor }
            .sorted { $0.madeAt > $1.madeAt }
            .prefix(BackgroundPlan.maxResults)
        return results.filter { result in kept.contains { $0.id == result.id } }
    }

    // MARK: Asking

    /// Asks the person before anything consequential, through `NeedsYou`,
    /// so the question waits in Needs you and opens the usual sheet. `act`
    /// runs only after a yes from that sheet, and only if `AskFirst`
    /// agrees once more when it is checked, so a late or reused yes does
    /// nothing.
    ///
    /// Only while the person is here: a question stays open for
    /// `AskFirst.defaultWindow`, so one asked in the night would time out
    /// before anyone saw it. In the background this asks nothing.
    @discardableResult
    public func propose(_ action: ProposedAction, conditions: BackgroundConditions, at time: Date,
                        act: @escaping @Sendable () -> Void) -> ConfirmationRequest? {
        guard conditions.moment == .foreground, isOn, let needsYou else { return nil }
        let rule = needsYou.rule
        return needsYou.ask(action, at: time) { approval in
            guard rule.decide(action, approval: approval) == .proceed else { return }
            act()
        }
    }

    // MARK: Forgetting

    /// Forget everything: background work turns off, the queue and every
    /// card go, and the file is erased. Nothing is left to run. Throws if
    /// the file couldn't be erased; what was in memory is gone either way.
    public func forget() throws {
        toggle.set(false)
        lock.lock()
        state = .empty
        // Nothing to read back: the file is about to go.
        loaded = true
        unsaved = false
        heldBeforeLoad = [:]
        lock.unlock()
        defer { didChange() }
        try store.forget()
    }

    /// Takes one card away.
    public func dismiss(_ id: UUID) {
        change { $0.results.removeAll { $0.id == id } }
    }

    // MARK: Storage

    private func change(_ body: (inout BackgroundState) -> Void) {
        lock.lock()
        loadIfNeeded()
        let before = state
        body(&state)
        let changed = state != before
        if changed { unsaved = true }
        saveIfNeeded()
        lock.unlock()
        if changed { didChange() }
    }

    /// With the lock held. A file that can't be opened yet is left for
    /// the next look; anything changed meanwhile is laid over it then.
    private func loadIfNeeded() {
        guard !loaded else { return }
        do {
            let saved = try store.load()
            if unsaved {
                // Changes made before the file could be read win, since
                // they are newer. Cards from both are kept.
                let ids = Set(state.results.map(\.id))
                state.results = saved.results.filter { !ids.contains($0.id) } + state.results
                state.lastSummary = [state.lastSummary, saved.lastSummary].compactMap { $0 }.max()
            } else {
                state = saved
            }
            loaded = true
        } catch {
            // Locked. Try again next time.
        }
    }

    /// With the lock held. Writes only once the file has been read, and
    /// keeps the change for later if it can't be written now.
    private func saveIfNeeded() {
        guard unsaved, loaded else { return }
        if (try? store.save(state)) != nil { unsaved = false }
    }

    /// True while changes wait to be written, for tests.
    package var hasUnsavedChanges: Bool {
        lock.lock(); defer { lock.unlock() }
        return unsaved
    }
}

/// The runner's cards, as a source for Today. Local only.
public struct BackgroundFeed: FeedSource {
    public let runner: BackgroundRunner
    public let calendar: Calendar
    public let locale: Locale

    public init(runner: BackgroundRunner, calendar: Calendar = .current, locale: Locale = .current) {
        self.runner = runner
        self.calendar = calendar
        self.locale = locale
    }

    public var isSample: Bool { runner.isSample }

    public func items(now: Date) -> [FeedItem] {
        runner.results.map { $0.item(calendar: calendar, locale: locale) }
    }
}

/// Words for background work: the cards it leaves and the switch for it.
public enum BackgroundWords {
    public static let summaryTitle = "Your morning summary"

    /// "One thing was waiting for you. Two tasks finished overnight."
    public static func summaryBody(_ summary: MorningSummary) -> String {
        var lines = [waiting(summary.waiting), finished(summary.finished)]
        if summary.couldNotFinish > 0 { lines.append(couldNotFinish(summary.couldNotFinish)) }
        if let hold = summary.late { lines.append(late(hold)) }
        return lines.joined(separator: " ")
    }

    /// The summary opened to read: the counts, where to find what waits,
    /// and from when it counted.
    public static func summaryDetail(_ summary: MorningSummary, now: Date, calendar: Calendar,
                                     locale: Locale) -> String {
        var lines = [waiting(summary.waiting)]
        if summary.waiting > 0 { lines.append(whereWaiting) }
        lines.append(finished(summary.finished))
        if summary.couldNotFinish > 0 { lines.append(couldNotFinish(summary.couldNotFinish)) }
        lines.append(countedSince(summary.since, now: now, calendar: calendar, locale: locale))
        if let hold = summary.late { lines.append(late(hold)) }
        return lines.joined(separator: "\n\n")
    }

    static func waiting(_ count: Int) -> String {
        switch count {
        case 0: "Nothing was waiting for you."
        case 1: "One thing was waiting for you."
        default: "\(count) things were waiting for you."
        }
    }

    static func finished(_ count: Int) -> String {
        switch count {
        case 0: "Nothing finished overnight."
        case 1: "One task finished overnight."
        default: "\(count) tasks finished overnight."
        }
    }

    static func couldNotFinish(_ count: Int) -> String {
        count == 1 ? "One task couldn't finish." : "\(count) tasks couldn't finish."
    }

    /// Questions time out, so it says where to look rather than promise
    /// they are all still there.
    public static let whereWaiting = "Anything still waiting is at the top of Today, under Needs you."

    /// "I counted from 7:00 PM yesterday."
    static func countedSince(_ since: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = clock(since, calendar: calendar, locale: locale)
        if calendar.isDate(since, inSameDayAs: now) { return "I counted from \(time) today." }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(since, inSameDayAs: yesterday) {
            return "I counted from \(time) yesterday."
        }
        return "I counted from \(weekday(since, calendar: calendar, locale: locale)) at \(time)."
    }

    /// "7:00 PM", in the calendar's time zone.
    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone))
    }

    /// "Thursday", in the calendar's time zone.
    static func weekday(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
    }

    /// Why a summary came later than it was due.
    public static func late(_ hold: BackgroundHold) -> String {
        switch hold {
        case .locked: "I waited until you unlocked, so this came later than planned."
        case .lowPower: "Low Power Mode was on, so I waited and this came later than planned."
        case .outOfTime: "I ran out of time earlier, so this came later than planned."
        }
    }

    /// "I couldn't make Thursday's summary"
    public static func missedTitle(_ due: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "I couldn't make \(weekday(due, calendar: calendar, locale: locale))'s summary"
    }

    /// Why a summary's day ended before it could be made.
    public static func missed(_ hold: BackgroundHold?) -> String {
        switch hold {
        case .locked: "It stayed locked that morning, so I couldn't look in time."
        case .lowPower: "Low Power Mode was on that morning, so I let it go to save battery."
        case .outOfTime: "I ran out of time before I could make it."
        case nil: "I didn't get a chance to make it while the app was closed."
        }
    }

    // The switch, on the memory screen.

    public static let settingTitle = "Work while you're away"
    /// What the switch does, true for where it runs. The system decides
    /// when an iPhone or iPad app gets time while closed, so the line says
    /// "when I can" and names the catch up that always happens.
    public static func settingDetail(whileClosed: Bool) -> String {
        whileClosed
            ? "Each morning I'll put a short summary in Today of what's waiting for you and what finished overnight. I make it in the background when I can, or as soon as you open the app. I never send, buy or share anything without asking you first."
            : "Each morning I'll put a short summary in Today of what's waiting for you and what finished overnight. I make it while the app is open, even with no window showing, or as soon as you come back. I never send, buy or share anything without asking you first."
    }

    /// Under the switch while it is on: "The next one is due at 7:00 AM tomorrow."
    public static func nextDue(_ due: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = clock(due, calendar: calendar, locale: locale)
        if due <= now { return "The next one is due now." }
        if calendar.isDate(due, inSameDayAs: now) { return "The next one is due at \(time) today." }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
            return "The next one is due at \(time) tomorrow."
        }
        return "The next one is due \(weekday(due, calendar: calendar, locale: locale)) at \(time)."
    }
}
