import Foundation

/// A task still going, as `TaskStore` keeps it while the app is closed.
/// Never a yes: a question comes back only by being asked again.
public struct SavedTask: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// Working on a step, or about to ask. Picked up at that step.
        case working
        /// Stuck after its retries ran out, waiting for Try again.
        case stuck
        /// Waiting on a yes for the step's question, first asked at `askedAt`.
        case waiting
        /// The person said yes at `approvedAt` and the step was under way.
        /// It is never run again.
        case approved
    }

    public struct Step: Codable, Sendable, Equatable {
        public let text: String
        public let mark: TaskStep.Mark
        public let at: Date

        public init(text: String, mark: TaskStep.Mark, at: Date) {
            self.text = text
            self.mark = mark
            self.at = at
        }
    }

    public let id: String
    public let title: String
    /// Which step it had got to, from zero.
    public let step: Int
    public let phase: Phase
    public let askedAt: Date?
    public let approvedAt: Date?
    public let kept: [String]
    public let notDone: [String]
    public let history: [Step]
    public let startedAt: Date

    public init(id: String, title: String, step: Int, phase: Phase, askedAt: Date? = nil, approvedAt: Date? = nil,
                kept: [String] = [], notDone: [String] = [], history: [Step] = [], startedAt: Date) {
        self.id = id
        self.title = title
        self.step = step
        self.phase = phase
        self.askedAt = askedAt
        self.approvedAt = approvedAt
        self.kept = kept
        self.notDone = notDone
        self.history = history
        self.startedAt = startedAt
    }
}

/// What the person said yes to, and what came of it. Kept until the person
/// clears it or forgets everything.
public struct Receipt: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// The step finished.
        case done
        /// The step was under way when the task stopped or the app closed.
        case mayBeDone
    }

    public let id: UUID
    /// The task it was for, such as "Find a dentist near you open Saturdays".
    public let taskTitle: String
    public let kind: ConsequentialAction
    public let recipientName: String
    /// The exact address, number or site, as the question showed it.
    public let handle: String
    public let details: String
    public let outcomeLine: String?
    public let priceMinorUnits: Int?
    public let priceCurrency: String?
    public let approvedAt: Date
    public let endedAt: Date
    public let outcome: Outcome
    /// From a scripted example, so the card says so.
    public let isSample: Bool

    public init(id: UUID = UUID(), action: ProposedAction, taskTitle: String, approvedAt: Date, endedAt: Date,
                outcome: Outcome, isSample: Bool) {
        self.id = id
        self.taskTitle = taskTitle
        self.kind = action.kind
        self.recipientName = action.recipient.displayName
        self.handle = action.recipient.shownAs
        self.details = action.details
        self.outcomeLine = action.outcome
        self.priceMinorUnits = action.price?.minorUnits
        self.priceCurrency = action.price?.currency
        self.approvedAt = approvedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.isSample = isSample
    }

    public var price: Price? {
        guard let priceMinorUnits, let priceCurrency else { return nil }
        return Price(minorUnits: priceMinorUnits, currency: priceCurrency)
    }

    /// "Your details for Maple Dental".
    public var title: String { ReceiptWords.title(kind, recipientName) }

    /// What came of it.
    public var line: String { outcome == .done ? ReceiptWords.done : ReceiptWords.mayBeDone }
}

/// Whether the person wants a nudge when a question is waiting. Asked in
/// the moment, the first time a question waits, never at launch.
public enum NudgeChoice: String, Codable, Sendable {
    /// Not asked yet.
    case notAsked
    /// Said yes, and the system allowed it.
    case allowed
    /// Said no thanks.
    case declined
    /// Said yes, and the system said no, now or in Settings before.
    case denied
}

/// What the system says about notifications for this app.
public enum NudgePermission: Sendable, Equatable {
    case notDetermined, allowed, denied
}

/// One nudge for one waiting question. Its words name nothing the question
/// holds: only that the agent has a question, so a lock screen shows no
/// more than that.
public struct QuestionNudge: Sendable, Equatable {
    /// The question's id, so the nudge goes when the question closes.
    public let id: String
    /// The task to show when the nudge is opened.
    public let taskID: String
    public let title: String

    public init(question: ConfirmationRequest, taskID: String, agentName: String) {
        self.id = "question:\(question.id.uuidString)"
        self.taskID = taskID
        self.title = NudgeWords.question(agentName)
    }
}

/// Posts and takes away the nudges for waiting questions. Local only:
/// nothing here reaches the network.
public protocol QuestionNotifying: AnyObject, Sendable {
    /// What the system says now, without asking.
    func permission() async -> NudgePermission
    /// Asks the system, which shows its own question the first time. True
    /// when nudges are allowed.
    func requestPermission() async -> Bool
    /// Shows `nudge` once `delay` seconds have passed, unless it is taken
    /// away first.
    func post(_ nudge: QuestionNudge, after delay: TimeInterval)
    func remove(_ ids: [String])
    /// Takes away every nudge about a question, shown or still to come,
    /// this launch's and any left from before.
    func removeAll()
    /// Called with a task's id when the person opens its nudge. A nudge
    /// opened before anything listens is handed over once something does.
    func onOpen(_ handler: @escaping @MainActor @Sendable (String) -> Void)
}

/// Everything about waiting questions that outlives the app being closed:
/// the tasks still going, the receipts for what the person said yes to,
/// and whether they want a nudge.
///
/// Kept in one file inside Application Support, left out of backups, and
/// written whole each time. Forget everything removes the tasks and the
/// receipts and keeps only the nudge choice, which holds nothing of theirs.
public final class TaskStore: @unchecked Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var tasks: [SavedTask] = []
        public var receipts: [Receipt] = []
        public var nudges: NudgeChoice = .notAsked

        public init(tasks: [SavedTask] = [], receipts: [Receipt] = [], nudges: NudgeChoice = .notAsked) {
            self.tasks = tasks
            self.receipts = receipts
            self.nudges = nudges
        }
    }

    /// Receipts kept at most. Past this the oldest go.
    public static let receiptLimit = 30

    /// Nil keeps everything in memory only, for tests and screenshots.
    public let fileURL: URL?
    private let lock = NSLock()
    private var state = State()
    /// False while a file is there but can't be read, so nothing is written
    /// over it. Each change tries again.
    private var loaded: Bool
    /// What changed in memory while the file couldn't be read. A late read
    /// never takes these back.
    private var changedTasks = false
    private var changedNudges = false
    /// Forget everything ran while a file that couldn't be read also
    /// couldn't be removed. Whatever it held is dropped once it is read.
    private var forgotUnread = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    package init(fileURL: URL?) {
        self.fileURL = fileURL
        loaded = fileURL == nil
        lock.lock()
        loadIfNeeded()
        lock.unlock()
    }

    /// Kept in memory only.
    public static func inMemory(_ state: State = State()) -> TaskStore {
        let store = TaskStore(fileURL: nil)
        store.lock.lock()
        store.state = state
        store.lock.unlock()
        return store
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: TaskStore?

    /// The one store on this device, beside the notes.
    public static func onDevice(fileManager: FileManager = .default) throws -> TaskStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        var folder = base.appendingPathComponent("pebble", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try MemoryStore.excludeFromBackup(&folder)
        let store = TaskStore(fileURL: folder.appendingPathComponent("tasks.json"))
        shared = store
        return store
    }

    public var tasks: [SavedTask] { read(\.tasks) }
    /// Newest first.
    public var receipts: [Receipt] { read(\.receipts).sorted { ($0.endedAt, $0.id.uuidString) > ($1.endedAt, $1.id.uuidString) } }
    public var nudges: NudgeChoice { read(\.nudges) }

    // MARK: Changes

    /// Saves where the engine's tasks have got to, and keeps the receipts it
    /// has made since the last time. Written only when something changed.
    public func keep(_ engine: any KeepsTasks) {
        let saved = engine.saved()
        let made = engine.takeReceipts()
        change { state in
            state.tasks = saved
            for receipt in made where !state.receipts.contains(where: { $0.id == receipt.id }) {
                state.receipts.append(receipt)
            }
            state.receipts = Self.newest(state.receipts)
        }
    }

    /// Picks up the tasks saved before the app closed, then saves again, so
    /// a question that timed out meanwhile is never picked up twice.
    public func restore(into engine: any KeepsTasks, now: Date) {
        let saved = tasks
        if !saved.isEmpty { engine.restore(saved, now: now) }
        keep(engine)
    }

    /// Takes one receipt away. False when there was no such receipt.
    @discardableResult
    public func clearReceipt(_ id: UUID) -> Bool {
        var found = false
        change { state in
            let before = state.receipts.count
            state.receipts.removeAll { $0.id == id }
            found = state.receipts.count != before
        }
        return found
    }

    public func setNudges(_ choice: NudgeChoice) {
        change { $0.nudges = choice }
    }

    /// Forget everything: every saved task and every receipt. Only the nudge
    /// choice stays, since it holds nothing the person said or did.
    ///
    /// The file goes too, read or not: one that couldn't be read, or not
    /// yet, is never left behind to bring anything back later.
    public func forget() {
        lock.lock()
        if !loaded, let fileURL, let stagingURL {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: stagingURL)
            // Gone, so there is nothing left to read, and what is in memory
            // is written from here on.
            if !FileManager.default.fileExists(atPath: fileURL.path) { loaded = true } else { forgotUnread = true }
        }
        lock.unlock()
        change { state in
            state.tasks = []
            state.receipts = []
        }
    }

    /// Everything, the nudge choice too. For screenshots and tests.
    package func reset() {
        change { $0 = State() }
    }

    // MARK: Watching

    public struct Observation: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Calls `hook` after every change, never with the lock held.
    public func observe(_ hook: @escaping @Sendable () -> Void) -> Observation {
        let observation = Observation()
        lock.lock()
        observers[observation.id] = hook
        lock.unlock()
        return observation
    }

    public func stopObserving(_ observation: Observation) {
        lock.lock()
        observers[observation.id] = nil
        lock.unlock()
    }

    // MARK: Storage

    private func read<T>(_ path: KeyPath<State, T>) -> T {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return state[keyPath: path]
    }

    private func change(_ body: (inout State) -> Void) {
        lock.lock()
        loadIfNeeded()
        var next = state
        body(&next)
        let changed = next != state
        if changed {
            if !loaded {
                if next.tasks != state.tasks { changedTasks = true }
                if next.nudges != state.nudges { changedNudges = true }
            }
            state = next
            if loaded { save(next) }
        }
        let hooks = changed ? Array(observers.values) : []
        lock.unlock()
        for hook in hooks { hook() }
    }

    /// Reads the file once it can. A file that can't be read is left alone.
    ///
    /// A file read late, as when it was locked until the device was first
    /// unlocked, never takes back what changed in memory since launch: the
    /// tasks and the nudge choice made here stand, and the receipts from
    /// both are kept. Then the whole is written back.
    private func loadIfNeeded() {
        guard !loaded, let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(State.self, from: data) else { return }
        loaded = true
        var merged = saved
        if forgotUnread {
            merged.tasks = []
            merged.receipts = []
        }
        if changedTasks { merged.tasks = state.tasks }
        if changedNudges { merged.nudges = state.nudges }
        for receipt in state.receipts where !merged.receipts.contains(where: { $0.id == receipt.id }) {
            merged.receipts.append(receipt)
        }
        merged.receipts = Self.newest(merged.receipts)
        state = merged
        changedTasks = false
        changedNudges = false
        forgotUnread = false
        if merged != saved { save(merged) }
    }

    /// At most `receiptLimit`, the oldest going first.
    private static func newest(_ receipts: [Receipt]) -> [Receipt] {
        guard receipts.count > receiptLimit else { return receipts }
        return Array(receipts.sorted { $0.endedAt < $1.endedAt }.suffix(receiptLimit))
    }

    private var stagingURL: URL? {
        fileURL.map { $0.deletingLastPathComponent().appendingPathComponent("." + $0.lastPathComponent + ".next") }
    }

    private func save(_ next: State) {
        guard let fileURL, let stagingURL else { return }
        let manager = FileManager.default
        // Nothing left to keep, so no file at all.
        if next == State() {
            try? manager.removeItem(at: fileURL)
            try? manager.removeItem(at: stagingURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(next) else { return }
        try? manager.removeItem(at: stagingURL)
        #if os(macOS)
        let options: Data.WritingOptions = [.withoutOverwriting]
        #else
        let options: Data.WritingOptions = [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
        guard (try? data.write(to: stagingURL, options: options)) != nil else { return }
        if rename(stagingURL.path, fileURL.path) != 0 { try? manager.removeItem(at: stagingURL) }
    }
}

/// Receipts as cards in the Today feed, newest first, each with Clear.
public struct ReceiptFeed: FeedSource {
    public let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    public func items(now: Date) -> [FeedItem] {
        store.receipts.map(Self.item)
    }

    public static func item(_ receipt: Receipt) -> FeedItem {
        FeedItem(id: "receipt:\(receipt.id.uuidString)", kind: .receipt, time: receipt.endedAt,
                 title: receipt.title, body: receipt.line, action: .receipt(receipt))
    }
}

/// Words for receipts.
public enum ReceiptWords {
    /// The small label on the card.
    public static let label = "You said yes"
    public static func title(_ kind: ConsequentialAction, _ name: String) -> String {
        switch kind {
        case .send: "A message to \(name)"
        case .purchase: "A payment to \(name)"
        case .sharePersonalInfo: "Your details for \(name)"
        }
    }
    public static let done = "Done, once, just as you said yes to it."
    public static let mayBeDone = "I'd started this when I stopped, so it may be done."
    public static let clearHint = "Takes this away."
}

/// Words for nudges about waiting questions.
public enum NudgeWords {
    /// All a nudge says, on the lock screen and everywhere else.
    public static func question(_ name: String) -> String { "\(name) has a question for you" }
    public static let offerTitle = "Want a nudge when I have a question?"
    public static let offerDetail = "I'll nudge you only when I need your yes. Your lock screen will just say I have a question, never what it is."
    public static let allowTitle = "Yes, nudge me"
    public static let declineTitle = "No thanks"
    /// After No thanks, or when the system said no.
    public static let off = "Okay, no nudges. Your questions will wait for you here."
}
