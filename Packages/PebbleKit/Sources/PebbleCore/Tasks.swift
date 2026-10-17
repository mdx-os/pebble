import Foundation

/// Something the agent is working on that takes a while, as a live card in
/// the Today feed shows it. A snapshot: the engine makes a new one each time
/// anything changes.
///
/// Named `AgentTask` so it never shadows Swift's own `Task`.
public struct AgentTask: Identifiable, Sendable, Equatable {
    public let id: String
    /// What the person asked for, in their words, such as "Find a dentist
    /// near you open Saturdays".
    public let title: String
    /// What the agent is doing right now, in plain words.
    public var step: String
    public var progress: TaskProgress
    public var state: TaskState
    /// The last few steps, oldest first. Never longer than `historyLimit`.
    public var history: [TaskStep]
    /// The question the agent is waiting on, from `AskFirst`. Only set while
    /// the state is `.waitingOnYou` for an approval.
    public var question: ConfirmationRequest?
    /// What was kept and what was not done, once the task has ended.
    public var wrapUp: TaskWrapUp?
    /// The finished result to read, once the task is done.
    public var result: String?
    public let startedAt: Date
    public var updatedAt: Date

    public static let historyLimit = 4

    public init(id: String, title: String, step: String, progress: TaskProgress = .indeterminate,
                state: TaskState = .running, history: [TaskStep] = [], question: ConfirmationRequest? = nil,
                wrapUp: TaskWrapUp? = nil, result: String? = nil, startedAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.step = step
        self.progress = progress
        self.state = state
        self.history = Array(history.suffix(Self.historyLimit))
        self.question = question
        self.wrapUp = wrapUp
        self.result = result
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// Adds a step to the history, keeping only the last few.
    public mutating func record(_ step: TaskStep) {
        history.append(step)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// True while the agent may still do something on this task.
    public var isActive: Bool { !state.isFinished }

    /// Waiting for a yes from `AskFirst`, so the card can offer Approve.
    public var waitsForApproval: Bool { state == .waitingOnYou && question != nil }

    /// Stuck after its retries ran out, so the card offers Try again.
    public var isStuck: Bool { state == .waitingOnYou && question == nil }

    /// The task as the feed holds it: everything but live progress, which a
    /// card reads from the engine. A tick of progress then never changes the
    /// feed, so it never redraws every card. Keeps only whether progress can
    /// be told at all.
    public var card: AgentTask {
        var card = self
        card.progress = progress.fraction == nil ? .indeterminate : .fraction(0)
        return card
    }

    /// How VoiceOver reads the progress.
    public var spokenProgress: String {
        switch progress {
        case .indeterminate: TaskWords.stillWorking
        case .fraction(let done): TaskWords.percentDone(Int((done * 100).rounded()))
        }
    }
}

/// How far along a task is.
public enum TaskProgress: Sendable, Equatable {
    /// The agent can't tell how much is left.
    case indeterminate
    /// From 0 to 1.
    case fraction(Double)

    public var fraction: Double? {
        if case .fraction(let value) = self { return min(1, max(0, value)) }
        return nil
    }
}

public enum TaskState: String, Sendable, Equatable, CaseIterable {
    /// Working through its steps.
    case running
    /// Needs the person: a yes from `AskFirst`, or a choice after the
    /// retries ran out.
    case waitingOnYou
    /// A step took too long. The agent is about to try another way.
    case stalled
    /// Trying a step again, another way.
    case retrying
    case done
    /// The person stopped it.
    case stopped
    /// The agent couldn't finish it.
    case failed

    public var isFinished: Bool { self == .done || self == .stopped || self == .failed }

    /// The small label on the card.
    public var label: String {
        switch self {
        case .running: TaskWords.runningLabel
        case .waitingOnYou: FeedWords.needsYouHeading
        case .stalled: TaskWords.stalledLabel
        case .retrying: TaskWords.retryingLabel
        case .done: FeedWords.didLabel
        case .stopped: TaskWords.stoppedLabel
        case .failed: TaskWords.failedLabel
        }
    }
}

/// One line in a task's history.
public struct TaskStep: Sendable, Hashable {
    public enum Mark: String, Sendable, Hashable {
        /// A step finished.
        case done
        /// A step finished, after it was slow and the agent tried another way.
        case retried
        /// The person gave new instructions.
        case redirected
        /// A step was left undone: a no, a timeout, or a question that couldn't be asked.
        case skipped
        /// The person said yes.
        case approved
    }

    /// Steady while newer steps push in, so a list keyed by it never shows
    /// one step's words in another step's place.
    public var id: String { "\(at.timeIntervalSinceReferenceDate)|\(text)" }

    public let text: String
    public let mark: Mark
    public let at: Date

    public init(_ text: String, mark: Mark, at: Date) {
        self.text = text
        self.mark = mark
        self.at = at
    }
}

/// What a task left behind when it ended.
public struct TaskWrapUp: Sendable, Equatable {
    /// What the agent found or made and kept, such as "three dentists open Saturdays".
    public let kept: [String]
    /// What it didn't do, such as "hold a Saturday visit".
    public let notDone: [String]

    public init(kept: [String], notDone: [String]) {
        self.kept = kept
        self.notDone = notDone
    }

    /// "I kept a, b and c." or that nothing was kept yet.
    public var keptLine: String {
        kept.isEmpty ? TaskWords.keptNothing : TaskWords.kept(kept)
    }

    /// "I didn't a or b." Nil when everything was done.
    public var notDoneLine: String? {
        notDone.isEmpty ? nil : TaskWords.notDone(notDone)
    }
}

/// What the person asks the agent to work on.
public struct TaskRequest: Sendable, Equatable {
    public let title: String
    public let instructions: String

    public init(title: String, instructions: String = "") {
        self.title = title
        self.instructions = instructions
    }
}

/// What came of a yes handed to a task.
public enum TaskApproval: Sendable, Equatable {
    /// `AskFirst` honored it and the task goes on.
    case proceeding
    /// The yes came too late. Nothing was done.
    case timedOut
    /// Not for this task's open question, already used, or not the question
    /// that was asked. Nothing was done.
    case refused
}

/// Does long work for the person and reports each step.
///
/// An engine never approves anything itself. When a step would send, buy or
/// share, it asks through `AskFirst` and waits; only a yes from the
/// confirmation sheet, checked by `AskFirst.verdict`, lets it go on.
/// Redirect and stop never need a yes. Stop is immediate.
///
/// `LocalFakeEngine` runs scripted tasks on a clock tests control. A real
/// engine (Forge) plugs in here later; any networking stays outside
/// `PebbleCore`.
public protocol TaskEngine: AnyObject, Sendable {
    /// The rule every question is asked through. Its yes is the only way on.
    var rule: AskFirst { get }

    /// Every task, newest first.
    var tasks: [AgentTask] { get }

    /// Begins work. Returns the task's id.
    @discardableResult
    func start(_ request: TaskRequest) -> String

    /// Calls `onChange` now and after every change, until the observation
    /// is cancelled or released. Each snapshot's `sequence` is higher than
    /// the one before, so a listener that hops threads can drop one that
    /// arrives late.
    func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation

    /// New instructions for a task still going. Never needs a yes. A step
    /// waiting on a yes is withdrawn and left undone, since the question no
    /// longer matches what the person asked for; it is never asked again
    /// unchanged. False when the task has ended or the words are empty.
    @discardableResult
    func redirect(_ id: String, with instructions: String) -> Bool

    /// Stops at once and says what was kept and what was not done. Any open
    /// question is withdrawn. False when the task had already ended.
    @discardableResult
    func stop(_ id: String) -> Bool

    /// Takes an ended task away, with everything it held: its steps, the
    /// words the person gave it and what it kept. False while it is still
    /// going, so it is stopped first.
    @discardableResult
    func dismiss(_ id: String) -> Bool

    /// Forgets every task at once. Anything still going stops, any open
    /// question is withdrawn, and nothing a task held is kept. Wired to the
    /// same Forget everything as memory.
    func clear()

    /// Tries a stuck task again. False unless it was stuck.
    @discardableResult
    func retry(_ id: String) -> Bool

    /// Goes on after a yes from the confirmation sheet for this task's open
    /// question. The engine checks it with `AskFirst.verdict` first, so a
    /// late, used or mismatched yes does nothing.
    func resume(_ id: String, with approval: Approval) -> TaskApproval

    /// The question was closed without a yes: Not now, Close, or the sheet
    /// went away. The task goes on without that step.
    func questionClosed(_ request: ConfirmationRequest)

    /// Looks again at anything that changes with time, such as a question
    /// that timed out.
    func refresh()

    /// True when the tasks are scripted examples and nothing is really
    /// done, so the feed labels them like every other example.
    var isSample: Bool { get }
}

extension TaskEngine {
    public var isSample: Bool { false }
}

/// Every task at one moment, numbered so a late arrival can be told apart.
public struct TaskSnapshot: Sendable, Equatable {
    /// Goes up with every change the engine reports.
    public let sequence: Int
    /// Every task, newest first.
    public let tasks: [AgentTask]

    public init(sequence: Int, tasks: [AgentTask]) {
        self.sequence = sequence
        self.tasks = tasks
    }
}

/// Keeps an observation alive. Cancelling, or letting it go, stops the calls.
public final class TaskObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let cancel = onCancel
        onCancel = nil
        lock.unlock()
        cancel?()
    }

    deinit { cancel() }
}

/// Decides what VoiceOver says as tasks move, so it is told about new steps
/// politely and never about every tick of progress.
///
/// The first look is silent: what is already on screen can be read by
/// moving through it. After that a new step or state is said once, with at
/// least `minimumGap` between lines. A step that arrives too soon waits, and
/// only the newest waiting step is said. A task that needs the person, or
/// that ends, is said straight away.
public struct TaskAnnouncer: Sendable {
    public static let minimumGap: Duration = .seconds(4)

    private struct Heard: Equatable {
        let state: TaskState
        let step: String
    }

    private var heard: [String: Heard] = [:]
    private var waiting: [String: String] = [:]
    private var lastSpoken: ContinuousClock.Instant?
    private var primed = false

    public init() {}

    /// A line to say, and whether it is urgent enough to say over anything else.
    public struct Line: Sendable, Equatable {
        public let text: String
        public let urgent: Bool

        public init(text: String, urgent: Bool) {
            self.text = text
            self.urgent = urgent
        }
    }

    public mutating func lines(for tasks: [AgentTask], at now: ContinuousClock.Instant) -> [Line] {
        defer { primed = true }
        var out: [Line] = []
        for task in tasks {
            let current = Heard(state: task.state, step: task.step)
            let before = heard[task.id]
            heard[task.id] = current
            guard primed else { continue }
            guard before != current else { continue }
            let line = Self.line(for: task)
            if Self.isUrgent(task.state) && before?.state != task.state {
                waiting[task.id] = nil
                out.append(Line(text: line, urgent: true))
            } else {
                waiting[task.id] = line
            }
        }
        // Tasks that went away have nothing left to say.
        let ids = Set(tasks.map(\.id))
        waiting = waiting.filter { ids.contains($0.key) }
        heard = heard.filter { ids.contains($0.key) }

        if !out.isEmpty {
            lastSpoken = now
            return out
        }
        if let lastSpoken, now - lastSpoken < Self.minimumGap { return [] }
        guard let next = tasks.first(where: { waiting[$0.id] != nil }), let text = waiting[next.id] else { return [] }
        waiting[next.id] = nil
        lastSpoken = now
        return [Line(text: text, urgent: false)]
    }

    static func isUrgent(_ state: TaskState) -> Bool {
        state == .waitingOnYou || state.isFinished
    }

    /// "Find a dentist near you open Saturdays. Checking Saturday hours."
    static func line(for task: AgentTask) -> String {
        let title = task.title.hasSuffix(".") ? task.title : task.title + "."
        return "\(title) \(task.step)"
    }
}

/// Words for task cards.
public enum TaskWords {
    public static let workingHeading = "Working on it"
    public static let workingDetail = "You can change course or stop me at any time."
    /// Not the same as `workingHeading`, so VoiceOver doesn't say it twice in a row.
    public static let runningLabel = "On it"
    public static let stalledLabel = "Taking a moment"
    public static let retryingLabel = "Trying another way"
    public static let stoppedLabel = "Stopped"
    public static let failedLabel = "Couldn't finish"

    public static let stalled = "This step is slow. I'll try another way in a moment."
    public static let retrying = "That was slow, so I'm trying another way."
    public static let stuck = "I couldn't get past this step after a few tries. Want me to try again, or try something else?"
    public static let waitingForYes = "I'll wait for your yes before I go on."
    public static let redirected = "Got it. I'm working that in now."
    public static let stopped = "I stopped, as you asked."
    public static let failed = "Sorry, I couldn't finish this."
    public static let keptNothing = "I hadn't kept anything yet."
    public static let stillWorking = "Still working"

    public static let approveTitle = "Check and approve"
    public static let redirectTitle = "Change course"
    public static let redirectPlaceholder = "What should I do instead?"
    public static let redirectSendTitle = "Send"
    public static let redirectCancelTitle = "Cancel"
    public static let stopTitle = "Stop"
    public static let tryAgainTitle = "Try again"
    /// Takes an ended card away, with everything it held.
    public static let dismissTitle = "Clear"

    /// The history line for new instructions.
    public static func youSaid(_ words: String) -> String { "You said: \(words)" }
    public static let youSaidYes = "You said yes."
    /// A step that finished after a slow try, such as "Found another way to check Saturday hours."
    public static func tookAnotherWay(_ todo: String) -> String { "Found another way to \(todo)." }
    /// True for Not now and for a sheet swiped away alike.
    public static func declined(_ todo: String) -> String { "You closed the question, so I didn't \(todo)." }
    /// A step that needed a yes, left undone for new instructions rather
    /// than asked as it was.
    public static func changedCourse(_ todo: String) -> String { "You changed course, so I didn't \(todo)." }
    public static func timedOut(_ todo: String) -> String { "That question timed out, so I didn't \(todo)." }
    public static func couldNotAsk(_ todo: String) -> String { "I couldn't ask about this clearly, so I didn't \(todo)." }

    public static func percentDone(_ percent: Int) -> String { "\(percent) percent done" }
    public static func kept(_ things: [String]) -> String { "I kept \(list(things, joiner: "and"))." }
    public static func notDone(_ things: [String]) -> String { "I didn't \(list(things, joiner: "or"))." }

    /// "a", "a and b", "a, b and c".
    static func list(_ things: [String], joiner: String) -> String {
        switch things.count {
        case 0: return ""
        case 1: return things[0]
        default: return things.dropLast().joined(separator: ", ") + " \(joiner) " + things[things.count - 1]
        }
    }
}
