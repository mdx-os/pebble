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
        /// See `TaskStep.undone`.
        public let undone: String?

        public init(text: String, mark: TaskStep.Mark, at: Date, undone: String? = nil) {
            self.text = text
            self.mark = mark
            self.at = at
            self.undone = undone
        }
    }

    public let id: String
    public let title: String
    /// Which step it had got to, from zero.
    public let step: Int
    public let phase: Phase
    public let askedAt: Date?
    public let approvedAt: Date?
    /// What the person said yes to, as the question showed it, kept only
    /// while the phase is `.approved`. Its receipt is made from this and
    /// nothing else, so a script changed by an update never puts words in
    /// a receipt that the person never saw.
    public let approvedAction: SavedAction?
    public let kept: [String]
    public let notDone: [String]
    public let history: [Step]
    public let startedAt: Date

    public init(id: String, title: String, step: Int, phase: Phase, askedAt: Date? = nil, approvedAt: Date? = nil,
                approvedAction: SavedAction? = nil,
                kept: [String] = [], notDone: [String] = [], history: [Step] = [], startedAt: Date) {
        self.id = id
        self.title = title
        self.step = step
        self.phase = phase
        self.askedAt = askedAt
        self.approvedAt = approvedAt
        self.approvedAction = approvedAction
        self.kept = kept
        self.notDone = notDone
        self.history = history
        self.startedAt = startedAt
    }
}

/// A `ProposedAction` as it is kept on disk.
public struct SavedAction: Codable, Sendable, Equatable {
    public let kind: ConsequentialAction
    public let recipientID: String
    public let recipientName: String
    public let handle: String?
    public let details: String
    public let priceMinorUnits: Int?
    public let priceCurrency: String?
    public let outcome: String?

    public init(_ action: ProposedAction) {
        kind = action.kind
        recipientID = action.recipient.id
        recipientName = action.recipient.displayName
        handle = action.recipient.handle
        details = action.details
        priceMinorUnits = action.price?.minorUnits
        priceCurrency = action.price?.currency
        outcome = action.outcome
    }

    /// The action, or nil when the file was changed into something no
    /// question could have shown: no exact handle, a name the question would
    /// have tidied, hidden characters, an empty or hidden recipient id, or
    /// a purchase with no price.
    public var action: ProposedAction? {
        let price = priceMinorUnits.flatMap { minor in priceCurrency.flatMap { Price(minorUnits: minor, currency: $0) } }
        let action = ProposedAction(kind: kind, recipient: Recipient(id: recipientID, displayName: recipientName, handle: handle),
                                    details: details, price: price, outcome: outcome)
        guard action.recipient.handle != nil, action.recipient.handle == handle,
              !recipientID.isEmpty, !AskFirst.hasHiddenScalars(recipientID),
              action.recipient.displayName == recipientName,
              !AskFirst.hasHiddenScalars(details), !(outcome.map(AskFirst.hasHiddenScalars) ?? false),
              (priceMinorUnits == nil) == (price == nil),
              action.kind != .purchase || price != nil else { return nil }
        return action
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
    /// Forget everything: every nudge, as `removeAll`, and a nudge opened
    /// but not yet handed over, so no task from before reaches a listener.
    func forget()
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
///
/// Forget everything deletes the file first, read or not. If it can't be
/// deleted, a small marker in a folder of its own says a forget is still
/// owed, so even a store opened after the app was killed never reads the
/// file again and deletes it as soon as it can. A file that couldn't be
/// read when it was forgotten takes its nudge choice with it, so the offer
/// may come once more, still only when a question waits. Clearing the last
/// thing it holds is the same: a file that won't go is owed a forget.
///
/// A write that fails leaves the store dirty, and each read and change
/// tries it again, so a receipt cleared here never comes back from the
/// file.
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
    /// The file Forget everything deletes: `fileURL`, or for a store that
    /// couldn't open its folder, where the file would be.
    private let knownURL: URL?
    /// Says a forget is owed. In a folder apart from the file, so a folder
    /// that won't let the file go can't keep this from being written.
    private let markerURL: URL?
    private let lock = NSLock()
    private var state = State()
    /// False while a file is there but can't be read yet, or must still be
    /// deleted, so nothing is written over it. Each read and change tries
    /// again.
    private var loaded: Bool
    /// What changed in memory while the file couldn't be read. A late read
    /// never takes these back.
    private var changedTasks = false
    private var changedNudges = false
    /// Forget everything ran and the file couldn't be deleted. It is never
    /// read; each read and change tries to delete it again.
    private var mustDelete = false
    /// What is in memory couldn't be written. Each read and change tries
    /// again, so the file never keeps what was taken away here.
    private var dirty = false
    /// Tasks a late read found that no engine has picked up yet. They stay
    /// in the file until one has, so a `keep` made before the read never
    /// drops them.
    private var arrivedLate: [SavedTask] = []
    /// A late read brought something in, so watchers hear of it.
    private var tellWatchers = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// `forgetMarker` is where a forget still owed is written down. Nil
    /// keeps it in memory only. Never left out: a test that forgot it would
    /// share a marker with every other.
    package init(fileURL: URL?, forgetMarker: URL?) {
        self.fileURL = fileURL
        knownURL = fileURL
        markerURL = forgetMarker
        loaded = fileURL == nil
        lock.lock()
        if let forgetMarker, FileManager.default.fileExists(atPath: forgetMarker.path) { mustDelete = true }
        loadIfNeeded()
        // Whatever was read now is picked up by `restore`, so none of it
        // arrived late.
        arrivedLate = []
        tellWatchers = false
        lock.unlock()
    }

    /// Kept in memory only, but Forget everything still deletes the file
    /// at `forgets`, left by an earlier launch. A forget an earlier launch
    /// still owed is carried out now.
    package init(forgetOnly forgets: URL, forgetMarker: URL?) {
        fileURL = nil
        knownURL = forgets
        markerURL = forgetMarker
        loaded = true
        lock.lock()
        if let forgetMarker, FileManager.default.fileExists(atPath: forgetMarker.path) {
            mustDelete = true
            deleteIfOwed()
        }
        lock.unlock()
    }

    /// Kept in memory only.
    public static func inMemory(_ state: State = State()) -> TaskStore {
        let store = TaskStore(fileURL: nil, forgetMarker: nil)
        store.lock.lock()
        store.state = state
        store.lock.unlock()
        return store
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: TaskStore?

    /// Where the store on this device keeps its file, and where a forget
    /// still owed is written down, under `app`'s own folder. The marker has
    /// a folder of its own.
    package static func location(base: URL, app: String) -> (file: URL, marker: URL) {
        let root = base.appendingPathComponent(app, isDirectory: true)
        return (root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent("tasks.json"),
                root.appendingPathComponent("pending", isDirectory: true).appendingPathComponent("tasks-forgotten"))
    }

    /// The app's folder in Application Support: its bundle identifier, as
    /// the system names its other folders, so no name is written here.
    package static func appFolder(_ bundle: Bundle = .main) -> String {
        bundle.bundleIdentifier ?? "kept-tasks"
    }

    /// The one store on this device.
    public static func onDevice(fileManager: FileManager = .default) throws -> TaskStore {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return shared }
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let (file, marker) = location(base: base, app: appFolder())
        var folder = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try MemoryStore.excludeFromBackup(&folder)
        let store = TaskStore(fileURL: file, forgetMarker: marker)
        shared = store
        return store
    }

    /// For when `onDevice` couldn't open its folder: keeps everything in
    /// memory, and Forget everything still deletes a file an earlier launch
    /// left there.
    public static func forgetOnly(fileManager: FileManager = .default) -> TaskStore {
        guard let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: false) else { return inMemory() }
        let (file, marker) = location(base: base, app: appFolder())
        return TaskStore(forgetOnly: file, forgetMarker: marker)
    }

    public var tasks: [SavedTask] { read(\.tasks) }
    /// Newest first.
    public var receipts: [Receipt] { read(\.receipts).sorted { ($0.endedAt, $0.id.uuidString) > ($1.endedAt, $1.id.uuidString) } }
    public var nudges: NudgeChoice { read(\.nudges) }

    // MARK: Changes

    /// Saves where the engine's tasks have got to, and keeps the receipts it
    /// has made since the last time. Written only when something changed.
    ///
    /// Tasks a late read found are handed to the engine first, as `restore`
    /// would have at launch, so an approved step under way gets its "may be
    /// done" card and receipt rather than being dropped. Any that arrive
    /// while this runs are kept in the file for the next time.
    public func keep(_ engine: any KeepsTasks, now: Date = Date()) {
        let late = takeArrivedLate()
        if !late.isEmpty { engine.restore(late, now: now) }
        let saved = engine.saved()
        let made = engine.takeReceipts()
        change { state in
            state.tasks = saved + self.arrivedLate.filter { task in !saved.contains { $0.id == task.id } }
            for receipt in made where !state.receipts.contains(where: { $0.id == receipt.id }) {
                state.receipts.append(receipt)
            }
            state.receipts = Self.newest(state.receipts)
        }
    }

    /// Picks up the tasks saved before the app closed, then saves again, so
    /// a question that timed out meanwhile is never picked up twice.
    ///
    /// A waiting question is asked again with the deadline its saved
    /// `askedAt` gives it, but with the action today's script has at that
    /// step. If an update changed the step, the new question inherits the
    /// old one's time left. It still needs a fresh yes, so nothing is
    /// approved by it; it may only have less time than a new question.
    public func restore(into engine: any KeepsTasks, now: Date) {
        let saved = tasks
        if !saved.isEmpty { engine.restore(saved, now: now) }
        keep(engine, now: now)
    }

    /// True while a late read found tasks no engine has picked up. The
    /// next `keep` picks them up.
    public var hasLateTasks: Bool {
        lock.lock()
        loadIfNeeded()
        let late = !arrivedLate.isEmpty
        let hooks = takeHooks()
        lock.unlock()
        for hook in hooks { hook() }
        return late
    }

    private func takeArrivedLate() -> [SavedTask] {
        lock.lock()
        loadIfNeeded()
        let late = arrivedLate
        arrivedLate = []
        let hooks = takeHooks()
        lock.unlock()
        for hook in hooks { hook() }
        return late
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
    /// The file goes first, read or not, and only then is the nudge choice
    /// written again. A file that won't go is never read again, by this
    /// store or one opened on a later launch, and is deleted as soon as it
    /// can be.
    public func forget() {
        lock.lock()
        state.tasks = []
        state.receipts = []
        arrivedLate = []
        dirty = false
        if knownURL != nil {
            mustDelete = true
            writeMarker()
            deleteIfOwed()
        }
        let hooks = Array(observers.values)
        lock.unlock()
        for hook in hooks { hook() }
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
        loadIfNeeded()
        let value = state[keyPath: path]
        let hooks = takeHooks()
        lock.unlock()
        for hook in hooks { hook() }
        return value
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
            tellWatchers = true
        }
        let hooks = takeHooks()
        lock.unlock()
        for hook in hooks { hook() }
    }

    /// The watchers to call once the lock is let go, when something they
    /// would see has changed. Called with the lock held.
    private func takeHooks() -> [@Sendable () -> Void] {
        guard tellWatchers else { return [] }
        tellWatchers = false
        return Array(observers.values)
    }

    /// Reads the file once it can, and writes again what couldn't be
    /// written before. A file that can't be read yet is left alone and
    /// tried again. One that is read but can't be understood, as from a
    /// later version or a broken write, is deleted: nothing could ever read
    /// it back, and the person couldn't see or clear what it held. A file
    /// owed a forget is never read, only deleted.
    ///
    /// A file read late, as when it was locked until the device was first
    /// unlocked, never takes back what changed in memory since launch: the
    /// tasks and the nudge choice made here stand, and the receipts from
    /// both are kept. Its tasks that aren't here are kept too, as arrived
    /// late, until an engine picks them up. Then the whole is written back.
    private func loadIfNeeded() {
        if mustDelete { deleteIfOwed() }
        if loaded, dirty { save(state) }
        guard !loaded, !mustDelete, let fileURL else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let saved = try? JSONDecoder().decode(State.self, from: data) else {
            // Gone as Forget everything would take it, so a file that won't
            // go is still never read and goes as soon as it can.
            mustDelete = true
            writeMarker()
            deleteIfOwed()
            return
        }
        loaded = true
        let here = changedTasks ? state.tasks : []
        let late = saved.tasks.filter { task in !here.contains { $0.id == task.id } }
        var merged = saved
        merged.tasks = here + late
        if changedNudges { merged.nudges = state.nudges }
        for receipt in state.receipts where !merged.receipts.contains(where: { $0.id == receipt.id }) {
            merged.receipts.append(receipt)
        }
        merged.receipts = Self.newest(merged.receipts)
        if merged != state { tellWatchers = true }
        arrivedLate = late
        state = merged
        changedTasks = false
        changedNudges = false
        if merged != saved { save(merged) }
    }

    /// Deletes the file and its half written next one. Once both are gone,
    /// so is the marker, and what is in memory is written from here on.
    /// Until then nothing is read or written.
    private func deleteIfOwed() {
        guard mustDelete, let knownURL else { return }
        let manager = FileManager.default
        let leftovers = Self.leftovers(of: knownURL)
        for url in leftovers { try? manager.removeItem(at: url) }
        guard !leftovers.contains(where: { manager.fileExists(atPath: $0.path) }) else {
            if fileURL != nil { loaded = false }
            return
        }
        mustDelete = false
        if let markerURL { try? manager.removeItem(at: markerURL) }
        changedTasks = false
        changedNudges = false
        if fileURL != nil {
            loaded = true
            if state != State() { save(state) }
        }
    }

    /// Written before anything is deleted, so a forget cut short by the app
    /// being killed is still owed on the next launch. It holds nothing, and
    /// has no file protection so it can be written while the device is
    /// locked.
    private func writeMarker() {
        guard let markerURL else { return }
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(macOS)
        let options: Data.WritingOptions = []
        #else
        let options: Data.WritingOptions = [.noFileProtection]
        #endif
        try? Data().write(to: markerURL, options: options)
    }

    /// Every file a store at `url` may leave.
    private static func leftovers(of url: URL) -> [URL] {
        [url, sibling(of: url, ".next")]
    }

    private static func sibling(of url: URL, _ suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + suffix)
    }

    /// At most `receiptLimit`, the oldest going first.
    private static func newest(_ receipts: [Receipt]) -> [Receipt] {
        guard receipts.count > receiptLimit else { return receipts }
        return Array(receipts.sorted { $0.endedAt < $1.endedAt }.suffix(receiptLimit))
    }

    private var stagingURL: URL? {
        fileURL.map { Self.sibling(of: $0, ".next") }
    }

    /// Writes `next` whole. One that can't be written leaves the store
    /// dirty, to be tried again at the next read or change.
    private func save(_ next: State) {
        guard let fileURL, let stagingURL else { return }
        let manager = FileManager.default
        dirty = false
        // Nothing left to keep, so no file at all. One that won't go is owed
        // a forget, written down, so what was cleared never comes back from
        // it, on this launch or the next.
        if next == State() {
            try? manager.removeItem(at: fileURL)
            try? manager.removeItem(at: stagingURL)
            if Self.leftovers(of: fileURL).contains(where: { manager.fileExists(atPath: $0.path) }) {
                mustDelete = true
                writeMarker()
                loaded = false
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(next) else {
            dirty = true
            return
        }
        try? manager.removeItem(at: stagingURL)
        #if os(macOS)
        let options: Data.WritingOptions = [.withoutOverwriting]
        #else
        let options: Data.WritingOptions = [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
        guard (try? data.write(to: stagingURL, options: options)) != nil,
              rename(stagingURL.path, fileURL.path) == 0 else {
            try? manager.removeItem(at: stagingURL)
            dirty = true
            return
        }
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
    /// Said after Yes, nudge me, once the system allows it, as the offer goes.
    public static let on = "Okay, I'll nudge you when I have a question."
    public static let offerTitle = "Want a nudge when I have a question?"
    public static let offerDetail = "I'll nudge you only when I need your yes. Your lock screen will just say I have a question, never what it is."
    public static let allowTitle = "Yes, nudge me"
    public static let declineTitle = "No thanks"
    /// After No thanks, or when the system said no.
    public static let off = "Okay, no nudges. Your questions will wait for you here."
}
