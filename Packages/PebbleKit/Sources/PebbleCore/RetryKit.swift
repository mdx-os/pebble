import Foundation

// The retry kit: what a step's failure means, how long to wait before the
// next try, the key that marks every try of a step as the same request, and
// the limit that ends a step that hangs. Pure logic. Time comes from an
// injected clock and sleeper, so a run can be tested without waiting.
// `CheckpointRunner` puts the pieces together. See docs/RETRY.md.

/// Why a step's try didn't work. Transient ones are tried again, up to
/// `BackoffPolicy.maxTries`; the rest end the run on the first try.
public enum StepFailure: Error, Codable, Sendable, Equatable {
    /// The connection went away partway.
    case dropped
    /// The try ran past its step's limit and was let go.
    case timedOut
    /// Too many requests (429): come back later, maybe after `retryAfter`.
    case busy(retryAfter: String?)
    /// The far side had trouble of its own (5xx), maybe with a `retryAfter`.
    case serverTrouble(retryAfter: String?)
    /// The far side said no, and asking again won't change that.
    case refused
    /// The request itself was wrong (400 and the like).
    case badRequest
    /// Not allowed (401, 403), or a permission the person hasn't given.
    case notAllowed
    /// The step threw something that isn't a `StepFailure`.
    case unexpected
    /// The run couldn't keep its checkpoint, so it stops rather than run
    /// ahead of what it could pick up again.
    case notSaved
    /// The kept checkpoint says a place this run can't have reached, so its
    /// progress can't be read. Nothing runs until it is forgotten.
    case unreadable

    /// True when trying again might work.
    public var isTransient: Bool {
        switch self {
        case .dropped, .timedOut, .busy, .serverTrouble: true
        case .refused, .badRequest, .notAllowed, .unexpected, .notSaved, .unreadable: false
        }
    }

    /// The Retry-After value the far side sent, as it sent it.
    public var retryAfter: String? {
        switch self {
        case .busy(let retryAfter), .serverTrouble(let retryAfter): retryAfter
        default: nil
        }
    }

    /// What an HTTP status means for a step, with the Retry-After value
    /// that came with it. Nil for a status that isn't a failure.
    public static func status(_ code: Int, retryAfter: String? = nil) -> StepFailure? {
        switch code {
        case 200..<400: nil
        case 408: .timedOut
        case 429: .busy(retryAfter: retryAfter)
        case 401, 403: .notAllowed
        case 400, 404, 405, 406, 410, 411, 413, 414, 415, 422: .badRequest
        case 501, 505: .refused
        case 500..<600: .serverTrouble(retryAfter: retryAfter)
        default: .refused
        }
    }
}

/// A Retry-After value: a number of seconds, or an HTTP date.
public enum RetryAfter {
    /// How many seconds from `now` the value asks to wait, never below
    /// zero. Nil when it is neither a number of seconds nor an HTTP date.
    public static func seconds(_ value: String, now: Date) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, text.allSatisfy(\.isASCIIDigit) {
            return TimeInterval(text)
        }
        guard let date = date(text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// The three date forms HTTP allows, preferred first.
    private static let dateForms = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    private static func date(_ text: String) -> Date? {
        for form in dateForms {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = form
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// How often a step is tried and how long to wait between tries.
public struct BackoffPolicy: Sendable, Equatable {
    /// Tries in all, the first one included. Never fewer than one.
    public let maxTries: Int
    /// The wait before the second try, doubled for each try after it.
    public let baseDelay: TimeInterval
    /// The longest the doubling ever waits.
    public let maxDelay: TimeInterval
    /// The longest a Retry-After value is waited for.
    public let maxRetryAfter: TimeInterval

    public init(maxTries: Int = 4, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60,
                maxRetryAfter: TimeInterval = 300) {
        self.maxTries = max(1, maxTries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.maxRetryAfter = max(0, maxRetryAfter)
    }

    public static let standard = BackoffPolicy()

    /// How long to wait after try number `tryNumber` (from one) failed
    /// with `failure`. A Retry-After value is honoured, up to
    /// `maxRetryAfter`. Otherwise the wait doubles from `baseDelay` up to
    /// `maxDelay`, and `random` (from zero to one) picks a point in its
    /// upper half, so many runs that failed together don't all come back
    /// at once.
    public func delay(afterTry tryNumber: Int, failure: StepFailure, now: Date, random: Double) -> TimeInterval {
        if let value = failure.retryAfter, let wait = RetryAfter.seconds(value, now: now) {
            return min(maxRetryAfter, wait)
        }
        let doublings = Double(max(0, tryNumber - 1))
        let full = min(maxDelay, baseDelay * pow(2, min(doublings, 62)))
        let spread = min(1, max(0, random.isFinite ? random : 0))
        return full / 2 + full / 2 * spread
    }
}

/// The key every try of one step carries, so a far side that sees the same
/// request twice can tell it is the same one. Made from the task and the
/// step's place in it, never from the time: the same on every retry, and
/// after the run is picked up again.
public struct IdempotencyKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public let value: String

    public init(taskID: String, step: Int) {
        value = "\(taskID):\(step)"
    }

    public var description: String { value }
}

/// Where a run's time comes from.
public protocol RunClock: Sendable {
    var now: Date { get }
}

/// Why a run is waiting.
public enum RunWait: Sendable, Equatable {
    /// Between two tries of a step.
    case backoff
    /// A step's limit. The step is let go once this ends.
    case limit
}

/// Waits for a run. Throws once the waiting task is cancelled.
public protocol RunSleeper: Sendable {
    func sleep(_ seconds: TimeInterval, for wait: RunWait) async throws
}

/// The device's own clock.
public struct SystemRunClock: RunClock {
    public init() {}
    public var now: Date { Date() }
}

/// Waits on the device's own clock.
public struct SystemRunSleeper: RunSleeper {
    public init() {}

    public func sleep(_ seconds: TimeInterval, for wait: RunWait) async throws {
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

/// How one try of a step ended.
enum StepTry: Sendable, Equatable {
    case finished(StepResult)
    case failed(StepFailure)
    /// The run was cancelled while the try was under way.
    case cancelled
}

enum StepLimit {
    /// Runs `body` until it ends or `limit` seconds pass on `sleeper`,
    /// whichever comes first. A try past its limit ends as timed out and is
    /// cancelled, and this returns at once even if it never stops: a step
    /// can't hang its run.
    static func run(limit: TimeInterval, sleeper: any RunSleeper,
                    _ body: @escaping @Sendable () async throws -> StepResult) async -> StepTry {
        let first = FirstOf()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                first.wait(continuation)
                first.hold(Task {
                    // The limit starts once the try is under way, never
                    // before it.
                    first.hold(Task {
                        guard (try? await sleeper.sleep(limit, for: .limit)) != nil else { return }
                        first.finish(.failed(.timedOut))
                    })
                    do {
                        first.finish(.finished(try await body()))
                    } catch let failure as StepFailure {
                        first.finish(.failed(failure))
                    } catch is CancellationError {
                        first.finish(.cancelled)
                    } catch {
                        first.finish(.failed(.unexpected))
                    }
                })
            }
        } onCancel: {
            first.finish(.cancelled)
        }
    }
}

/// The first of several ways a try can end, told once. The rest are
/// cancelled.
private final class FirstOf: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StepTry, Never>?
    private var ended: StepTry?
    private var tasks: [Task<Void, Never>] = []

    func wait(_ next: CheckedContinuation<StepTry, Never>) {
        lock.lock()
        if let ended {
            lock.unlock()
            next.resume(returning: ended)
            return
        }
        continuation = next
        lock.unlock()
    }

    func hold(_ task: Task<Void, Never>) {
        lock.lock()
        guard ended == nil else {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    func finish(_ end: StepTry) {
        lock.lock()
        guard ended == nil else {
            lock.unlock()
            return
        }
        ended = end
        let waiting = continuation
        continuation = nil
        let running = tasks
        tasks = []
        lock.unlock()
        for task in running { task.cancel() }
        waiting?.resume(returning: end)
    }
}
