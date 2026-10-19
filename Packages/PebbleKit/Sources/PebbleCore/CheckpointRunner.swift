import Foundation

/// What a step did when its try worked.
public enum StepResult: Codable, Sendable, Equatable {
    /// The step is finished.
    case done
    /// The step can't go on without the person. The run keeps its place and
    /// stops; running it again with their answer tries this step again.
    case needsYou(question: String)
}

/// One try of one step, as the step sees it.
public struct StepAttempt: Sendable, Equatable {
    public let taskID: String
    /// The step's place in the run, from zero.
    public let step: Int
    /// Which try this is, from one.
    public let tryNumber: Int
    /// The same on every try of this step, and after the run is picked up
    /// again. Send it with anything that leaves the device.
    public let key: IdempotencyKey
    /// What the person answered, when this step asked them and the run was
    /// picked up again with their answer.
    public let answer: String?
}

/// One step of a run.
public struct RunStep: Sendable {
    public let name: String
    /// How long one try may take before it ends as timed out.
    public let limit: TimeInterval
    public let body: @Sendable (StepAttempt) async throws -> StepResult

    public init(_ name: String, limit: TimeInterval = 60,
                body: @escaping @Sendable (StepAttempt) async throws -> StepResult) {
        self.name = name
        self.limit = limit
        self.body = body
    }
}

/// How a run ended. Every run ends in exactly one of these.
public enum RunOutcome: Codable, Sendable, Equatable {
    /// Every step is finished.
    case done
    /// `step` failed for `reason`, and won't be tried again on its own.
    case failed(step: Int, reason: StepFailure)
    /// The run was cancelled during or before `step`. Running it again
    /// picks up there.
    case stopped(step: Int)
    /// `step` is waiting on the person's answer to `question`.
    case waiting(step: Int, question: String)
}

/// Where a run has got to, kept after each finished step.
public struct Checkpoint: Codable, Sendable, Equatable {
    public let taskID: String
    /// How many steps are finished. The next to run is the one at this place.
    public var finished: Int
    /// The question the next step is waiting on the person to answer.
    public var question: String?
    /// How the run ended, once it is done or failed. A run that ended is
    /// never run again; it only tells this.
    public var ended: RunOutcome?
    public var savedAt: Date

    public init(taskID: String, finished: Int = 0, question: String? = nil, ended: RunOutcome? = nil,
                savedAt: Date) {
        self.taskID = taskID
        self.finished = finished
        self.question = question
        self.ended = ended
        self.savedAt = savedAt
    }
}

/// What is kept for one task.
public enum KeptCheckpoint: Sendable, Equatable {
    /// Nothing is kept for it.
    case missing
    case kept(Checkpoint)
    /// Something is kept for it that can't be understood, as from another
    /// version. It is kept as it is until the task is forgotten.
    case unreadable
}

/// Where checkpoints are kept, one for each task. Reading may not be
/// possible yet, as while the device is locked, and then nothing
/// is written either.
public protocol CheckpointStoring: AnyObject, Sendable {
    /// Every checkpoint kept that can be understood, by task, or nil while
    /// they can't be read.
    func read() -> [String: Checkpoint]?
    /// What is kept for `taskID`, or nil while it can't be read.
    func checkpoint(_ taskID: String) -> KeptCheckpoint?
    /// Reads every checkpoint, lets `edit` change them and keeps the result,
    /// all in one go, so no other change can land in between and be lost.
    /// `edit` never touches the store, and sees only the checkpoints that
    /// can be understood; the rest are kept as they are. False when they
    /// couldn't be read or written now, or `edit` set a task whose kept
    /// checkpoint can't be understood, and then nothing changed.
    @discardableResult
    func update(_ edit: (inout [String: Checkpoint]) -> Void) -> Bool
    /// Lets go of what is kept for `taskID`, whether it can be understood
    /// or not. False when it couldn't.
    @discardableResult
    func remove(_ taskID: String) -> Bool
}

extension CheckpointStoring {
    public func checkpoint(_ taskID: String) -> KeptCheckpoint? {
        guard let all = read() else { return nil }
        return all[taskID].map(KeptCheckpoint.kept) ?? .missing
    }

    /// Keeps `checkpoint` beside the others. False when it couldn't be kept.
    @discardableResult
    public func save(_ checkpoint: Checkpoint) -> Bool {
        update { $0[checkpoint.taskID] = checkpoint }
    }

    @discardableResult
    public func remove(_ taskID: String) -> Bool {
        update { $0[taskID] = nil }
    }
}

/// Runs a task's steps in order and keeps a checkpoint after each one, so a
/// run cut short, by the app closing or by a question for the person, picks
/// up at the first step that isn't finished and never does a finished one
/// again.
///
/// Each step is tried until it works, up to `policy.maxTries`, waiting
/// between tries as the policy says. Failures that aren't transient end the
/// run on the first try. Every try carries the step's `IdempotencyKey`, so
/// a step tried again after the app closed mid step is the same request.
public final class CheckpointRunner: @unchecked Sendable {
    public let taskID: String
    private let steps: [RunStep]
    private let store: any CheckpointStoring
    private let policy: BackoffPolicy
    private let clock: any RunClock
    private let sleeper: any RunSleeper
    private let random: @Sendable () -> Double
    private let lock = NSLock()
    /// How the run ended, when that couldn't be kept yet. Kept again before
    /// anything runs, so a step that ended the run is never run again.
    private var unkeptEnd: Checkpoint?

    public init(taskID: String, steps: [RunStep], store: any CheckpointStoring, policy: BackoffPolicy = .standard,
                clock: any RunClock = SystemRunClock(), sleeper: any RunSleeper = SystemRunSleeper(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.taskID = taskID
        self.steps = steps
        self.store = store
        self.policy = policy
        self.clock = clock
        self.sleeper = sleeper
        self.random = random
    }

    /// Runs from the first step that isn't finished, to the end or until a
    /// step stops it. `answer` is the person's answer to the question the
    /// run is waiting on; without one a waiting run stays waiting.
    public func run(answer: String? = nil) async -> RunOutcome {
        let unkept = heldEnd
        let kept: Checkpoint?
        switch store.checkpoint(taskID) {
        case nil: return .failed(step: unkept?.ended.map(endingStep) ?? 0, reason: .notSaved)
        case .unreadable: return .failed(step: 0, reason: .unreadable)
        case .missing: kept = nil
        case .kept(let checkpoint): kept = checkpoint
        }
        if let ended = kept?.ended {
            heldEnd = nil
            return ended
        }
        if var unkept, let ended = unkept.ended { return end(&unkept, ended) }
        var checkpoint = kept ?? Checkpoint(taskID: taskID, savedAt: clock.now)
        // A place this run can't have reached, as from a file written for
        // other steps, is never run from or told as done.
        let last = checkpoint.question == nil ? steps.count : steps.count - 1
        guard checkpoint.finished >= 0, checkpoint.finished <= last else {
            return .failed(step: 0, reason: .unreadable)
        }
        var index = checkpoint.finished
        var answer = answer
        if let question = checkpoint.question, answer == nil {
            return .waiting(step: index, question: question)
        }
        while index < steps.count {
            if Task.isCancelled { return .stopped(step: index) }
            let step = steps[index]
            let key = IdempotencyKey(taskID: taskID, step: index)
            var tryNumber = 1
            stepTries: while true {
                let attempt = StepAttempt(taskID: taskID, step: index, tryNumber: tryNumber, key: key, answer: answer)
                let tried = await StepLimit.run(limit: step.limit, sleeper: sleeper) { try await step.body(attempt) }
                switch tried {
                case .finished(.done):
                    checkpoint.finished = index + 1
                    checkpoint.question = nil
                    guard keep(&checkpoint) else { return .failed(step: index, reason: .notSaved) }
                    break stepTries
                case .finished(.needsYou(let question)):
                    checkpoint.question = question
                    guard keep(&checkpoint) else { return .failed(step: index, reason: .notSaved) }
                    return .waiting(step: index, question: question)
                case .cancelled:
                    return .stopped(step: index)
                case .failed(let failure):
                    if !failure.isTransient || tryNumber >= policy.maxTries {
                        return end(&checkpoint, .failed(step: index, reason: failure))
                    }
                    let wait = policy.delay(afterTry: tryNumber, failure: failure, now: clock.now, random: random())
                    do {
                        try await sleeper.sleep(wait, for: .backoff)
                    } catch {
                        return .stopped(step: index)
                    }
                    tryNumber += 1
                }
            }
            answer = nil
            index += 1
        }
        return end(&checkpoint, .done)
    }

    /// Lets go of this task's checkpoint, as when the person clears it.
    @discardableResult
    public func forget() -> Bool {
        guard store.remove(taskID) else { return false }
        heldEnd = nil
        return true
    }

    private var heldEnd: Checkpoint? {
        get { lock.lock(); defer { lock.unlock() }; return unkeptEnd }
        set { lock.lock(); unkeptEnd = newValue; lock.unlock() }
    }

    private func keep(_ checkpoint: inout Checkpoint) -> Bool {
        checkpoint.savedAt = clock.now
        return store.save(checkpoint)
    }

    /// Keeps how the run ended, so running it again only tells it. When it
    /// can't be kept the run says so, and this runner holds the end and
    /// keeps it before anything else, rather than run the step again.
    private func end(_ checkpoint: inout Checkpoint, _ outcome: RunOutcome) -> RunOutcome {
        checkpoint.ended = outcome
        checkpoint.question = nil
        guard keep(&checkpoint) else {
            heldEnd = checkpoint
            return .failed(step: endingStep(outcome), reason: .notSaved)
        }
        heldEnd = nil
        return outcome
    }

    /// The step a run ended at: the one that failed, or the last.
    private func endingStep(_ outcome: RunOutcome) -> Int {
        switch outcome {
        case .failed(let step, _), .stopped(let step), .waiting(let step, _): step
        case .done: max(steps.count - 1, 0)
        }
    }
}

/// Kept in memory only, for tests. `locked` stands for a locked device:
/// nothing can be read or written.
public final class InMemoryCheckpointStore: CheckpointStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: Checkpoint]
    private var isLocked: Bool
    private var writeCount = 0

    public init(_ kept: [String: Checkpoint] = [:], locked: Bool = false) {
        self.kept = kept
        isLocked = locked
    }

    public var locked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isLocked }
        set { lock.lock(); isLocked = newValue; lock.unlock() }
    }

    /// What is kept now, whatever the lock says. For tests.
    public var checkpoints: [String: Checkpoint] { lock.lock(); defer { lock.unlock() }; return kept }

    /// Writes that went in. For tests.
    public var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    private var readHook: (@Sendable () -> Void)?

    /// Called each time the store lets go after reading, outside its lock,
    /// so a test can put another change there.
    public var afterRead: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return readHook }
        set { lock.lock(); readHook = newValue; lock.unlock() }
    }

    public func read() -> [String: Checkpoint]? {
        lock.lock()
        let all = isLocked ? nil : kept
        let hook = readHook
        lock.unlock()
        hook?()
        return all
    }

    public func update(_ edit: (inout [String: Checkpoint]) -> Void) -> Bool {
        lock.lock()
        let changed = !isLocked
        if changed {
            var all = kept
            edit(&all)
            if all != kept {
                kept = all
                writeCount += 1
            }
        }
        let hook = readHook
        lock.unlock()
        hook?()
        return changed
    }
}

/// The checkpoints in one file beside the kept tasks, written the way
/// `TaskStore` writes its file: whole, through a staged copy, and readable
/// only while the device is unlocked. A file that is there but can't be
/// read yet is never written over. Each task's record is read on its own:
/// one that can't be understood makes that task alone unreadable, and is
/// never deleted or written over until its task is forgotten. Every store
/// for one file in this process shares one lock, so two of them never lose
/// each other's changes.
public final class CheckpointFileStore: CheckpointStoring, @unchecked Sendable {
    public let fileURL: URL
    /// Held for each read and change of the file and its staged copy.
    private let fileLock: FileLock
    /// Guards the test hooks only.
    private let lock = NSLock()

    package init(fileURL: URL) {
        self.fileURL = fileURL
        fileLock = FileLock.shared(for: fileURL)
    }

    /// Where the checkpoints are kept beside the tasks, under `base`.
    package static func location(base: URL, app: String = TaskStore.appFolder) -> URL {
        TaskStore.location(base: base, app: app).file.deletingLastPathComponent()
            .appendingPathComponent("checkpoints.json")
    }

    /// The store on this device, in the kept tasks' folder, which is left
    /// out of backups.
    public static func onDevice(fileManager: FileManager = .default) throws -> CheckpointFileStore {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let file = location(base: base)
        var folder = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try MemoryStore.excludeFromBackup(&folder)
        return CheckpointFileStore(fileURL: file)
    }

    /// How the file is written: as the kept tasks are, so it can be read
    /// only while the device is unlocked.
    package static func fileWriting(protected: Bool = TaskStore.protectsFiles) -> Data.WritingOptions {
        TaskStore.fileWriting(protected: protected)
    }

    private var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    private var readHook: (@Sendable () -> Void)?

    /// Called each time the store lets go after reading, outside its lock,
    /// so a test can put another change there.
    package var afterRead: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return readHook }
        set { lock.lock(); readHook = newValue; lock.unlock() }
    }

    private var heldHook: (@Sendable () -> Void)?

    /// Called inside each change, after reading and before writing, with
    /// the file's lock held, so a test can try another change there.
    package var whileHeld: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return heldHook }
        set { lock.lock(); heldHook = newValue; lock.unlock() }
    }

    /// How many are waiting for this file's lock now. For tests.
    package var waitingForFile: Int { fileLock.waiting }

    public func read() -> [String: Checkpoint]? {
        fileLock.lock()
        let loaded = load()
        fileLock.unlock()
        afterRead?()
        guard case .kept(let kept) = loaded else { return nil }
        return kept.checkpoints
    }

    public func checkpoint(_ taskID: String) -> KeptCheckpoint? {
        fileLock.lock()
        let loaded = load()
        fileLock.unlock()
        afterRead?()
        switch loaded {
        case .shut: return nil
        case .unreadable: return .unreadable
        case .kept(let kept):
            if kept.unreadable[taskID] != nil { return .unreadable }
            return kept.checkpoints[taskID].map(KeptCheckpoint.kept) ?? .missing
        }
    }

    public func update(_ edit: (inout [String: Checkpoint]) -> Void) -> Bool {
        change { kept in
            var all = kept.checkpoints
            edit(&all)
            // A record that can't be understood is never written over.
            guard kept.unreadable.keys.allSatisfy({ all[$0] == nil }) else { return false }
            kept.checkpoints = all
            return true
        }
    }

    /// Lets go of the task's record alone, even one that can't be
    /// understood, so forgetting the task is the way past it.
    public func remove(_ taskID: String) -> Bool {
        change { kept in
            kept.checkpoints[taskID] = nil
            kept.unreadable[taskID] = nil
            return true
        }
    }

    /// Reads the file, lets `body` change what it holds and writes it back,
    /// all with the lock held. False, with nothing written, when the file
    /// can't be read now, can't be understood at all, or `body` says no.
    private func change(_ body: (inout Kept) -> Bool) -> Bool {
        fileLock.lock()
        var done = false
        if case .kept(let before) = load() {
            var after = before
            let allowed = body(&after)
            whileHeld?()
            done = allowed && (after == before || store(after))
        }
        fileLock.unlock()
        afterRead?()
        return done
    }

    /// What the file holds: each task's checkpoint, and, just as they were
    /// written, the records that can't be understood.
    private struct Kept: Equatable {
        var checkpoints: [String: Checkpoint] = [:]
        var unreadable: [String: Data] = [:]
    }

    private enum Loaded {
        /// It can't be read now, as while the device is locked.
        case shut
        /// It is read but isn't a set of records at all.
        case unreadable
        case kept(Kept)
    }

    /// Reads the file, each task's record on its own, so one that can't be
    /// understood leaves the others readable. Nothing here ever deletes or
    /// changes the file. Called with the lock held.
    private func load() -> Loaded {
        if Self.isMissing(fileURL) { return .kept(Kept()) }
        guard let data = try? Data(contentsOf: fileURL) else { return .shut }
        guard let records = CheckpointRecords.split(data) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var kept = Kept()
        for (taskID, record) in records {
            if let checkpoint = try? decoder.decode(Checkpoint.self, from: record), checkpoint.taskID == taskID {
                kept.checkpoints[taskID] = checkpoint
            } else {
                kept.unreadable[taskID] = record
            }
        }
        return .kept(kept)
    }

    /// Writes the file whole, each record that can't be understood just as
    /// it was read. Called with the lock held.
    private func store(_ kept: Kept) -> Bool {
        let manager = FileManager.default
        // A file there that can't be read yet is never written over.
        if manager.fileExists(atPath: fileURL.path), !manager.isReadableFile(atPath: fileURL.path) { return false }
        if kept.checkpoints.isEmpty, kept.unreadable.isEmpty {
            try? manager.removeItem(at: fileURL)
            try? manager.removeItem(at: stagingURL)
            return [fileURL, stagingURL].allSatisfy(Self.isMissing)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var records = kept.unreadable
        for (taskID, checkpoint) in kept.checkpoints {
            guard let record = try? encoder.encode(checkpoint) else { return false }
            records[taskID] = record
        }
        guard let data = CheckpointRecords.join(records) else { return false }
        try? manager.removeItem(at: stagingURL)
        guard (try? data.write(to: stagingURL, options: Self.fileWriting())) != nil,
              rename(stagingURL.path, fileURL.path) == 0 else {
            try? manager.removeItem(at: stagingURL)
            return false
        }
        return true
    }

    /// A permission error is not proof of absence. lstat also sees dangling
    /// links, which fileExists would mistake for a missing file.
    private static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }
}

/// The checkpoint file is one JSON object, a record for each task. This
/// finds each record's own bytes, so one that can't be understood is
/// written back just as it was.
private struct CheckpointRecords {
    private let bytes: [UInt8]
    private var at = 0

    private init(_ data: Data) { bytes = [UInt8](data) }

    /// Each task's record, or nil when the file isn't one JSON object or
    /// names a task twice.
    static func split(_ data: Data) -> [String: Data]? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        var scan = CheckpointRecords(data)
        return scan.records()
    }

    /// The records as one JSON object, by task in order.
    static func join(_ records: [String: Data]) -> Data? {
        var data = Data("{".utf8)
        for (index, taskID) in records.keys.sorted().enumerated() {
            guard let key = try? JSONEncoder().encode(taskID), let record = records[taskID] else { return nil }
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data += key
            data.append(UInt8(ascii: ":"))
            data += record
        }
        data.append(UInt8(ascii: "}"))
        return data
    }

    private mutating func records() -> [String: Data]? {
        skipSpace()
        guard next == UInt8(ascii: "{") else { return nil }
        at += 1
        skipSpace()
        var records: [String: Data] = [:]
        if next == UInt8(ascii: "}") { return records }
        while true {
            skipSpace()
            let keyStart = at
            guard next == UInt8(ascii: "\""), skipString(),
                  let taskID = try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<at])) else { return nil }
            skipSpace()
            guard next == UInt8(ascii: ":") else { return nil }
            at += 1
            skipSpace()
            let start = at
            guard skipValue() else { return nil }
            var end = at
            while end > start, Self.isSpace(bytes[end - 1]) { end -= 1 }
            guard records.updateValue(Data(bytes[start..<end]), forKey: taskID) == nil else { return nil }
            skipSpace()
            switch next {
            case UInt8(ascii: "}"): return records
            case UInt8(ascii: ","): at += 1
            default: return nil
            }
        }
    }

    private var next: UInt8? { at < bytes.count ? bytes[at] : nil }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private mutating func skipSpace() {
        while let byte = next, Self.isSpace(byte) { at += 1 }
    }

    /// Moves past the string that starts here.
    private mutating func skipString() -> Bool {
        at += 1
        while let byte = next {
            at += byte == UInt8(ascii: "\\") ? 2 : 1
            if byte == UInt8(ascii: "\"") { return true }
        }
        return false
    }

    /// Moves to the end of the value that starts here: past its closing
    /// bracket, or up to the comma or brace after a plain value.
    private mutating func skipValue() -> Bool {
        var depth = 0
        while let byte = next {
            switch byte {
            case UInt8(ascii: "\""):
                guard skipString() else { return false }
                if depth == 0 { return true }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 { return true }
                depth -= 1
                if depth == 0 { at += 1; return true }
            case UInt8(ascii: ","):
                if depth == 0 { return true }
            default:
                break
            }
            at += 1
        }
        return false
    }
}

/// One lock for each checkpoint file, shared by every store for it in this
/// process, however its path is written. Kept for as long as the process
/// runs; there is one for each file, and only a few files.
private final class FileLock: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var all: [String: FileLock] = [:]

    static func shared(for fileURL: URL) -> FileLock {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock(); defer { lock.unlock() }
        if let kept = all[path] { return kept }
        let made = FileLock()
        all[path] = made
        return made
    }

    private let condition = NSCondition()
    private var held = false
    private var waits = 0

    /// How many are waiting for it now.
    var waiting: Int { condition.lock(); defer { condition.unlock() }; return waits }

    func lock() {
        condition.lock()
        while held {
            waits += 1
            condition.wait()
            waits -= 1
        }
        held = true
        condition.unlock()
    }

    func unlock() {
        condition.lock()
        held = false
        condition.signal()
        condition.unlock()
    }
}
