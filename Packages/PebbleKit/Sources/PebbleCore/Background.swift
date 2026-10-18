import Foundation

// Work the agent does on its own while the app is closed, and the cards it
// leaves in Today. The runner here decides and remembers; the platform
// (`PebbleBackground`) only gives it time and says what the moment is like.
//
// The runner never sends, buys or shares. Its one job reads what is
// already here. Anything consequential is asked through `AskFirst` and
// waits in Needs you (`BackgroundRunner.propose`).

/// The identifiers the system knows the background tasks by, each the
/// app's bundle identifier plus a suffix, so no name is spelled here. The
/// app's Info.plist lists the refresh one, from project.yml as
/// `$(PRODUCT_BUNDLE_IDENTIFIER).background.refresh`, or the system
/// refuses it. `BackgroundTests` checks they match.
public enum BackgroundIdentifiers {
    public static let refreshSuffix = ".background.refresh"
    public static let macSuffix = ".background.mac"

    /// A short run in the morning, as `BGAppRefreshTask`. A two second
    /// count needs nothing longer.
    public static func refresh(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        (bundleIdentifier ?? "") + refreshSuffix
    }

    /// The Mac's `NSBackgroundActivityScheduler`. Needs no listing.
    public static func mac(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        (bundleIdentifier ?? "") + macSuffix
    }
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
    /// The device hadn't been unlocked since it started, so the file the
    /// results go in couldn't be opened.
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
    /// How many chances in a row passed it by, so the asks for time back
    /// off over a long night. Back to zero once it runs or moves on.
    public var holds: Int

    public init(id: UUID = UUID(), kind: BackgroundJobKind, due: Date, held: BackgroundHold? = nil, holds: Int = 0) {
        self.id = id
        self.kind = kind
        self.due = due
        self.held = held
        self.holds = holds
    }

    private enum CodingKeys: String, CodingKey { case id, kind, due, held, holds }

    /// A file from before `holds` was kept reads as none.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(BackgroundJobKind.self, forKey: .kind)
        due = try values.decode(Date.self, forKey: .due)
        held = try values.decodeIfPresent(BackgroundHold.self, forKey: .held)
        holds = try values.decodeIfPresent(Int.self, forKey: .holds) ?? 0
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
    /// True while the runner's file can't be opened yet, as before the
    /// first unlock since the device started. This is not the screen
    /// lock: a phone locked again after that still opens the file, so this
    /// is false and the summary is made overnight. It comes from trying
    /// the file, through `background(store:lowPower:deadline:)`.
    public var fileShut: Bool
    /// When the system takes the time back. Nil when there is no limit.
    public var deadline: Date?

    public init(moment: Moment, lowPower: Bool = false, fileShut: Bool = false, deadline: Date? = nil) {
        self.moment = moment
        self.lowPower = lowPower
        self.fileShut = fileShut
        self.deadline = deadline
    }

    /// The app is open and in front: unlocked, with no time limit. Low
    /// Power Mode doesn't hold back a run here, since the person is here
    /// and the summary only counts what is on screen anyway.
    public static let foreground = BackgroundConditions(moment: .foreground)

    /// A run the system gave time for while the app was closed. Whether the
    /// file is shut is found by trying to open `store`, never from the
    /// screen or from whether protected data is available, so a run while
    /// the screen is locked after the first unlock goes ahead.
    public static func background(store: BackgroundStore, lowPower: Bool, deadline: Date?) -> BackgroundConditions {
        BackgroundConditions(moment: .background, lowPower: lowPower, fileShut: store.isShut, deadline: deadline)
    }
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
    /// After this many holds in a row, each ask waits twice as long as the
    /// one before, up to `longestRetry`.
    public static let holdsBeforeBackingOff = 3
    public static let longestRetry: TimeInterval = 2 * 60 * 60
    /// How often the Mac looks while the app is running. Its own value:
    /// a different thing from the wait after a hold, though the same today.
    public static let macLookInterval: TimeInterval = 15 * 60
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

    /// Whether `job` runs now. Held back before the first unlock since the
    /// device started, and in the background while Low Power Mode is on or
    /// there isn't the time to finish. Missed once its day is over,
    /// whatever the moment.
    public static func decide(_ job: BackgroundJob, now: Date, conditions: BackgroundConditions,
                              calendar: Calendar) -> BackgroundDecision {
        if now < job.due { return .notYet(job.due) }
        if now >= lastChance(for: job, calendar: calendar) { return .missed }
        if conditions.fileShut { return .hold(.locked) }
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
        queue.map { $0.due > now ? $0.due : now + retry(afterHolds: $0.holds) }.min()
    }

    /// How long to wait before asking again after `holds` holds in a row:
    /// a quarter hour for the first few, then twice as long each time, so
    /// a night in Low Power Mode or before the first unlock isn't woken
    /// every quarter hour until it ends.
    public static func retry(afterHolds holds: Int) -> TimeInterval {
        let doublings = min(max(0, holds - holdsBeforeBackingOff), 8)
        return min(retryAfterHold * Double(1 << doublings), longestRetry)
    }

    /// Where a missed job goes next: this morning if today's is still to
    /// come or still today, so it runs now if it can.
    static func afterMissing(now: Date, calendar: Calendar) -> Date {
        morning(of: now, calendar: calendar)
    }

    /// The morning of the last day a missed job went without, when that
    /// is a later day than the one it was due: every day before today was
    /// missed. Nil when only its own day was.
    public static func lastMissedDay(_ job: BackgroundJob, now: Date, calendar: Calendar) -> Date? {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
              calendar.startOfDay(for: job.due) < yesterday else { return nil }
        return morning(of: yesterday, calendar: calendar)
    }
}

/// What a morning summary found. Only counts and times, so nothing a task
/// held or a question asked is kept here, and forgetting tasks leaves no
/// words of theirs behind in a summary.
///
/// A count is nil when it couldn't be known: there was nothing to count it
/// from, or what it comes from lives only in memory and the app wasn't
/// running for the whole time it covers. Its line is left out then, never
/// said as zero.
public struct MorningSummary: Codable, Sendable, Equatable {
    /// Questions open in Needs you and tasks waiting on the person.
    public let waiting: Int?
    /// Tasks that finished since `since`.
    public let finished: Int?
    /// Tasks that couldn't finish since `since`.
    public let couldNotFinish: Int?
    /// Counted from here: the summary before, or the evening before.
    public let since: Date
    /// Why it was made later than it was due, if it was held back.
    public let late: BackgroundHold?

    public init(waiting: Int?, finished: Int?, couldNotFinish: Int?, since: Date, late: BackgroundHold?) {
        self.waiting = waiting
        self.finished = finished
        self.couldNotFinish = couldNotFinish
        self.since = since
        self.late = late
    }

    /// Counts what is really here: the open questions, and the tasks. A
    /// task counts as finished only if it ended between `since` and `now`.
    /// A task waiting on the person counts once, even if its question is
    /// in `questions` too. Nil `questions` means Needs you couldn't be
    /// seen, so nothing waiting is counted; nil `tasks` means there were
    /// no tasks to see, so nothing finished is counted.
    ///
    /// What is waiting is open now, so it is known whenever it can be seen.
    /// What finished is about the whole window, so it is known only if
    /// the tasks were watched for all of it: `watchedWindow`.
    public static func count(questions: [FeedItem]?, tasks: [AgentTask]?, since: Date, now: Date,
                             late: BackgroundHold?, watchedWindow: Bool = true) -> MorningSummary {
        let window = since...now
        let ended = watchedWindow ? tasks?.filter { !$0.isActive && window.contains($0.updatedAt) } : nil
        let waitingTasks = tasks?.filter { $0.state == .waitingOnYou }
        let taskQuestions = Set((waitingTasks ?? []).compactMap { $0.question?.id })
        let asks = questions?.filter { item in
            guard item.kind == .needsYou else { return false }
            if case .review(let request) = item.action, taskQuestions.contains(request.id) { return false }
            return true
        }
        return MorningSummary(
            waiting: asks.map { $0.count + (waitingTasks?.count ?? 0) },
            finished: ended?.filter { $0.state == .done }.count,
            couldNotFinish: ended?.filter { $0.state == .failed }.count,
            since: since, late: late)
    }

    /// Nothing to report: every count that could be known is zero.
    public var isQuiet: Bool { (waiting ?? 0) == 0 && (finished ?? 0) == 0 && (couldNotFinish ?? 0) == 0 }

    /// Nothing could be counted at all.
    public var countedNothing: Bool { waiting == nil && finished == nil && couldNotFinish == nil }
}

/// Something a run left for Today.
public struct BackgroundResult: Codable, Sendable, Equatable, Identifiable {
    public enum Content: Codable, Sendable, Equatable {
        case morningSummary(MorningSummary)
        /// A job whose day ended before it could run. `through` is the last
        /// day missed when more than one went by, so the card names them all.
        case missed(kind: BackgroundJobKind, due: Date, held: BackgroundHold?, through: Date? = nil)
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
            let body = BackgroundWords.summaryBody(summary, now: madeAt, calendar: calendar, locale: locale)
            // The runner no longer leaves quiet ones; a file from before may hold one.
            guard !summary.isQuiet else {
                return FeedItem(id: id, kind: .did, time: madeAt, title: BackgroundWords.summaryTitle, body: body)
            }
            return FeedItem(id: id, kind: .ready, time: madeAt, title: BackgroundWords.summaryTitle, body: body,
                            action: .open(BackgroundWords.summaryDetail(summary, now: madeAt, calendar: calendar,
                                                                        locale: locale)))
        case .missed(_, let due, let held, let through):
            guard let through else {
                return FeedItem(id: id, kind: .noticed, time: madeAt,
                                title: BackgroundWords.missedTitle(due, calendar: calendar, locale: locale),
                                body: BackgroundWords.missed(held))
            }
            return FeedItem(id: id, kind: .noticed, time: madeAt,
                            title: BackgroundWords.missedTitle(from: due, through: through, calendar: calendar,
                                                               locale: locale),
                            body: BackgroundWords.missedSeveral)
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
///
/// It also keeps when the next job is due, why a run waited before the
/// runner's file could be read, and whether a Forget everything still has
/// that file to erase: a bool, dates and a reason, nothing of the person's,
/// so they can live where a launch before the first unlock can read and
/// write them. The next launch, often a new process, still knows them.
public protocol BackgroundSwitch: Sendable {
    var isOn: Bool { get }
    func set(_ on: Bool)
    /// False when the switch couldn't be read just now, so off may not be
    /// off. The runner never takes that as off.
    var isKnown: Bool { get }
    /// The soonest job's due time, as last known. Nil with nothing queued.
    var nextDue: Date? { get }
    func setNextDue(_ due: Date?)
    /// A run held back before the file could be read, and when. Nil once
    /// the file has taken it.
    var heldBeforeLoad: BackgroundHeldRun? { get }
    func setHeldBeforeLoad(_ held: BackgroundHeldRun?)
    /// True from the start of a Forget everything until the runner's file
    /// is erased, so a file that couldn't be erased is tried again, and
    /// nothing in it is shown or run meanwhile.
    var forgetPending: Bool { get }
    func setForgetPending(_ pending: Bool)
}

/// A run that waited before the runner's file could be read.
public struct BackgroundHeldRun: Codable, Sendable, Equatable {
    public let hold: BackgroundHold
    /// The latest time it waited.
    public let at: Date
    /// How many times it waited, so the asks for time back off.
    public let count: Int

    public init(hold: BackgroundHold, at: Date, count: Int = 1) {
        self.hold = hold
        self.at = at
        self.count = count
    }
}

/// The switch, in a small file of its own next to the runner's.
///
/// It holds only a bool, the next due time, why a run waited and whether a
/// Forget everything is pending: nothing of the person's, no words and no
/// counts. So it is written with no file protection, and a run before the
/// first unlock since the device started can read whether it may go ahead
/// and keep why it waited. `UserDefaults` can't be read then.
///
/// An earlier version kept the switch in `UserDefaults`. Until the switch
/// is set here, it is read from there, and moved here the first time
/// `UserDefaults` has it, so a launch before the first unlock, which sees
/// nothing there, never writes it over as off.
public final class FileBackgroundSwitch: BackgroundSwitch, @unchecked Sendable {
    /// No protection: what this file holds is safe to read before the
    /// first unlock, and has to be.
    public static let fileProtection: FileProtectionType = .none

    /// Where the earlier version kept it.
    public enum LegacyKeys {
        public static let on = "backgroundWork.on"
        public static let nextDue = "backgroundWork.nextDue"
        public static let held = "backgroundWork.held"
        public static let heldAt = "backgroundWork.heldAt"
        static let all = [on, nextDue, held, heldAt]
    }

    struct Saved: Codable, Equatable {
        /// Nil until set here or moved from `UserDefaults`.
        var on: Bool?
        var nextDue: Date?
        var held: BackgroundHeldRun?
        var forgetPending: Bool?
    }

    public let fileURL: URL
    private let defaults: UserDefaults?
    private let writer: ProtectedWriter
    private let lock = NSLock()
    /// What was last read or written. Nil until the file is read.
    private var saved: Saved?
    /// True while the file is there but couldn't be read. Nothing is
    /// written over it then; changes wait in `waiting`.
    private var unreadable = false
    /// Changes made while the file couldn't be read, laid over it once it can.
    private var waiting: [(inout Saved) -> Void] = []

    /// `defaults` is where an earlier version kept the switch, to move from.
    package init(fileURL: URL, defaults: UserDefaults? = nil, writer: ProtectedWriter = .disk) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.writer = writer
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: FileBackgroundSwitch?

    /// The one switch, beside the runner's file.
    public static func onDevice(fileManager: FileManager = .default,
                                defaults: UserDefaults = .standard) throws -> FileBackgroundSwitch {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let folder = try MemoryStore.onDeviceFolder(fileManager: fileManager)
        let toggle = FileBackgroundSwitch(fileURL: folder.appendingPathComponent("background-switch.json"),
                                          defaults: defaults)
        shared = toggle
        return toggle
    }

    package var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    public var isOn: Bool { read { $0.on ?? false } }
    public func set(_ on: Bool) { update { $0.on = on } }

    public var isKnown: Bool { read { _ in !unreadable } }

    public var nextDue: Date? { read(\.nextDue) }
    public func setNextDue(_ due: Date?) { update { $0.nextDue = due } }

    public var heldBeforeLoad: BackgroundHeldRun? { read(\.held) }
    public func setHeldBeforeLoad(_ held: BackgroundHeldRun?) { update { $0.held = held } }

    public var forgetPending: Bool { read { $0.forgetPending ?? false } }
    public func setForgetPending(_ pending: Bool) { update { $0.forgetPending = pending ? true : nil } }

    private func read<T>(_ value: (Saved) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value(current())
    }

    private func update(_ body: @escaping (inout Saved) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var next = current()
        body(&next)
        if unreadable {
            waiting.append(body)
            saved = next
            return
        }
        guard next != saved else { return }
        saved = next
        write(next)
    }

    /// With the lock held. What the file says, with anything still kept in
    /// `UserDefaults` moved over.
    private func current() -> Saved {
        if saved == nil || unreadable { reload() }
        var value = saved ?? Saved()
        if value.on == nil { moveFromDefaults(&value) }
        return value
    }

    /// With the lock held.
    private func reload() {
        if let data = FileManager.default.contents(atPath: fileURL.path) {
            // A file that can't be decoded starts over: it holds nothing
            // of the person's.
            var read = (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
            for change in waiting { change(&read) }
            let changed = !waiting.isEmpty
            waiting = []
            unreadable = false
            saved = read
            if changed { write(read) }
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            unreadable = true
            if saved == nil { saved = Saved() }
        } else {
            // No file: what is in memory is all there is.
            let changed = !waiting.isEmpty
            waiting = []
            unreadable = false
            if saved == nil { saved = Saved() }
            if changed, let saved { write(saved) }
        }
    }

    /// With the lock held. Until the switch is set here, `UserDefaults`
    /// is read each time, since before the first unlock it reads as empty.
    private func moveFromDefaults(_ value: inout Saved) {
        guard let defaults, defaults.object(forKey: LegacyKeys.on) != nil else { return }
        value.on = defaults.bool(forKey: LegacyKeys.on)
        if value.nextDue == nil { value.nextDue = defaults.object(forKey: LegacyKeys.nextDue) as? Date }
        if value.held == nil, let raw = defaults.string(forKey: LegacyKeys.held),
           let hold = BackgroundHold(rawValue: raw), let at = defaults.object(forKey: LegacyKeys.heldAt) as? Date {
            value.held = BackgroundHeldRun(hold: hold, at: at)
        }
        saved = value
        // Moved once: the old keys go only once the file has it.
        guard !unreadable, write(value) else { return }
        for key in LegacyKeys.all { defaults.removeObject(forKey: key) }
    }

    /// With the lock held. Staged and renamed over the file, as the other
    /// stores write theirs.
    @discardableResult
    private func write(_ value: Saved) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try writer.write(data, stagingURL, Self.fileProtection)
            guard rename(stagingURL.path, fileURL.path) == 0 else {
                try? FileManager.default.removeItem(at: stagingURL)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Removes the file, for tests.
    package func removeFile() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: stagingURL)
        saved = nil
    }
}

/// A switch held in memory, for tests and screenshots.
public final class InMemoryBackgroundSwitch: BackgroundSwitch, @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private var due: Date?
    private var held: BackgroundHeldRun?
    private var pending = false

    public init(on: Bool = false, nextDue: Date? = nil) {
        self.on = on
        due = nextDue
    }

    public var isKnown: Bool { true }

    public var heldBeforeLoad: BackgroundHeldRun? {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    public func setHeldBeforeLoad(_ held: BackgroundHeldRun?) {
        lock.lock()
        self.held = held
        lock.unlock()
    }

    public var forgetPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    public func setForgetPending(_ pending: Bool) {
        lock.lock()
        self.pending = pending
        lock.unlock()
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

    public var nextDue: Date? {
        lock.lock(); defer { lock.unlock() }
        return due
    }

    public func setNextDue(_ due: Date?) {
        lock.lock()
        self.due = due
        lock.unlock()
    }
}

/// The runner's file, next to the notes: in the same folder and left out of
/// backups. On iPhone and iPad it opens once the device has been unlocked
/// since it started, so a run in the night can write the summary. It holds
/// only counts, times and kinds, never words from the notes, the private
/// words or a chat, which keep the strictest protection. Before that first
/// unlock the runner holds its work back.
public final class BackgroundStore: @unchecked Sendable {
    /// The file is there but can't be opened right now, as before the
    /// first unlock.
    public struct Unavailable: Error, Equatable {}

    /// The file and its staged copy, which the rename turns into the file.
    public static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    public let fileURL: URL
    /// True for a store that keeps nothing on disk, for the showcase.
    private let diskless: Bool
    private let writer: ProtectedWriter
    /// The errors opening the file gives while its protection keeps it
    /// shut. A file shut by its protection class gives `EPERM`; anything
    /// else, such as a disk error, is not the lock.
    private let shutErrors: Set<Int32>
    private let lock = NSLock()

    /// Package access: the app uses `onDevice()`. Tests point a store at a
    /// scratch file, and may fake the lock with another error.
    package init(fileURL: URL, writer: ProtectedWriter = .disk, shutErrors: Set<Int32> = [EPERM]) {
        self.fileURL = fileURL
        diskless = false
        self.writer = writer
        self.shutErrors = shutErrors
    }

    private init(diskless: Void) {
        fileURL = URL(fileURLWithPath: "/dev/null")
        self.diskless = true
        writer = .disk
        shutErrors = []
    }

    /// A store that writes nothing anywhere, so the showcase leaves no file
    /// behind however often it launches. What its runner makes lives only
    /// in memory.
    package static func memoryOnly() -> BackgroundStore {
        BackgroundStore(diskless: ())
    }

    /// Where a save is written before it takes the file's place.
    package var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: BackgroundStore?

    /// The one store, in the notes' folder.
    public static func onDevice(fileManager: FileManager = .default) throws -> BackgroundStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let folder = try MemoryStore.onDeviceFolder(fileManager: fileManager)
        let store = BackgroundStore(fileURL: folder.appendingPathComponent("background.json"))
        shared = store
        return store
    }

    public var hasStoredFile: Bool {
        guard !diskless else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: stagingURL.path)
    }

    /// Whether the file can be opened now. False while it is there but
    /// won't open, whatever the reason. True with no file.
    public var canOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openError() == nil
    }

    /// True while the file is there and its protection keeps it shut, as
    /// before the first unlock since the device started. Found by trying
    /// to open it, so a phone whose screen is locked after that first
    /// unlock opens the file, and this is false.
    public var isShut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openError().map(shutErrors.contains) ?? false
    }

    /// With the lock held. Why the file won't open, or nil if it opens or
    /// isn't there.
    private func openError() -> Int32? {
        guard !diskless, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let descriptor = open(fileURL.path, O_RDONLY)
        guard descriptor < 0 else {
            close(descriptor)
            return nil
        }
        return errno
    }

    /// What was kept. Empty with no file. A file that can't be decoded,
    /// as from a newer version, starts over: it holds only counts and
    /// times the runner made, nothing of the person's own.
    public func load() throws -> BackgroundState {
        lock.lock()
        defer { lock.unlock() }
        guard !diskless, FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { throw Unavailable() }
        return (try? JSONDecoder().decode(BackgroundState.self, from: data)) ?? .empty
    }

    public func save(_ state: BackgroundState) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !diskless else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // A staged copy left by a save cut short goes first, or the write,
        // which never replaces a file, would fail every time after.
        try removeStaged()
        try writer.write(data, stagingURL, Self.fileProtection)
        guard rename(stagingURL.path, fileURL.path) == 0 else {
            try? removeStaged()
            throw Unavailable()
        }
    }

    /// Removes the file and any staged copy.
    public func forget() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !diskless else { return }
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

/// One stretch of time the system gave for a run. When the system takes it
/// back, only this run hears it, so a late call can't hold back the next.
public final class BackgroundTime: @unchecked Sendable {
    private let lock = NSLock()
    private var up = false

    public init() {}

    /// The system is taking its time back. Whatever hasn't run in this
    /// run waits for the next chance, and its card will say it ran out of time.
    public func timeIsUp() {
        lock.lock()
        up = true
        lock.unlock()
    }

    public var isUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return up
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
/// What it keeps lives in `store`, which can't be opened before the first
/// unlock since the device started. Until it can, the runner holds what
/// changed in memory and writes it at the next chance.
public final class BackgroundRunner: @unchecked Sendable {
    public let store: BackgroundStore
    public let needsYou: NeedsYou?
    public let tasks: (any TaskEngine)?
    /// Since when `needsYou` and `tasks` have been watching: this launch
    /// of the app. They live in memory only, so a summary whose window
    /// began earlier can't count from them, and leaves those lines out.
    public let watchingSince: Date
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
    /// Turned on or off before the file could be read. The queue saved in
    /// the file then follows this, so an old queue never comes back.
    private var switchedBeforeLoad: Bool?
    /// A run held back before the file could be read, kept here too in
    /// case the switch couldn't keep it.
    private var heldWaiting: BackgroundHeldRun?
    /// A Forget everything whose file is still to be erased, kept here too
    /// in case the switch couldn't keep it.
    private var forgetWaiting = false
    /// Questions `propose` asked and not yet answered, so turning off or
    /// forgetting can withdraw them.
    private var proposals: [ConfirmationRequest] = []
    private var observers: [Observation: @Sendable () -> Void] = [:]

    /// `sample` marks the cards as examples, for the showcase. A runner
    /// reading scripted tasks or sample questions is an example too.
    public init(store: BackgroundStore, toggle: any BackgroundSwitch, needsYou: NeedsYou? = nil,
                tasks: (any TaskEngine)? = nil, watchingSince: Date = Date(), calendar: Calendar = .current,
                sample: Bool = false) {
        self.store = store
        self.toggle = toggle
        self.needsYou = needsYou
        self.tasks = tasks
        self.watchingSince = watchingSince
        self.calendar = calendar
        self.sample = sample
    }

    /// The app's runner, on the device's store with the switch beside it.
    /// It reads the same `needsYou` and `tasks` as Today, which have been
    /// watching since `launchedAt`. Nil if the folder can't be made.
    public static func onDevice(needsYou: NeedsYou, tasks: (any TaskEngine)?, launchedAt: Date = Date(),
                                store: () throws -> BackgroundStore = { try BackgroundStore.onDevice() },
                                toggle: () throws -> any BackgroundSwitch = { try FileBackgroundSwitch.onDevice() },
                                calendar: Calendar = .current) -> BackgroundRunner? {
        guard let store = try? store(), let toggle = try? toggle() else { return nil }
        return BackgroundRunner(store: store, toggle: toggle, needsYou: needsYou, tasks: tasks,
                                watchingSince: launchedAt, calendar: calendar)
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

    /// What the switch says, as far as can be told now.
    public enum SwitchReading: Sendable, Equatable {
        case on, off
        /// It reads off, but may not have been read: the switch says so, or
        /// it reads off while the runner's file is shut, before the first
        /// unlock, when a switch kept where nothing opens then would read
        /// off too. Never taken as off, so nothing is cancelled on its word.
        case unknown
    }

    public var switchReading: SwitchReading {
        if toggle.isOn { return .on }
        return toggle.isKnown && !store.isShut ? .off : .unknown
    }

    /// Turns background work on, with the morning summary due at the next
    /// morning. Turning it on again changes nothing.
    public func turnOn(now: Date) {
        toggle.set(true)
        change(switching: true) { state in
            guard !state.queue.contains(where: { $0.kind == .morningSummary }) else { return }
            state.queue.append(BackgroundJob(kind: .morningSummary,
                                             due: BackgroundPlan.nextMorning(after: now, calendar: calendar)))
        }
    }

    /// Turns it off. The queue goes, so nothing more runs, and any question
    /// it asked is withdrawn. Cards already made stay until they are
    /// forgotten. The next summary after turning on again counts from the
    /// evening before it, never across the days it was off. A run that
    /// waited for the file is forgotten too, so it is never said of a job
    /// queued after turning on again.
    public func turnOff() {
        toggle.set(false)
        clearHeldBeforeLoad()
        change(switching: false) { state in
            state.queue.removeAll()
            state.lastSummary = nil
        }
        withdrawProposals()
    }

    private func clearHeldBeforeLoad() {
        lock.lock()
        heldWaiting = nil
        lock.unlock()
        toggle.setHeldBeforeLoad(nil)
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
    /// or with nothing queued. While the switch is on but the file can't
    /// be read yet, or the switch can't be told from off, the queue may
    /// still be in the file, so the ask is never cancelled: it asks for
    /// the due time the switch keeps, or a little later if that has come
    /// or isn't known, backing off as the holds add up.
    public func nextWake(now: Date) -> Date? {
        let reading = switchReading
        guard reading != .off else { return nil }
        lock.lock()
        loadIfNeeded()
        let isLoaded = loaded
        let queue = state.queue
        let holds = latestHeld?.count ?? 0
        lock.unlock()
        guard isLoaded, reading == .on else {
            if let due = toggle.nextDue, due > now { return due }
            return now + BackgroundPlan.retry(afterHolds: holds)
        }
        return BackgroundPlan.nextWake(for: queue, now: now)
    }

    /// True when a run just now did the work it was given time for, so the
    /// platform can tell the system. False while off, or while it can't be
    /// told from off, since nothing was done; false when the file couldn't
    /// be read, as before the first unlock or after a disk error; and false
    /// while a job that is due waits because a run was held back.
    public func didItsWork(now: Date) -> Bool {
        guard switchReading == .on else { return false }
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard loaded, !forgetIsPending else { return false }
        return !state.queue.contains { $0.held != nil && $0.due <= now }
    }

    /// The cards, as a source for Today.
    public var feed: BackgroundFeed { BackgroundFeed(runner: self) }

    // MARK: Running

    /// Runs every job that is due and may run now. Returns the cards made.
    ///
    /// Called by the platform with the moment it reports and the `time` it
    /// gave, and by Today whenever it refreshes, so a summary the system
    /// never woke the app for is made as soon as the person opens it.
    @discardableResult
    public func runDue(now: Date, conditions: BackgroundConditions,
                       time: BackgroundTime? = nil) -> [BackgroundResult] {
        // Off is off. A switch that can't be told from off goes as far as
        // keeping why the run waited, but runs nothing.
        let reading = switchReading
        guard reading != .off else { return [] }
        // Read outside the runner's lock: `NeedsYou` and the engine take
        // their own, and may call back.
        let questions = needsYou?.items(now: now)
        let taskList = tasks?.tasks

        lock.lock()
        loadIfNeeded()
        guard loaded, reading == .on else {
            // The file can't be opened, so neither can anything be written.
            // If that is because it is shut until the first unlock, say so
            // beside the switch, where the next launch reads it, and here,
            // in case the switch can't keep it, for the card that comes
            // later. Anything else, such as a disk error, is no lock, and
            // no reason is claimed.
            if !loaded, conditions.fileShut {
                let held = BackgroundHeldRun(hold: .locked, at: now, count: (latestHeld?.count ?? 0) + 1)
                heldWaiting = held
                toggle.setHeldBeforeLoad(held)
            }
            lock.unlock()
            return []
        }
        var made: [BackgroundResult] = []
        var changed = false
        for index in state.queue.indices {
            var job = state.queue[index]
            // At most twice: a missed job moves to this morning and may run now.
            for _ in 0..<2 {
                var decision = BackgroundPlan.decide(job, now: now, conditions: conditions, calendar: calendar)
                if decision == .run, time?.isUp == true { decision = .hold(.outOfTime) }
                switch decision {
                case .notYet:
                    break
                case .hold(let reason):
                    // Counted only in the background, where each hold asks
                    // for time again: the person opening the app isn't a wake.
                    if conditions.moment == .background { job.holds += 1; changed = true }
                    if job.held != reason { job.held = reason; changed = true }
                case .missed:
                    // With no tasks to count and Needs you in memory only, a
                    // day the app never ran would almost always have been
                    // quiet, and a quiet morning leaves no card. So no card
                    // claims a summary was missed; the job still moves on.
                    //
                    // `lastSummary` stays as it was, so the next summary's
                    // window can reach back days: its words then say "since
                    // Tuesday" rather than "overnight", and `watchedWindow`
                    // leaves out what finished unless it was watched all along.
                    if self.tasks != nil {
                        made.append(BackgroundResult(madeAt: now, content: .missed(
                            kind: job.kind, due: job.due, held: job.held,
                            through: BackgroundPlan.lastMissedDay(job, now: now, calendar: calendar))))
                    }
                    job.due = BackgroundPlan.afterMissing(now: now, calendar: calendar)
                    job.held = nil
                    job.holds = 0
                    changed = true
                    continue
                case .run:
                    if let result = run(job, now: now, questions: questions, tasks: taskList) { made.append(result) }
                    job.due = BackgroundPlan.nextMorning(after: now, calendar: calendar)
                    job.held = nil
                    job.holds = 0
                    changed = true
                }
                break
            }
            state.queue[index] = job
        }
        if !made.isEmpty {
            state.results += made
            changed = true
        }
        let pruned = Self.prune(state.results, now: now)
        if pruned != state.results { state.results = pruned; changed = true }
        if changed { unsaved = true }
        saveIfNeeded()
        syncNextDue()
        lock.unlock()
        if changed { didChange() }
        return made
    }

    /// One job's run, with the lock held. Nil `questions` or `tasks` has
    /// nothing to count from. Nil back on a quiet morning: nothing was
    /// waiting and nothing finished, so there is no card to leave.
    private func run(_ job: BackgroundJob, now: Date, questions: [FeedItem]?, tasks: [AgentTask]?) -> BackgroundResult? {
        switch job.kind {
        case .morningSummary:
            // Since the last summary, or the evening before this one was due.
            let since = state.lastSummary ?? job.due - 12 * 60 * 60
            // What is waiting is open now, so it counts whenever it can be
            // seen. What finished lives in memory, so it is known only if
            // it was watched from the window's start.
            let summary = MorningSummary.count(questions: questions, tasks: tasks, since: since, now: now,
                                               late: job.held, watchedWindow: watchingSince <= since)
            state.lastSummary = now
            guard !summary.isQuiet else { return nil }
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
    ///
    /// Turning background work off, or Forget everything, withdraws the
    /// question. A yes that still arrives does nothing while it is off.
    @discardableResult
    public func propose(_ action: ProposedAction, conditions: BackgroundConditions, at time: Date,
                        act: @escaping @Sendable () -> Void) -> ConfirmationRequest? {
        guard conditions.moment == .foreground, isOn, let needsYou else { return nil }
        let rule = needsYou.rule
        let asked = needsYou.ask(action, at: time) { [weak self] approval in
            guard let self else { return }
            self.answered(approval.id)
            // Checked again here: it may have been turned off since it asked.
            guard self.isOn, rule.decide(action, approval: approval) == .proceed else { return }
            act()
        }
        guard let asked else { return nil }
        lock.lock()
        proposals.removeAll { rule.isClosed($0) }
        proposals.append(asked)
        lock.unlock()
        return asked
    }

    private func answered(_ id: UUID) {
        lock.lock()
        proposals.removeAll { $0.id == id }
        lock.unlock()
    }

    /// Withdraws every question `propose` asked, through the rule, so none
    /// can be approved later, and takes them out of Needs you.
    private func withdrawProposals() {
        lock.lock()
        let open = proposals
        proposals = []
        lock.unlock()
        guard let needsYou else { return }
        for request in open {
            needsYou.rule.withdraw(request)
            needsYou.dismissed(request)
        }
    }

    // MARK: Forgetting

    /// Forget everything: background work turns off, any question it asked
    /// is withdrawn, the queue and every card go, and the file is erased.
    /// Nothing is left to run. Throws if the file couldn't be erased; what
    /// was in memory is gone either way, and the erase is tried again the
    /// next time the runner looks, in this launch or a later one. Until it
    /// goes, nothing in that file is shown, run or written over.
    public func forget() throws {
        // Kept beside the switch first, so a launch after a failed erase
        // knows the file is not to be read.
        toggle.setForgetPending(true)
        toggle.set(false)
        toggle.setNextDue(nil)
        withdrawProposals()
        lock.lock()
        forgetWaiting = true
        state = .empty
        // Nothing to read back: the file is about to go.
        loaded = true
        unsaved = false
        switchedBeforeLoad = nil
        heldWaiting = nil
        lock.unlock()
        toggle.setHeldBeforeLoad(nil)
        defer { didChange() }
        lock.lock()
        defer { lock.unlock() }
        try eraseForgottenFile()
    }

    /// With the lock held. True while a Forget everything still has the
    /// file to erase.
    private var forgetIsPending: Bool { forgetWaiting || toggle.forgetPending }

    /// With the lock held. Erases the file a Forget everything left, if
    /// there is one, and says so beside the switch once it is gone.
    private func eraseForgottenFile() throws {
        guard forgetIsPending else { return }
        try store.forget()
        forgetWaiting = false
        toggle.setForgetPending(false)
    }

    /// Takes one card away.
    public func dismiss(_ id: UUID) {
        change { $0.results.removeAll { $0.id == id } }
    }

    // MARK: Storage

    /// `switching` is set when the switch was turned on or off. If the
    /// file can't be read yet, that is remembered and wins over the queue
    /// in the file once it can.
    private func change(switching: Bool? = nil, _ body: (inout BackgroundState) -> Void) {
        lock.lock()
        loadIfNeeded()
        let before = state
        body(&state)
        var changed = state != before
        if !loaded, let switching {
            switchedBeforeLoad = switching
            changed = true
        }
        if changed { unsaved = true }
        saveIfNeeded()
        syncNextDue()
        lock.unlock()
        if changed { didChange() }
    }

    /// With the lock held. Keeps the soonest due time beside the switch,
    /// so a launch that can't read the file still asks for the right time.
    /// Before the file is read, turning on keeps the sooner of the two:
    /// the file's job keeps its time once it can be read.
    private func syncNextDue() {
        let soonest = state.queue.map(\.due).min()
        let due: Date?
        if !toggle.isOn {
            due = nil
        } else if loaded {
            due = soonest
        } else {
            due = [toggle.nextDue, soonest].compactMap { $0 }.min()
        }
        if toggle.nextDue != due { toggle.setNextDue(due) }
    }

    /// With the lock held. A file that can't be opened yet is left for
    /// the next look; anything changed meanwhile is laid over it then.
    /// A file Forget everything couldn't erase is erased first, and while
    /// it still can't be, it is never read: none of its cards come back.
    private func loadIfNeeded() {
        let erased = (try? eraseForgottenFile()) != nil
        guard !loaded else { return }
        guard erased else {
            // Started from nothing, as Forget everything left it.
            switchedBeforeLoad = nil
            loaded = true
            applyHeldBeforeLoad()
            return
        }
        do {
            let saved = try store.load()
            if unsaved {
                // Changes made before the file could be read win, since
                // they are newer. Cards from both are kept. Turned off
                // meanwhile, the saved queue goes; turned on, a saved job
                // keeps its time and why it was held.
                let ids = Set(state.results.map(\.id))
                state.results = saved.results.filter { !ids.contains($0.id) } + state.results
                state.lastSummary = [state.lastSummary, saved.lastSummary].compactMap { $0 }.max()
                switch switchedBeforeLoad {
                case false?:
                    state.queue = []
                    state.lastSummary = nil
                case true?:
                    if saved.queue.contains(where: { $0.kind == .morningSummary }) { state.queue = saved.queue }
                case nil: state.queue = saved.queue
                }
            } else {
                state = saved
            }
            switchedBeforeLoad = nil
            loaded = true
            applyHeldBeforeLoad()
            // What waited for the file goes into it now, so the next launch
            // reads it too.
            saveIfNeeded()
            syncNextDue()
        } catch {
            // Locked. Try again next time.
        }
    }

    /// With the lock held, once the file is read. A run that waited before
    /// then, in this launch or an earlier one, goes on its job, so the card
    /// can say why. A hold from before the job was due held nothing back,
    /// and is never said.
    private func applyHeldBeforeLoad() {
        guard let held = latestHeld else { return }
        for index in state.queue.indices where state.queue[index].held == nil && held.at >= state.queue[index].due {
            state.queue[index].held = held.hold
            state.queue[index].holds += held.count
            unsaved = true
        }
        heldWaiting = nil
        if toggle.heldBeforeLoad != nil { toggle.setHeldBeforeLoad(nil) }
    }

    /// With the lock held. The latest run that waited for the file, as
    /// the switch kept it or, if it couldn't, as this launch did.
    private var latestHeld: BackgroundHeldRun? {
        [toggle.heldBeforeLoad, heldWaiting].compactMap { $0 }.max { $0.at < $1.at }
    }

    /// With the lock held. Writes only once the file has been read, never
    /// while a Forget everything still has it to erase, and keeps the
    /// change for later if it can't be written now.
    private func saveIfNeeded() {
        guard unsaved, loaded, !forgetIsPending else { return }
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

    /// "One thing was waiting for you. Two tasks finished overnight." A
    /// count that couldn't be known is left out, never said as zero.
    public static func summaryBody(_ summary: MorningSummary, now: Date, calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        var lines: [String] = []
        if let count = summary.waiting { lines.append(waiting(count)) }
        if let count = summary.finished {
            lines.append(finished(count, since: summary.since, now: now, calendar: calendar, locale: locale))
        }
        if let count = summary.couldNotFinish, count > 0 { lines.append(couldNotFinish(count)) }
        if summary.countedNothing { lines.append(countedNothing) }
        if let hold = summary.late { lines.append(late(hold)) }
        return lines.joined(separator: " ")
    }

    /// The summary opened to read: the counts, where to find what waits,
    /// and from when it counted.
    public static func summaryDetail(_ summary: MorningSummary, now: Date, calendar: Calendar,
                                     locale: Locale) -> String {
        var lines: [String] = []
        if let count = summary.waiting {
            lines.append(waiting(count))
            if count > 0 { lines.append(whereWaiting) }
        }
        if let count = summary.finished {
            lines.append(finished(count, since: summary.since, now: now, calendar: calendar, locale: locale))
        }
        if let count = summary.couldNotFinish, count > 0 { lines.append(couldNotFinish(count)) }
        if summary.countedNothing { lines.append(countedNothing) }
        lines.append(countedSince(summary.since, now: now, calendar: calendar, locale: locale))
        if let hold = summary.late { lines.append(late(hold)) }
        return lines.joined(separator: "\n\n")
    }

    /// When nothing could be counted: the app wasn't running for the whole
    /// time, and what it would count lives only while it runs.
    public static let countedNothing = "The app was closed for part of this time, so I couldn't count what happened."

    static func waiting(_ count: Int) -> String {
        switch count {
        case 0: "Nothing was waiting for you."
        case 1: "One thing was waiting for you."
        default: "\(count) things were waiting for you."
        }
    }

    /// "overnight" only when it counted from yesterday afternoon or later.
    /// Longer, it names from when: "since yesterday", "since Tuesday".
    static func finished(_ count: Int, since: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let span = period(since: since, now: now, calendar: calendar, locale: locale)
        return switch count {
        case 0: "Nothing finished \(span)."
        case 1: "One task finished \(span)."
        default: "\(count) tasks finished \(span)."
        }
    }

    static func period(since: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return "overnight" }
        let afternoon = calendar.date(byAdding: .hour, value: 12, to: yesterday) ?? yesterday
        if since >= today { return "since \(clock(since, calendar: calendar, locale: locale))" }
        if since >= afternoon { return "overnight" }
        if since >= yesterday { return "since yesterday" }
        return "since \(weekday(since, calendar: calendar, locale: locale))"
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

    /// "I couldn't make Thursday's summary". A format string, so a
    /// translation can place the day where its language puts it.
    public static func missedTitle(_ due: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = weekday(due, calendar: calendar, locale: locale)
        return String(localized: "I couldn't make \(day)'s summary", locale: locale,
                      comment: "A card title. The argument is a weekday, such as Thursday.")
    }

    /// "I couldn't make the summaries from Thursday to Saturday", or for
    /// a week or more, "I couldn't make the last 9 summaries", since day
    /// names would repeat.
    public static func missedTitle(from first: Date, through last: Date, calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                            to: calendar.startOfDay(for: last)).day ?? 0) + 1
        guard days < 7 else {
            return String(localized: "I couldn't make the last \(days) summaries", locale: locale,
                          comment: "A card title. The argument is how many mornings were missed, 7 or more.")
        }
        let from = weekday(first, calendar: calendar, locale: locale)
        let to = weekday(last, calendar: calendar, locale: locale)
        return String(localized: "I couldn't make the summaries from \(from) to \(to)", locale: locale,
                      comment: "A card title. The arguments are the first and last weekday missed.")
    }

    /// Why several days went by: only the first day's reason is known, so
    /// it says what is true of them all.
    public static let missedSeveral = "I didn't get a chance to make them while the app was closed."

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
    /// What the switch does, true for where it runs. On iPhone and iPad the
    /// summary can be made overnight only once the device has been unlocked
    /// since it last started, so the line says that, and names the catch up
    /// when the app opens that covers every other night.
    ///
    /// It names what finished only when `countsTasks`: the runner has tasks
    /// to count. Without them no summary could ever say it, so the line
    /// the person reads as they turn it on doesn't promise it. A quiet
    /// morning leaves no card, so it says "when there's something".
    public static func settingDetail(whileClosed: Bool, countsTasks: Bool) -> String {
        let what = countsTasks
            ? "When there's something to tell you in the morning, I'll put a short summary in Today of what's waiting for you and what finished overnight."
            : "When there's something to tell you in the morning, I'll put a short summary in Today of what's waiting for you."
        let when = whileClosed
            ? "I make it overnight if you've unlocked since your last restart, and otherwise when you open the app."
            : "I make it while the app is open, even with no window showing, or as soon as you come back."
        return [what, when, askFirst].joined(separator: " ")
    }

    static let askFirst = "I never send, buy or share anything without asking you first."

    /// Under the switch while it is on: "I'll look next at 7:00 AM tomorrow."
    /// It says when it looks, not that a card comes: a quiet morning leaves none.
    public static func nextDue(_ due: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = clock(due, calendar: calendar, locale: locale)
        if due <= now { return "I'll look as soon as I can." }
        if calendar.isDate(due, inSameDayAs: now) { return "I'll look next at \(time) today." }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
            return "I'll look next at \(time) tomorrow."
        }
        return "I'll look next on \(weekday(due, calendar: calendar, locale: locale)) at \(time)."
    }
}
