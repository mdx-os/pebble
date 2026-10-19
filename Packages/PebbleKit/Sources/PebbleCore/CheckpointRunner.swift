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

/// Where checkpoints are kept, one for each task. Reading may not be
/// possible yet, as while the device is locked, and then nothing
/// is written either.
public protocol CheckpointStoring: AnyObject, Sendable {
    /// Every checkpoint kept, by task, or nil while they can't be read.
    func read() -> [String: Checkpoint]?
    /// Reads every checkpoint, lets `edit` change them and keeps the result,
    /// all in one go, so no other change can land in between and be lost.
    /// `edit` never touches the store. False when they couldn't be read or
    /// written now, and then nothing changed.
    @discardableResult
    func update(_ edit: (inout [String: Checkpoint]) -> Void) -> Bool
}

extension CheckpointStoring {
    /// The checkpoint for `taskID`. Nil inside when there is none; nil
    /// outside while they can't be read.
    public func checkpoint(_ taskID: String) -> Checkpoint?? {
        guard let all = read() else { return nil }
        return .some(all[taskID])
    }

    /// Keeps `checkpoint` beside the others. False when it couldn't be kept.
    @discardableResult
    public func save(_ checkpoint: Checkpoint) -> Bool {
        update { $0[checkpoint.taskID] = checkpoint }
    }

    /// Lets go of the checkpoint for `taskID`. False when it couldn't.
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
        guard let kept = store.checkpoint(taskID) else {
            return .failed(step: unkept?.ended.map(endingStep) ?? 0, reason: .notSaved)
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
/// read yet is never written over. Every store for one file in this process
/// shares one lock, so two of them never lose each other's changes.
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
        let all = load()
        fileLock.unlock()
        afterRead?()
        return all
    }

    public func update(_ edit: (inout [String: Checkpoint]) -> Void) -> Bool {
        fileLock.lock()
        var kept = false
        if let before = load() {
            var all = before
            edit(&all)
            whileHeld?()
            kept = all == before || store(all)
        }
        fileLock.unlock()
        afterRead?()
        return kept
    }

    /// Reads the file. Called with the lock held.
    private func load() -> [String: Checkpoint]? {
        if Self.isMissing(fileURL) { return [:] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let checkpoints = try? decoder.decode([String: Checkpoint].self, from: data) else {
            // Nothing could ever read it back, so it goes. A run started
            // again from the top still sends each step with its own key.
            try? FileManager.default.removeItem(at: fileURL)
            return Self.isMissing(fileURL) ? [:] : nil
        }
        return checkpoints
    }

    /// Writes the file whole. Called with the lock held.
    private func store(_ checkpoints: [String: Checkpoint]) -> Bool {
        let manager = FileManager.default
        // A file there that can't be read yet is never written over.
        if manager.fileExists(atPath: fileURL.path), !manager.isReadableFile(atPath: fileURL.path) { return false }
        if checkpoints.isEmpty {
            try? manager.removeItem(at: fileURL)
            try? manager.removeItem(at: stagingURL)
            return [fileURL, stagingURL].allSatisfy(Self.isMissing)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(checkpoints) else { return false }
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
