import Foundation

/// How long a yes from the question sheet lasts.
public enum GrantScope: Sendable, Equatable, Hashable {
    /// Spent by its first use.
    case once
    /// Until the task with this key ends. The key is the one `AskFirst`
    /// gave the question (`ConfirmationRequest.task`), unique to one task
    /// of one engine, so a task in another window never shares it.
    case thisTask(String)
    /// Until this time, on the book's clock.
    case until(Date)
    /// Until the person removes it.
    case always
}

/// What the person picks on the question sheet, in the order it shows them.
public enum GrantChoice: String, CaseIterable, Sendable, Identifiable {
    case justThisOnce
    case forThisTask
    case untilTonight
    case always

    public var id: String { rawValue }

    /// What the sheet starts on: the yes counts once.
    public static let standard = GrantChoice.justThisOnce

    /// The choices a question offers. Spending and sharing the person's
    /// details are never allowed past one task. For this task needs a task.
    public static func offered(for kind: ConsequentialAction, task: String?) -> [GrantChoice] {
        var out: [GrantChoice] = [.justThisOnce]
        if task != nil { out.append(.forThisTask) }
        if kind == .send { out += [.untilTonight, .always] }
        return out
    }

    /// "Just this once", or "Always for Sam".
    public func title(for recipient: Recipient) -> String {
        switch self {
        case .justThisOnce: GrantWords.justThisOnce
        case .forThisTask: GrantWords.forThisTask
        case .untilTonight: GrantWords.untilTonight
        case .always: GrantWords.always(recipient.displayName)
        }
    }
}

/// A yes that lasts: it lets one action go to one exact target, inside its
/// scope, without asking again. Only the question sheet's answer can make
/// one (`GrantIssuer`), and nothing can widen or extend it: every field is
/// fixed when it is made.
public struct Grant: Sendable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let action: ConsequentialAction
    /// The exact recipient the sheet showed: id, name and handle all match,
    /// as `AskFirst` matches an approval.
    public let target: Recipient
    public let scope: GrantScope
    public let createdAt: Date

    fileprivate init(id: UUID = UUID(), action: ConsequentialAction, target: Recipient, scope: GrantScope,
                     createdAt: Date) {
        self.id = id
        self.action = action
        self.target = target
        self.scope = scope
        self.createdAt = createdAt
    }

    /// Kept in the store's file. A once or a task grant lives only in
    /// memory, so it never outlives the launch it was given in.
    var isKept: Bool {
        switch scope {
        case .until, .always: true
        case .once, .thisTask: false
        }
    }

    /// "Send messages to Sam", for the list.
    public var title: String { GrantWords.title(action, target.displayName) }

    /// "Always", or "Until midnight tonight", for the list.
    public func scopeLine(now: Date, calendar: Calendar = .current) -> String {
        switch scope {
        case .once: GrantWords.justThisOnce
        case .thisTask: GrantWords.whileTaskRuns
        case .always: GrantWords.alwaysLine
        case .until(let end): GrantWords.until(end, now: now, calendar: calendar)
        }
    }
}

/// Makes grants. Only the question sheet's answer path holds one: its
/// init is package only, and a source guard (`grant.issuerOutsideSheet` in
/// Tools/GuardKit) fails if any file but this one and the sheet's names it.
/// A grant is made from an `Approval`, which only the sheet's yes makes,
/// so nothing in a chat, a model's reply, a note or a task step can make,
/// widen or extend one.
public struct GrantIssuer: Sendable {
    package init() {}

    /// The grant for `choice`, for exactly what `approval` approved. Nil
    /// when the choice isn't offered for it: past one task for spending or
    /// sharing, for this task without a task, or a target with no handle.
    package func issue(_ choice: GrantChoice, for approval: Approval, now: Date,
                       calendar: Calendar = .current) -> Grant? {
        let action = approval.action
        guard action.recipient.handle != nil,
              GrantChoice.offered(for: action.kind, task: approval.task).contains(choice) else { return nil }
        let scope: GrantScope
        switch choice {
        case .justThisOnce: scope = .once
        case .forThisTask:
            guard let task = approval.task else { return nil }
            scope = .thisTask(task)
        case .untilTonight: scope = .until(GrantGate.endOfDay(now, calendar: calendar))
        case .always: scope = .always
        }
        return Grant(action: action.kind, target: action.recipient, scope: scope, createdAt: now)
    }
}

/// The check `AskFirst` makes before it asks: does a grant cover this
/// action, now, for this task? Pure and deterministic: the same grants,
/// action, task and time always give the same answer.
public enum GrantGate {
    public enum Decision: Sendable, Equatable {
        /// This grant lets the action go ahead without asking.
        case allowed(Grant)
        /// No grant covers it: ask, as always.
        case ask
    }

    /// The first grant that covers `action`, preferring one that isn't
    /// spent by its use, then the oldest. `task` is the asking task's key.
    public static func check(_ action: ProposedAction, task: String?, grants: [Grant], now: Date) -> Decision {
        let covering = grants.filter { covers($0, action, task: task, now: now) }
        let best = covering.min { a, b in
            (a.scope == .once ? 1 : 0, a.createdAt, a.id.uuidString) < (b.scope == .once ? 1 : 0, b.createdAt, b.id.uuidString)
        }
        return best.map(Decision.allowed) ?? .ask
    }

    /// True when `grant` lets `action` go ahead: its own action, its own
    /// exact target, inside its scope, and only for what a question could
    /// have shown. A clock set back before the grant was made covers nothing.
    public static func covers(_ grant: Grant, _ action: ProposedAction, task: String?, now: Date) -> Bool {
        guard grant.action == action.kind, grant.target == action.recipient,
              action.recipient.handle != nil, AskFirst.canAsk(action),
              allows(grant.scope, for: grant.action), now >= grant.createdAt else { return false }
        switch grant.scope {
        case .once, .always: return true
        case .thisTask(let key): return task == key
        case .until(let end): return now < end
        }
    }

    /// Spending and sharing the person's details never go past one task,
    /// however a grant came to say otherwise.
    static func allows(_ scope: GrantScope, for kind: ConsequentialAction) -> Bool {
        switch scope {
        case .once, .thisTask: true
        case .until, .always: kind == .send
        }
    }

    /// Midnight at the end of `now`'s local day.
    public static func endOfDay(_ now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
    }
}

/// A step a grant let go ahead. Only `GrantBook.use` makes one, so an
/// engine can't go ahead without a grant that covered it.
public struct GrantedStep: Sendable, Equatable {
    public let action: ProposedAction
    public let grant: Grant

    fileprivate init(action: ProposedAction, grant: Grant) {
        self.action = action
        self.grant = grant
    }
}

/// What a grant store's file holds right now.
public enum GrantFile: Sendable, Equatable {
    /// No file: no grants kept.
    case empty
    case data(Data)
    /// There, but it can't be read yet, as before the first unlock, or a
    /// forget is still owed on it. Nothing is written over it.
    case unavailable
}

/// Where the grants that outlive a launch are kept: the file, or a store
/// in memory for tests. Bytes only, so a later store, such as one in the
/// Keychain, needs only these three, and no store can make a grant.
public protocol GrantStoring: AnyObject, Sendable {
    func read() -> GrantFile
    /// False when it couldn't be written. It is tried again later.
    @discardableResult func write(_ data: Data) -> Bool
    /// Removes every kept grant. False while that couldn't be done; the
    /// store then reads as unavailable until it can.
    @discardableResult func erase() -> Bool
}

/// Grants kept in memory, for tests and screenshots. It can play a
/// locked device or a disk that won't write.
public final class GrantMemoryStore: GrantStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var isLocked = false
    private var failsWrites = false
    private var failsErases = false

    public init() {}

    /// While true, erases fail too, and leave what was kept.
    package var failingErase: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failsErases }
        set { lock.lock(); failsErases = newValue; lock.unlock() }
    }

    /// While true, reads say unavailable, as a file before the first unlock.
    package var locked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isLocked }
        set { lock.lock(); isLocked = newValue; lock.unlock() }
    }

    /// While true, writes fail.
    package var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failsWrites }
        set { lock.lock(); failsWrites = newValue; lock.unlock() }
    }

    /// The bytes kept, for tests.
    package var bytes: Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    public func read() -> GrantFile {
        lock.lock(); defer { lock.unlock() }
        if isLocked { return .unavailable }
        return data.map(GrantFile.data) ?? .empty
    }

    public func write(_ next: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isLocked, !failsWrites else { return false }
        data = next
        return true
    }

    public func erase() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failsErases else { return false }
        data = nil
        return true
    }
}

/// The grants file, with complete file protection: it can be read only
/// while the device is unlocked. Like the task store, a file that can't be
/// read yet is never written over, only tried again. A forget that
/// couldn't delete the file leaves a marker, so the file is never read
/// again, on this launch or a later one, and goes as soon as it can.
public final class GrantFileStore: GrantStoring, @unchecked Sendable {
    public let fileURL: URL
    private let markerURL: URL
    private let lock = NSLock()
    /// True for a store that keeps its grants in memory, as when its folder
    /// couldn't be opened, and only forgets the file.
    private let forgetOnly: Bool
    /// What a forget-only store keeps.
    private var held: Data?
    /// A forget remains owed even if its marker could not be written.
    private var pendingErase = false

    package init(fileURL: URL, forgetMarker: URL) {
        self.fileURL = fileURL
        markerURL = forgetMarker
        forgetOnly = false
    }

    /// Kept in memory only, but Forget everything still deletes the file at
    /// `forgets`, left by an earlier launch, which is never read. Any erase
    /// deletes it, so nothing in it can come back. A forget an earlier launch
    /// still owed is carried out now.
    package init(forgetOnly forgets: URL, forgetMarker: URL) {
        fileURL = forgets
        markerURL = forgetMarker
        forgetOnly = true
        lock.lock()
        if Self.presence(markerURL) == .present { _ = eraseOwed() }
        lock.unlock()
    }

    /// For when `onDevice` couldn't open its folder: keeps the grants in
    /// memory, and Forget everything still deletes a file an earlier launch
    /// left there.
    public static func forgetOnly(fileManager: FileManager = .default) -> any GrantStoring {
        guard let base = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: false) else { return GrantMemoryStore() }
        let (file, marker) = location(base: base, app: TaskStore.appFolder)
        return GrantFileStore(forgetOnly: file, forgetMarker: marker)
    }

    /// Where the file and its marker go, under `app`'s own folder.
    package static func location(base: URL, app: String) -> (file: URL, marker: URL) {
        let root = base.appendingPathComponent(app, isDirectory: true)
        return (root.appendingPathComponent("grants", isDirectory: true).appendingPathComponent("grants.json"),
                root.appendingPathComponent("pending", isDirectory: true).appendingPathComponent("grants-forgotten"))
    }

    /// The store on this device, beside the kept tasks, left out of backups.
    public static func onDevice(fileManager: FileManager = .default) throws -> GrantFileStore {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let (file, marker) = location(base: base, app: TaskStore.appFolder)
        for folder in [file.deletingLastPathComponent(), marker.deletingLastPathComponent()] {
            var folder = folder
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try MemoryStore.excludeFromBackup(&folder)
        }
        return GrantFileStore(fileURL: file, forgetMarker: marker)
    }

    /// How the file is written: complete protection, where the system
    /// protects files. A Mac's are kept by FileVault and the login instead.
    package static func fileWriting(protected: Bool = TaskStore.protectsFiles) -> Data.WritingOptions {
        protected ? [.atomic, .completeFileProtection] : [.atomic]
    }

    public func read() -> GrantFile {
        lock.lock(); defer { lock.unlock() }
        guard finishPendingErase() else { return .unavailable }
        if forgetOnly { return held.map(GrantFile.data) ?? .empty }
        if Self.isAbsent(fileURL) { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { return .unavailable }
        return .data(data)
    }

    public func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard finishPendingErase() else { return false }
        if forgetOnly {
            held = data
            return true
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: Self.fileWriting())) != nil
    }

    public func erase() -> Bool {
        lock.lock(); defer { lock.unlock() }
        held = nil
        // Written first, with no protection, so a forget cut short is
        // still owed on the next launch.
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        pendingErase = true
        let marked = (try? Data().write(to: markerURL, options: TaskStore.markerWriting())) != nil
        let erased = eraseOwed()
        // Keep a failed marker write visible even if deletion succeeded.
        pendingErase = !marked || !erased
        return !pendingErase
    }

    /// An inaccessible marker is unknown, never evidence of a forget.
    /// An explicit forget this launch is still owed without a marker.
    private func finishPendingErase() -> Bool {
        if pendingErase { return eraseOwed() }
        switch Self.presence(markerURL) {
        case .present: return eraseOwed()
        case .absent: return true
        case .inaccessible: return false
        }
    }

    /// Deletes the file, then the marker. Done only when the file was
    /// deleted or is known not to be there: a folder that won't let the
    /// delete through hides the file too, so the marker stays and the
    /// forget is still owed. Called with the lock held.
    private func eraseOwed() -> Bool {
        guard Self.delete(fileURL) else { return false }
        guard Self.delete(markerURL) else { return false }
        pendingErase = false
        return true
    }

    /// False unless `url` is gone: deleted now, or not there at all.
    private static func delete(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return isAbsent(url)
        }
    }

    /// True only when the system says nothing is at `url`. A folder on the
    /// way that can't be searched, or any other failure, is not proof.
    private static func isAbsent(_ url: URL) -> Bool {
        presence(url) == .absent
    }

    private enum Presence { case present, absent, inaccessible }

    private static func presence(_ url: URL) -> Presence {
        var info = stat()
        let result = lstat(url.path, &info)
        let failure = errno // Capture immediately, before any other system call.
        if result == 0 { return .present }
        return failure == ENOENT ? .absent : .inaccessible
    }
}

/// Every grant the person has given, and the one place they are used.
///
/// Once and task grants live in memory. Grants until a time and always
/// grants are kept by the store. While the store can't be read, as before
/// the first unlock, the kept ones are unknown, so none of them lets
/// anything go ahead: the agent asks. A grant given or removed meanwhile
/// is held here and written once the store can be read again.
public final class GrantBook: @unchecked Sendable {
    private let store: any GrantStoring
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Every grant known, kept and not, oldest first.
    private var all: [Grant] = []
    /// False while the store couldn't be read, so its grants are unknown.
    private var loaded = false
    /// Kept grants given or removed while the store couldn't be read.
    private var addedWhileUnread: [Grant] = []
    private var removedWhileUnread: Set<UUID> = []
    /// The kept grants couldn't be written or erased. Tried again at each use.
    private var dirty = false
    private var owesErase = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(store: any GrantStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// In memory only, for tests and screenshots.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) -> GrantBook {
        GrantBook(store: GrantMemoryStore(), now: now)
    }

    /// The book on this device, its kept grants in the file. If the file's
    /// folder can't be made, they are kept in memory, and Forget everything
    /// still deletes the file an earlier launch left.
    public static func onDevice(fileManager: FileManager = .default) -> GrantBook {
        if let store = try? GrantFileStore.onDevice(fileManager: fileManager) { return GrantBook(store: store) }
        return GrantBook(store: GrantFileStore.forgetOnly(fileManager: fileManager))
    }

    /// Every grant still in force, newest first, for the list.
    public var grants: [Grant] {
        locked { () -> ([Grant], Bool) in
            loadIfNeeded()
            let changed = dropLapsed(at: now())
            return (all.filter { GrantGate.allows($0.scope, for: $0.action) }.reversed(), changed)
        }
    }

    /// Adds a grant from the sheet's answer. A once grant is spent by the
    /// step that asked, so it is never added.
    public func add(_ grant: Grant) {
        guard grant.scope != .once else { return }
        insert(grant)
    }

    /// Adds a grant of any scope. Internal, so a once grant gets here only
    /// from a test.
    func insert(_ grant: Grant) {
        locked { () -> ((), Bool) in
            loadIfNeeded()
            guard !all.contains(where: { $0.id == grant.id }) else { return ((), false) }
            all.append(grant)
            if grant.isKept {
                if loaded { save() } else { addedWhileUnread.append(grant) }
            }
            return ((), true)
        }
    }

    /// Removes one grant, at once: the next step it would have covered asks.
    /// True once it is gone for good. False when there was no such grant,
    /// or when the store couldn't take the change: it is off for this
    /// launch, the change is tried again at each use, and `unsaved` says so.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        locked { () -> (Bool, Bool) in
            loadIfNeeded()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return (false, false) }
            let grant = all.remove(at: index)
            guard grant.isKept else { return (true, true) }
            guard loaded else {
                // Given this launch and never written, so nothing to undo.
                addedWhileUnread.removeAll { $0.id == id }
                removedWhileUnread.insert(id)
                return (true, true)
            }
            save()
            // The old file still holds it, so a later launch would read it
            // back. Every kept grant is erased instead: none can come back
            // as a yes, and the rest are written again once the store takes
            // them. Until then a restart loses them, and the agent asks.
            if dirty, !owesErase, !store.erase() { owesErase = true }
            return (!owesErase, true)
        }
    }

    /// What couldn't be saved yet, for the list. Each is tried again at
    /// each use.
    public enum Unsaved: Sendable, Equatable {
        /// Grants in force that the store couldn't take. If the app closes
        /// first they are gone, and the agent asks again.
        case grants
        /// A grant removed, or Forget everything, that the store couldn't
        /// take yet. Until it does, the old file may still hold it.
        case removal
    }

    /// Nil once every change is saved.
    public var unsaved: Unsaved? {
        lock.lock(); defer { lock.unlock() }
        return unsavedNow
    }

    /// Called with the lock held.
    private var unsavedNow: Unsaved? {
        if owesErase { return .removal }
        return dirty || !addedWhileUnread.isEmpty ? .grants : nil
    }

    /// A task ended: its task grants end with it.
    public func taskEnded(_ key: String) {
        locked { () -> ((), Bool) in
            let before = all.count
            all.removeAll { $0.scope == .thisTask(key) }
            return ((), all.count != before)
        }
    }

    /// Forget everything: every grant, in memory and kept.
    public func forget() {
        locked { () -> ((), Bool) in
            let had = !all.isEmpty
            all = []
            addedWhileUnread = []
            removedWhileUnread = []
            dirty = false
            owesErase = !store.erase()
            // Known to be empty now, so nothing kept before comes back.
            loaded = !owesErase
            return ((), had)
        }
    }

    /// The step `AskFirst` is about to ask about may go ahead when a grant
    /// covers it. A once grant is spent here, in the same breath.
    func use(_ action: ProposedAction, task: String?) -> GrantedStep? {
        locked { () -> (GrantedStep?, Bool) in
            loadIfNeeded()
            let time = now()
            var changed = dropLapsed(at: time)
            guard case .allowed(let grant) = GrantGate.check(action, task: task, grants: all, now: time) else {
                return (nil, changed)
            }
            if grant.scope == .once {
                all.removeAll { $0.id == grant.id }
                changed = true
            }
            return (GrantedStep(action: action, grant: grant), changed)
        }
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

    /// Runs `body` with the lock held, then calls the watchers when it
    /// says something changed, grants were loaded, or a change was saved
    /// or failed to be.
    private func locked<T>(_ body: () -> (T, Bool)) -> T {
        lock.lock()
        let before = unsavedNow
        let grantsBefore = all
        let (value, changed) = body()
        let hooks = changed || all != grantsBefore || unsavedNow != before ? Array(observers.values) : []
        lock.unlock()
        for hook in hooks { hook() }
        return value
    }

    /// Drops grants whose time has passed. Called with the lock held.
    private func dropLapsed(at time: Date) -> Bool {
        let lapsed = all.filter { if case .until(let end) = $0.scope { time >= end } else { false } }
        guard !lapsed.isEmpty else { return false }
        all.removeAll { grant in lapsed.contains { $0.id == grant.id } }
        if loaded { save() }
        return true
    }

    /// Reads the kept grants once the store can be read, and writes again
    /// what couldn't be written. One that can't be understood is erased:
    /// nothing could read it back, and no grant is better than a wrong one.
    /// Called with the lock held.
    private func loadIfNeeded() {
        // Read again once erased: what was given meanwhile is merged below.
        if owesErase {
            guard store.erase() else { return }
            owesErase = false
        }
        if loaded {
            if dirty { save() }
            return
        }
        let kept: [Grant]
        switch store.read() {
        case .unavailable: return
        case .empty: kept = []
        case .data(let data):
            if let decoded = try? JSONDecoder().decode([StoredGrant].self, from: data) {
                kept = decoded.compactMap(\.grant)
            } else {
                kept = []
                dirty = true
            }
        }
        loaded = true
        let fresh = kept.filter { grant in
            !removedWhileUnread.contains(grant.id) && !all.contains { $0.id == grant.id }
        }
        all = (fresh + all).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        if !addedWhileUnread.isEmpty || !removedWhileUnread.isEmpty { dirty = true }
        addedWhileUnread = []
        removedWhileUnread = []
        if dirty { save() }
    }

    /// Writes every kept grant. Called with the lock held, once loaded.
    private func save() {
        let kept = all.filter(\.isKept).compactMap(StoredGrant.init)
        if kept.isEmpty {
            dirty = !store.erase()
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(kept) else {
            dirty = true
            return
        }
        dirty = !store.write(data)
    }
}

/// A kept grant as it is written down. Only this file reads it back, and a
/// grant read back is checked as a question would be: one changed into
/// something no sheet could have given is dropped.
private struct StoredGrant: Codable {
    let id: UUID
    let action: ConsequentialAction
    let recipientID: String
    let recipientName: String
    let handle: String
    /// "always", or "until" with `until`.
    let scope: String
    let until: Date?
    let createdAt: Date

    init?(_ grant: Grant) {
        guard let handle = grant.target.handle else { return nil }
        id = grant.id
        action = grant.action
        recipientID = grant.target.id
        recipientName = grant.target.displayName
        self.handle = handle
        createdAt = grant.createdAt
        switch grant.scope {
        case .always:
            scope = "always"
            until = nil
        case .until(let end):
            scope = "until"
            until = end
        case .once, .thisTask:
            return nil
        }
    }

    var grant: Grant? {
        let target = Recipient(id: recipientID, displayName: recipientName, handle: handle)
        guard target.handle == handle, target.displayName == recipientName,
              !recipientID.isEmpty, !AskFirst.hasHiddenScalars(recipientID) else { return nil }
        let kept: GrantScope
        switch (scope, until) {
        case ("always", nil): kept = .always
        case ("until", let end?) where end > createdAt: kept = .until(end)
        default: return nil
        }
        guard GrantGate.allows(kept, for: action) else { return nil }
        return Grant(id: id, action: action, target: target, scope: kept, createdAt: createdAt)
    }
}

/// Words for grants: the sheet's choices, the list, and the receipt line.
public enum GrantWords {
    public static let choiceHeading = "How long is this yes for?"
    public static let justThisOnce = "Just this once"
    public static let forThisTask = "For this task"
    public static let untilTonight = "Until tonight"
    public static func always(_ name: String) -> String { "Always for \(name)" }

    /// What a choice means, under it on the sheet.
    public static func choiceDetail(_ choice: GrantChoice) -> String {
        switch choice {
        case .justThisOnce: "I'll ask you again next time."
        case .forThisTask: "Until this task ends."
        case .untilTonight: "Until midnight."
        case .always: "Until you remove it."
        }
    }

    /// The promise under the sheet's details, for a choice wider than once.
    /// It names the exact handle, the only place the yes reaches.
    public static func promise(_ choice: GrantChoice, kind: ConsequentialAction, handle: String) -> String {
        let what = verb(kind, handle)
        switch choice {
        case .justThisOnce: return ConfirmationWords.promise
        case .forThisTask:
            return "If you say yes, I can \(what) again until this task ends, without asking each time. For anything else, I'll ask you first."
        case .untilTonight:
            return "If you say yes, I can \(what) until midnight, without asking each time. For anything else, I'll ask you first."
        case .always:
            return "If you say yes, I can \(what) without asking each time, until you remove it from \(listTitle). For anything else, I'll ask you first."
        }
    }

    /// "send messages to sam@example.com"
    static func verb(_ kind: ConsequentialAction, _ target: String) -> String {
        switch kind {
        case .send: "send messages to \(target)"
        case .purchase: "pay \(target)"
        case .sharePersonalInfo: "share your details with \(target)"
        case .save: "keep things in \(target)"
        }
    }

    /// "Send messages to Sam", for a row of the list.
    public static func title(_ kind: ConsequentialAction, _ name: String) -> String {
        switch kind {
        case .send: "Send messages to \(name)"
        case .purchase: "Pay \(name)"
        case .sharePersonalInfo: "Share your details with \(name)"
        case .save: "Keep things in \(name)"
        }
    }

    // The list, on the memory screen.
    public static let listTitle = "What I'm allowed to do"
    public static let listDetail = "These I can do without asking you each time. Remove one and I'll ask you first again."
    public static let listEmpty = "Nothing yet. I'll ask you first every time."
    public static let removeTitle = "Remove"
    /// What VoiceOver reads for a row's Remove, so each says which it is.
    public static func removeLabel(_ kind: ConsequentialAction, _ name: String) -> String {
        "Remove \(title(kind, name).lowercasedFirst)"
    }
    /// Said once a grant is removed, since its row goes from under VoiceOver.
    public static let removed = "Removed. I'll ask you first next time."
    /// Under the list while a change couldn't be saved yet.
    public static func unsaved(_ what: GrantBook.Unsaved) -> String {
        switch what {
        case .removal:
            "I couldn't save that just now. It's off for now, and I'll keep trying. If the app closes first, check this list when you're back."
        case .grants:
            "I couldn't save this list just now, and I'll keep trying. If the app closes first, I'll ask you first again for these."
        }
    }
    public static let alwaysLine = "Always, until you remove it"
    public static let whileTaskRuns = "For this task, until it ends"
    public static let untilMidnight = "Until midnight tonight"
    /// A grant until a time: tonight, or the day and time it ends.
    public static func until(_ end: Date, now: Date, calendar: Calendar) -> String {
        if end == GrantGate.endOfDay(now, calendar: calendar) { return untilMidnight }
        return "Until \(end.formatted(.dateTime.weekday(.wide).hour().minute()))"
    }

    // On a task and its receipt, when a grant let a step go ahead.
    /// The step's line in the task's history.
    public static let wentAhead = "You'd said I could do this without asking, so I went ahead."
    /// The receipt's line, naming the grant.
    public static func receiptLine(_ kind: ConsequentialAction, sameDay: Bool) -> String {
        let when = sameDay ? "earlier today" : "an earlier day"
        switch kind {
        case .send: return "Sent with your OK from \(when)."
        case .purchase: return "Paid with your OK from \(when)."
        case .sharePersonalInfo: return "Shared with your OK from \(when)."
        case .save: return "Kept with your OK from \(when)."
        }
    }
    /// The receipt's line when the step was under way as the task stopped.
    public static let receiptMayBeDone = "I'd started this with your OK from earlier when I stopped, so it may be done."
}

private extension String {
    /// The same words with the first letter lowercased.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
