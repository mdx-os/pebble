import Foundation

/// Evidence supplied by an engine for its result: a source, a local artifact,
/// or a check. Sources and checks are supplied claims, not trusted execution
/// records. Validation checks their shape and resolves local artifacts; it
/// does not establish that a page was read or a check ran.
public enum TaskProof: Codable, Sendable, Hashable {
    /// A supplied source, by its title and web address.
    case source(title: String, url: URL)
    /// Something made on this device, by its name, what kind of thing it
    /// is, and where it is kept here. The reference is resolved by the
    /// ledger's `TaskArtifactResolving`, never taken on the engine's word.
    case artifact(name: String, kind: Kind, reference: String)
    /// A supplied claim that a check passed, in plain words, such as
    /// "All three open on Saturdays". Not a record of execution.
    case check(String)

    /// What kind of thing an artifact is.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case note, list, document, plan, file
    }

    /// The words on its chip: a source's title, an artifact's name, or
    /// what the check found.
    public var title: String {
        switch self {
        case .source(let title, _): title
        case .artifact(let name, _, _): name
        case .check(let words): words
        }
    }

    /// What VoiceOver says for its chip, such as "Source: Maple Dental hours".
    public var spoken: String {
        switch self {
        case .source(let title, _): LedgerWords.spokenSource(title)
        case .artifact(let name, _, _): LedgerWords.spokenMade(name)
        case .check(let words): LedgerWords.spokenCheck(words)
        }
    }

    /// Supplied evidence with a valid shape, in order, each once. A source
    /// needs a title and an http or https address with a host. An artifact
    /// needs a name and a reference `artifacts` resolves on this device.
    /// A check needs words. Sources and checks are not verified against
    /// trusted execution records. Anything else is dropped.
    public static func checked(_ proofs: [TaskProof], artifacts: any TaskArtifactResolving) -> [TaskProof] {
        var seen = Set<TaskProof>()
        return proofs.filter { proof in
            guard proof.isValid(artifacts: artifacts), !seen.contains(proof) else { return false }
            seen.insert(proof)
            return true
        }
    }

    func isValid(artifacts: any TaskArtifactResolving) -> Bool {
        guard Self.readable(title) else { return false }
        switch self {
        case .source(_, let url):
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            return !(url.host() ?? "").isEmpty
        case .artifact(_, _, let reference):
            return !reference.isEmpty && artifacts.resolves(reference)
        case .check:
            return true
        }
    }

    /// Words a person could read on a chip: not empty, and with no hidden
    /// or reordering characters.
    static func readable(_ words: String) -> Bool {
        !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !AskFirst.hasHiddenScalars(words)
    }
}

/// Tells whether an artifact's reference points at something kept on this
/// device. The ledger asks this, so an engine can't vouch for itself.
public protocol TaskArtifactResolving: Sendable {
    func resolves(_ reference: String) -> Bool
}

/// Resolves nothing, so every artifact is dropped. For a ledger with
/// nowhere things are made.
public struct NoArtifacts: TaskArtifactResolving {
    public init() {}
    public func resolves(_ reference: String) -> Bool { false }
}

/// Resolves the references it was given, for tests and the showcase.
public struct KnownArtifacts: TaskArtifactResolving {
    public let references: Set<String>

    public init(_ references: Set<String>) {
        self.references = references
    }

    public func resolves(_ reference: String) -> Bool { references.contains(reference) }
}

/// Resolves a reference that names a file inside `root` that is there now.
/// A reference that climbs out of `root`, or starts at the top of the
/// disk, resolves nothing. Symbolic links must resolve inside `root` too.
public struct FolderArtifacts: TaskArtifactResolving {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func resolves(_ reference: String) -> Bool {
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard !reference.hasPrefix("/"), !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let file = parts.reduce(root) { $0.appendingPathComponent(String($1)) }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolvedFile.count > resolvedRoot.count,
              resolvedFile.starts(with: resolvedRoot) else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &folder) && !folder.boolValue
    }
}

/// One line in a task's ledger, at a time from the ledger's clock.
public struct TaskLedgerEntry: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        /// Asked for, not started yet.
        case queued
        /// On a step, in the words the card shows.
        case working(step: String)
        /// Waiting on the person's answer to a question.
        case needsYou(question: UUID)
        /// The question was answered: yes, or anything but a yes.
        case answered(yes: Bool)
        /// Nothing new for a while, so `QuietWatch` says it is still on its
        /// last step.
        case stillWorking(step: String)
        /// Can't move on: why, and what happens next.
        case stuck(reason: String, next: String)
        /// Finished, with what shows it. Never empty.
        case done(proofs: [TaskProof])
        /// Finished, with nothing that showed it.
        case finishedUnchecked
        case failed(reason: String)
        case stopped(why: String)

        /// Done, finished unchecked, failed or stopped. A ledger has one,
        /// last, and nothing after it.
        public var isEnd: Bool {
            switch self {
            case .done, .finishedUnchecked, .failed, .stopped: true
            default: false
            }
        }

    }

    public let kind: Kind
    public let at: Date
    /// Written by `QuietWatch`, not from what an engine reported.
    public let watched: Bool

    public init(_ kind: Kind, at: Date, watched: Bool = false) {
        self.kind = kind
        self.at = at
        self.watched = watched
    }
}

/// Everything one task did, in order, kept on this device. Append only:
/// a line once written stays, and nothing is written after its end.
public struct TaskLedger: Codable, Sendable, Equatable, Identifiable {
    /// The task's id with when it started, since an engine may give a new
    /// task an id an old one had.
    public struct Key: Codable, Sendable, Hashable {
        public let task: String
        public let startedAt: Date

        public init(task: String, startedAt: Date) {
            self.task = task
            self.startedAt = startedAt
        }
    }

    public let key: Key
    public private(set) var entries: [TaskLedgerEntry]

    public var id: Key { key }
    public var taskID: String { key.task }

    public init(key: Key) {
        self.key = key
        entries = []
    }

    /// The end, once there is one.
    public var end: TaskLedgerEntry? {
        entries.last.flatMap { $0.kind.isEnd ? $0 : nil }
    }

    public var isEnded: Bool { end != nil }

    /// The last step the task was on, in its own words.
    public var lastStep: String? {
        for entry in entries.reversed() {
            switch entry.kind {
            case .working(let step), .stillWorking(let step): return step
            default: continue
            }
        }
        return nil
    }

    /// Writes one line. Nothing is written after the end, and false says
    /// so. A done is checked first: evidence with an invalid shape or an
    /// unresolved artifact is dropped. A done left with none is written as
    /// finished unchecked instead.
    @discardableResult
    public mutating func append(_ kind: TaskLedgerEntry.Kind, at: Date, watched: Bool = false,
                                artifacts: any TaskArtifactResolving) -> Bool {
        guard !isEnded else { return false }
        var kind = kind
        if case .done(let proofs) = kind {
            let kept = TaskProof.checked(proofs, artifacts: artifacts)
            kind = kept.isEmpty ? .finishedUnchecked : .done(proofs: kept)
        }
        entries.append(TaskLedgerEntry(kind, at: at, watched: watched))
        return true
    }

    /// The same lines written again, one by one, as `append` would, so a
    /// file changed by hand can't put a line after an end or a done without
    /// accepted supplied evidence. Source addresses and check text are
    /// checked for shape; they are not authenticated execution records.
    public func replayed(artifacts: any TaskArtifactResolving) -> TaskLedger {
        var ledger = TaskLedger(key: key)
        for entry in entries { ledger.append(entry.kind, at: entry.at, watched: entry.watched, artifacts: artifacts) }
        return ledger
    }

    /// How the card shows the end, once there is one: what shows it, or
    /// that it couldn't be checked. Nil for any other end.
    public var finish: TaskFinish? {
        switch end?.kind {
        case .done(let proofs): .proven(proofs)
        case .finishedUnchecked: .unchecked
        default: nil
        }
    }

    /// The line `QuietWatch` wrote last, while it is still the newest.
    public var quietLine: String? {
        guard let last = entries.last, last.watched else { return nil }
        switch last.kind {
        case .stillWorking(let step): return LedgerWords.stillOnIt(step)
        case .stuck(let reason, let next): return "\(reason) \(next)"
        default: return nil
        }
    }
}

/// How a finished task's card shows it was finished.
public enum TaskFinish: Sendable, Equatable {
    /// With what shows it, each as a chip.
    case proven([TaskProof])
    /// With nothing that showed it, so the card says so.
    case unchecked

    /// The visible and spoken status on a completed card.
    public var label: String { self == .unchecked ? LedgerWords.finishedLabel : TaskState.done.label }

    /// "Finished, but I couldn't check the result." Nil when proven.
    public var line: String? {
        self == .unchecked ? LedgerWords.unchecked : nil
    }
}

/// Watches for a task that has gone quiet, so none ever just sits there.
/// Pure: it is handed the time, and runs no timer of its own.
///
/// A task still working with nothing new for `period` gets a line naming
/// its last step. After `periodsBeforeStuck` quiet periods in a row it is
/// stuck instead, with why and what happens next, and its card offers Stop.
/// A task waiting on the person, already stuck, or ended is left alone.
public enum QuietWatch {
    public static let period: TimeInterval = 10 * 60
    public static let periodsBeforeStuck = 3

    /// The line to write now, or nil when there is nothing to say.
    public static func next(for ledger: TaskLedger, now: Date) -> TaskLedgerEntry.Kind? {
        guard let last = ledger.entries.last else { return nil }
        switch last.kind {
        case .queued, .working, .answered, .stillWorking: break
        case .needsYou, .stuck, .done, .finishedUnchecked, .failed, .stopped: return nil
        }
        // Quiet since the last line that wasn't this watch's own.
        let stills = ledger.entries.reversed().prefix(while: \.watched).count
        let since = ledger.entries[ledger.entries.count - 1 - stills].at
        let periods = Int(now.timeIntervalSince(since) / period)
        if periods >= periodsBeforeStuck {
            return .stuck(reason: LedgerWords.quietReason, next: LedgerWords.quietNext)
        }
        guard periods > stills else { return nil }
        return .stillWorking(step: ledger.lastStep ?? LedgerWords.gettingStarted)
    }
}

/// Where task ledgers are kept. Reading may not be possible yet, as before
/// the device is first unlocked, and then nothing is written either.
public protocol TaskLedgerStoring: AnyObject, Sendable {
    /// Every ledger kept, or nil while they can't be read yet.
    func read() -> [TaskLedger]?
    /// Keeps these, whole. False when they couldn't be written now.
    @discardableResult
    func write(_ ledgers: [TaskLedger]) -> Bool
    /// Erases every ledger, read or not. False while some of it stays, to
    /// be erased again before anything is read or written.
    @discardableResult
    func erase() -> Bool
}

/// Kept in memory only, for tests and the showcase. `locked` stands for a
/// device not yet unlocked: nothing can be read or written.
public final class InMemoryTaskLedgerStore: TaskLedgerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [TaskLedger]
    private var isLocked: Bool
    private var writeCount = 0

    public init(_ kept: [TaskLedger] = [], locked: Bool = false) {
        self.kept = kept
        isLocked = locked
    }

    public var locked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isLocked }
        set { lock.lock(); isLocked = newValue; lock.unlock() }
    }

    /// What is kept now, whatever the lock says. For tests.
    public var ledgers: [TaskLedger] { lock.lock(); defer { lock.unlock() }; return kept }

    /// Writes that went in. For tests.
    public var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    public func read() -> [TaskLedger]? {
        lock.lock(); defer { lock.unlock() }
        return isLocked ? nil : kept
    }

    public func write(_ ledgers: [TaskLedger]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isLocked else { return false }
        kept = ledgers
        writeCount += 1
        return true
    }

    public func erase() -> Bool {
        lock.lock(); defer { lock.unlock() }
        kept = []
        return true
    }
}

/// The ledgers in one file beside the kept tasks, written the way
/// `TaskStore` writes its file: whole, through a staged copy, and protected
/// until the device is first unlocked. A file that is there but can't be
/// read yet is never written over.
///
/// Erasing deletes the file first, read or not. If it won't go, an empty
/// marker beside `TaskStore`'s says an erase is still owed, so even a later
/// launch never reads it and deletes it as soon as it can.
public final class TaskLedgerFileStore: TaskLedgerStoring, @unchecked Sendable {
    public let fileURL: URL
    private let markerURL: URL
    private let lock = NSLock()
    /// An erase is owed even if its durable marker could not be written.
    private var pendingErase = false

    package init(fileURL: URL, forgetMarker: URL) {
        self.fileURL = fileURL
        markerURL = forgetMarker
    }

    /// Where the ledgers are kept beside the tasks, under `base`, and where
    /// an erase still owed is written down.
    package static func location(base: URL, app: String = TaskStore.appFolder) -> (file: URL, marker: URL) {
        let (tasks, marker) = TaskStore.location(base: base, app: app)
        return (tasks.deletingLastPathComponent().appendingPathComponent("ledger.json"),
                marker.deletingLastPathComponent().appendingPathComponent("ledger-forgotten"))
    }

    /// The store on this device, in the kept tasks' folder, which is left
    /// out of backups.
    public static func onDevice(fileManager: FileManager = .default) throws -> TaskLedgerFileStore {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let (file, marker) = location(base: base)
        var folder = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try MemoryStore.excludeFromBackup(&folder)
        var pending = marker.deletingLastPathComponent()
        try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)
        try MemoryStore.excludeFromBackup(&pending)
        return TaskLedgerFileStore(fileURL: file, forgetMarker: marker)
    }

    /// How the file is written: as the kept tasks are, so it can't be read
    /// until the device is first unlocked. It names supplied sources and
    /// artifacts for the person.
    package static func fileWriting(protected: Bool = TaskStore.protectsFiles) -> Data.WritingOptions {
        TaskStore.fileWriting(protected: protected)
    }

    /// How the marker is written: empty, and written while the device may
    /// still be locked.
    package static func markerWriting(protected: Bool = TaskStore.protectsFiles) -> Data.WritingOptions {
        TaskStore.markerWriting(protected: protected)
    }

    private var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    public func read() -> [TaskLedger]? {
        lock.lock(); defer { lock.unlock() }
        guard eraseIfOwed() else { return nil }
        if Self.isMissing(fileURL) { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let ledgers = try? JSONDecoder().decode([TaskLedger].self, from: data) else {
            // Nothing could ever read it back, so it goes as an erase would.
            return erased() ? [] : nil
        }
        return ledgers
    }

    public func write(_ ledgers: [TaskLedger]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard eraseIfOwed() else { return false }
        let manager = FileManager.default
        // A file there that can't be read yet is never written over.
        if manager.fileExists(atPath: fileURL.path), !manager.isReadableFile(atPath: fileURL.path) { return false }
        if ledgers.isEmpty {
            try? manager.removeItem(at: fileURL)
            try? manager.removeItem(at: stagingURL)
            return [fileURL, stagingURL].allSatisfy(Self.isMissing)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ledgers) else { return false }
        try? manager.removeItem(at: stagingURL)
        guard (try? data.write(to: stagingURL, options: Self.fileWriting())) != nil,
              rename(stagingURL.path, fileURL.path) == 0 else {
            try? manager.removeItem(at: stagingURL)
            return false
        }
        return true
    }

    public func erase() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return erased()
    }

    /// Owes an erase before trying any disk operation. Called with the lock held.
    private func erased() -> Bool {
        pendingErase = true
        return eraseIfOwed()
    }

    /// True once the data and marker are confirmed gone. Marker failure must
    /// never skip deletion or permit reads of data still owed an erase.
    private func eraseIfOwed() -> Bool {
        let manager = FileManager.default
        guard pendingErase || manager.fileExists(atPath: markerURL.path) else { return true }
        pendingErase = true
        try? manager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: markerURL, options: Self.markerWriting())
        for url in [fileURL, stagingURL] { try? manager.removeItem(at: url) }
        guard [fileURL, stagingURL].allSatisfy(Self.isMissing) else { return false }
        try? manager.removeItem(at: markerURL)
        guard Self.isMissing(markerURL) else { return false }
        pendingErase = false
        return true
    }

    /// A permission error is not proof of absence. lstat also sees dangling
    /// links, which fileExists would mistake for a missing file.
    private static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }
}

/// Every task's ledger, written from what an engine reports and from
/// `QuietWatch`, and kept through a `TaskLedgerStoring`.
///
/// The rule it keeps: no task ever ends silently. Each ends with one line
/// that says how, a done only with proof, and a task that goes quiet says
/// so on its own.
///
/// While the store can't be read, as before the device is first unlocked,
/// lines are kept in memory and nothing is written. Once it can be read,
/// what it held and what was written here meanwhile are put together and
/// written whole. A write that fails is tried again at the next change.
public final class TaskLedgerBook: @unchecked Sendable {
    /// Ended ledgers kept at most. Past this the oldest ended ones go.
    /// Ledgers still going are never let go.
    public static let endedLimit = 60

    public let artifacts: any TaskArtifactResolving
    private let store: any TaskLedgerStoring
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var kept: [TaskLedger] = []
    /// The store has been read, so what is here is everything.
    private var loaded = false
    /// What is here couldn't be written yet.
    private var dirty = false
    /// Cleared task ids, kept until a save persists their removal.
    private var pendingDeletions: Set<String> = []
    /// The newest snapshot written down, so a late one is dropped.
    private var seen = -1
    /// What each task was doing at the last snapshot, by ledger.
    private var last: [TaskLedger.Key: Seen] = [:]
    /// The launch's sweep, owed until the store can be read: when it was
    /// requested, and the engine's most recently reported tasks.
    private var sweep: (at: Date, live: Set<TaskLedger.Key>)?
    private var launched = false
    /// Ledgers that ended at launch since the last `takeStoppedAtLaunch`.
    private var stoppedAtLaunch: [TaskLedger.Key] = []

    private struct Seen: Equatable {
        let state: TaskState
        let step: String
        let question: UUID?
    }

    public init(store: any TaskLedgerStoring, artifacts: any TaskArtifactResolving = NoArtifacts(),
                clock: @escaping @Sendable () -> Date) {
        self.store = store
        self.artifacts = artifacts
        self.clock = clock
        lock.lock()
        loadIfNeeded()
        lock.unlock()
    }

    /// Every ledger, oldest first.
    public var ledgers: [TaskLedger] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return kept
    }

    /// The newest ledger for a task id.
    public func ledger(_ id: String) -> TaskLedger? {
        ledgers.last { $0.taskID == id }
    }

    /// The ledger for this very task, matched by its id and start.
    public func ledger(for task: AgentTask) -> TaskLedger? {
        let key = Self.key(task)
        return ledgers.last { $0.key == key }
    }

    /// How a finished task's card shows it was finished. Nil until then.
    public func finish(for task: AgentTask) -> TaskFinish? { ledger(for: task)?.finish }

    /// The line `QuietWatch` wrote last, while the task is still quiet.
    public func quietLine(for task: AgentTask) -> String? { ledger(for: task)?.quietLine }

    /// Writes down what changed in each task since the last snapshot. A
    /// snapshot older than one already written down is dropped. A task
    /// still going that is no longer there ends as stopped.
    public func record(_ snapshot: TaskSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.sequence > seen else { return }
        seen = snapshot.sequence
        let here = Set(snapshot.tasks.map(Self.key))
        // A delayed disk read must use the tasks the engine has now,
        // including restored tasks and outcomes not yet written below.
        sweep?.live = here
        loadIfNeeded()
        let now = clock()
        // Oldest first, so the ledgers go in in the order the tasks began.
        for task in snapshot.tasks.reversed() { record(task, at: now) }
        for index in kept.indices where !kept[index].isEnded && last[kept[index].key] != nil
            && !here.contains(kept[index].key) {
            kept[index].append(.stopped(why: LedgerWords.letGo), at: now, artifacts: artifacts)
        }
        last = last.filter { here.contains($0.key) }
        save()
    }

    /// Follows an engine, writing down each snapshot it reports, until the
    /// observation is cancelled or let go.
    public func follow(_ engine: any TaskEngine) -> TaskObservation {
        engine.observe { [weak self] in self?.record($0) }
    }

    /// Looks for tasks gone quiet, at the clock's time, and writes what
    /// `QuietWatch` has to say about each.
    public func watch() {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let now = clock()
        var changed = false
        for index in kept.indices {
            guard let line = QuietWatch.next(for: kept[index], now: now) else { continue }
            changed = kept[index].append(line, at: now, watched: true, artifacts: artifacts) || changed
        }
        if changed { save() }
    }

    /// At launch: any task with no end and no engine going on it ends as
    /// stopped, saying it stopped when the app closed. `live` is every task
    /// an engine has going now. If task restoration is unresolved, call
    /// again after it finishes. Runs once for this book; while the ledger
    /// can't be read it waits, using subsequent snapshots for the live set.
    ///
    /// Each one stopped here is handed over once by `takeStoppedAtLaunch`,
    /// for an offer to pick it up again.
    public func launch(live: [AgentTask], restorationComplete: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard restorationComplete, !launched else { return }
        launched = true
        let keys = Set(live.filter(\.isActive).map(Self.key))
        if loaded {
            stopOrphans(kept.indices, at: clock(), live: keys)
            save()
        } else {
            sweep = (clock(), keys)
            loadIfNeeded()
        }
    }

    /// The tasks `launch` stopped, each handed over once: the place a later
    /// offer to pick them up again starts from.
    public func takeStoppedAtLaunch() -> [TaskLedger] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let keys = stoppedAtLaunch
        stoppedAtLaunch = []
        return kept.filter { keys.contains($0.key) }
    }

    /// Takes one task's ledgers away, as its card is cleared.
    public func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        pendingDeletions.insert(id)
        kept.removeAll { $0.taskID == id }
        last = last.filter { $0.key.task != id }
        stoppedAtLaunch.removeAll { $0.task == id }
        save()
    }

    /// Forget everything, and clearing every task: every ledger goes, read
    /// or not. A late snapshot from before is still dropped.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        kept = []
        last = [:]
        pendingDeletions = []
        stoppedAtLaunch = []
        sweep = nil
        dirty = false
        if store.erase() {
            loaded = true
        } else {
            // Erased again before anything is read or written.
            loaded = false
        }
    }

    static func key(_ task: AgentTask) -> TaskLedger.Key {
        TaskLedger.Key(task: task.id, startedAt: task.startedAt)
    }

    // MARK: Inside the lock

    private func record(_ task: AgentTask, at now: Date) {
        guard !pendingDeletions.contains(task.id) else { return }
        let key = Self.key(task)
        let index: Int
        if let found = kept.lastIndex(where: { $0.key == key }) {
            index = found
        } else {
            // Its terminal ledger was evicted; an unchanged snapshot must
            // not recreate it as queued, or give it a newer terminal time.
            guard last[key]?.state.isFinished != true else { return }
            var ledger = TaskLedger(key: key)
            ledger.append(.queued, at: now, artifacts: artifacts)
            kept.append(ledger)
            index = kept.count - 1
        }
        let before = last[key]
        let seen = Seen(state: task.state, step: task.step, question: task.question?.id)
        last[key] = seen
        guard before != seen, !kept[index].isEnded else { return }
        func write(_ kind: TaskLedgerEntry.Kind) { kept[index].append(kind, at: now, artifacts: artifacts) }
        // A question that went: a yes, or anything else. A stop withdraws it
        // and says so itself.
        if let asked = before?.question, asked != seen.question, task.state != .stopped {
            write(.answered(yes: task.history.last?.mark == .approved))
        }
        switch task.state {
        case .running, .retrying:
            if before?.step != task.step || before?.state != task.state || before?.question != nil {
                write(.working(step: task.step))
            }
        case .waitingOnYou:
            if let question = task.question {
                if before?.question != question.id { write(.needsYou(question: question.id)) }
            } else if before?.state != .waitingOnYou || before?.question != nil {
                write(.stuck(reason: LedgerWords.triedReason, next: LedgerWords.triedNext))
            }
        case .stalled:
            if before?.state != .stalled { write(.stuck(reason: LedgerWords.slowReason, next: LedgerWords.slowNext)) }
        case .done:
            write(.done(proofs: task.proofs))
        case .failed:
            write(.failed(reason: task.step))
        case .stopped:
            write(.stopped(why: task.step))
        }
    }

    private func stopOrphans(_ indices: Range<Int>, at time: Date, live: Set<TaskLedger.Key>) {
        for index in indices where !kept[index].isEnded && !live.contains(kept[index].key) {
            kept[index].append(.stopped(why: LedgerWords.stoppedWhenClosed), at: time, artifacts: artifacts)
            stoppedAtLaunch.append(kept[index].key)
        }
    }

    /// Reads the store once it can. What it held comes first, then what was
    /// written here meanwhile, each line written again through `append`.
    private func loadIfNeeded() {
        guard !loaded else {
            if dirty { save() }
            return
        }
        guard let read = store.read() else { return }
        loaded = true
        let before = read.filter { !pendingDeletions.contains($0.taskID) }
            .map { $0.replayed(artifacts: artifacts) }
        var merged = before
        for ledger in kept {
            if let index = merged.firstIndex(where: { $0.key == ledger.key }) {
                // Begun again here while the store couldn't be read, so its
                // own first line is already there.
                for entry in ledger.entries where entry.kind != .queued {
                    merged[index].append(entry.kind, at: entry.at, watched: entry.watched, artifacts: artifacts)
                }
            } else {
                merged.append(ledger)
            }
        }
        kept = merged
        if let sweep {
            // Only ledgers from before the launch: those begun since are this launch's own.
            stopOrphans(0..<before.count, at: sweep.at, live: sweep.live)
            self.sweep = nil
        }
        dirty = true
        save()
    }

    private func save() {
        dropOldEnded()
        guard loaded else {
            dirty = true
            return
        }
        dirty = !store.write(kept)
        if !dirty { pendingDeletions.removeAll() }
    }

    private func dropOldEnded() {
        let ended = kept.indices.filter { kept[$0].isEnded }
            .sorted { (kept[$0].end!.at, $0) < (kept[$1].end!.at, $1) }
        guard ended.count > Self.endedLimit else { return }
        for index in ended.prefix(ended.count - Self.endedLimit).sorted().reversed() { kept.remove(at: index) }
    }
}

/// Words for what a task's ledger shows on its card.
public enum LedgerWords {
    public static let finishedLabel = "Finished"
    /// On a finished card with nothing to show for it.
    public static let unchecked = "Finished, but I couldn't check the result."
    /// "Still on it: reading the third page."
    public static func stillOnIt(_ step: String) -> String {
        "Still on it: \(sentence(step, lowered: true))"
    }
    /// The step named before a task has said what it is doing.
    public static let gettingStarted = "Getting started"
    /// Three quiet periods in a row.
    public static let quietReason = "I haven't moved forward on this in a while."
    public static let quietNext = "I'll keep trying, or you can stop me here."
    /// The engine said a step is slow.
    public static let slowReason = "This step is slow."
    public static let slowNext = "I'll try another way in a moment."
    /// The engine ran out of tries.
    public static let triedReason = "I couldn't get past this step after a few tries."
    public static let triedNext = "I'll try again when you say so, or you can stop me."
    /// At launch, for a task no engine picked up.
    public static let stoppedWhenClosed = "This stopped when the app closed."
    /// For a task an engine let go of before saying how it ended.
    public static let letGo = "I lost track of this one, so I can't say how it ended."

    /// What VoiceOver says for each chip.
    public static func spokenSource(_ title: String) -> String { "Source: \(title)" }
    public static func spokenMade(_ name: String) -> String { "Made: \(name)" }
    public static func spokenCheck(_ words: String) -> String { "Checked: \(words)" }

    /// The words as a sentence of their own, ending in a full stop. With
    /// `lowered`, the first letter is made small to follow a colon, unless
    /// the first word is "I" or all capitals, as a name like "PTA" is.
    static func sentence(_ words: String, lowered: Bool) -> String {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered, let first = text.split(separator: " ").first {
            let letters = first.prefix { $0 != "'" }.filter(\.isLetter)
            let capitals = letters == "I" || (letters.count > 1 && letters.allSatisfy(\.isUppercase))
            if !capitals { text = text.prefix(1).lowercased() + text.dropFirst() }
        }
        if let end = text.last, !".!?".contains(end) { text += "." }
        return text
    }
}
