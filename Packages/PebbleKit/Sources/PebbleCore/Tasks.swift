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
    /// Steps recorded so far, counting those the history has let go. Each
    /// new step takes this as its number, so no two steps share an id.
    public private(set) var stepsRecorded: Int

    public static let historyLimit = 4

    public init(id: String, title: String, step: String, progress: TaskProgress = .indeterminate,
                state: TaskState = .running, history: [TaskStep] = [], question: ConfirmationRequest? = nil,
                wrapUp: TaskWrapUp? = nil, result: String? = nil, startedAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.step = step
        self.progress = progress
        self.state = state
        self.history = history.suffix(Self.historyLimit).enumerated().map { $1.numbered($0) }
        self.stepsRecorded = self.history.count
        self.question = question
        self.wrapUp = wrapUp
        self.result = result
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// Adds a step to the history, keeping only the last few. The step is
    /// numbered here, after every step before it.
    public mutating func record(_ step: TaskStep) {
        history.append(step.numbered(stepsRecorded))
        stepsRecorded += 1
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

    /// Steady while newer steps push in, and never shared by two steps of
    /// one task, even when the clock stands still and the words repeat. So
    /// a list keyed by it never shows one step's words in another's place.
    public var id: Int { number }

    public let text: String
    public let mark: Mark
    public let at: Date
    /// Where the step falls in its task, from zero. Set by `AgentTask.record`.
    public private(set) var number: Int

    public init(_ text: String, mark: Mark, at: Date) {
        self.text = text
        self.mark = mark
        self.at = at
        self.number = 0
    }

    func numbered(_ number: Int) -> TaskStep {
        var step = self
        step.number = number
        return step
    }
}

/// What a task left behind when it ended.
public struct TaskWrapUp: Sendable, Equatable {
    /// What the agent found or made and kept, such as "three dentists open Saturdays".
    public let kept: [String]
    /// What it didn't do, such as "hold a Saturday visit".
    public let notDone: [String]
    /// A step the person said yes to that was under way when the task
    /// stopped, such as "hold a Saturday visit". Neither kept nor not done:
    /// it may have happened.
    public let underway: String?

    public init(kept: [String], notDone: [String], underway: String? = nil) {
        self.kept = kept
        self.notDone = notDone
        self.underway = underway
    }

    /// "I kept a, b and c." or that nothing was kept yet.
    public var keptLine: String {
        kept.isEmpty ? TaskWords.keptNothing : TaskWords.kept(kept)
    }

    /// "I didn't a or b." Nil when everything was done.
    public var notDoneLine: String? {
        notDone.isEmpty ? nil : TaskWords.notDone(notDone)
    }

    /// "You said yes, so I'd already started to a. It may be done." Nil
    /// when nothing approved was under way.
    public var underwayLine: String? {
        underway.map(TaskWords.mayBeDone)
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
/// An engine never calls `AskFirst` while it holds a lock of its own. The
/// rule may one day tell others when a question opens or closes, and they
/// may call straight back into the engine.
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
    /// unchanged. A step already approved is committed: the yes stands, the
    /// action may be under way, so it finishes and is never called undone.
    /// False when the task has ended or the words are empty.
    ///
    /// `LocalFakeEngine` runs a script, so it can't act on the words: they go
    /// into the history and the script goes on as written. That is fine for
    /// a labelled example only. A real engine must work the words into what
    /// it does next, or say plainly that it couldn't.
    @discardableResult
    func redirect(_ id: String, with instructions: String) -> Bool

    /// Stops at once and says what was kept and what was not done. Any open
    /// question is withdrawn. A step already approved is never listed as not
    /// done: the wrap-up names it as `underway`, since it may have happened.
    /// False when the task had already ended.
    @discardableResult
    func stop(_ id: String) -> Bool

    /// Takes an ended task away, with everything it held: its steps, the
    /// words the person gave it and what it kept. False while it is still
    /// going, so it is stopped first.
    @discardableResult
    func dismiss(_ id: String) -> Bool

    /// Forgets every task at once. Wired to the same Forget everything as
    /// memory.
    ///
    /// The contract, which every engine keeps:
    /// - Anything still going stops at once, with no wrap-up, and any open
    ///   question is withdrawn.
    /// - Nothing a task held is kept: its steps, the words the person gave
    ///   it, what it kept, and what it found.
    /// - A step the person already said yes to may be under way, and a
    ///   forgotten task can't say so. So the engine counts those steps and
    ///   returns the count, and nothing else about them, for the caller to
    ///   tell the person it may be done. The engine never refuses to forget
    ///   because of them.
    @discardableResult
    func clear() -> ClearedTasks

    /// Tries a stuck task again. False unless it was stuck.
    @discardableResult
    func retry(_ id: String) -> Bool

    /// Goes on after a yes from the confirmation sheet for this task's open
    /// question. The engine checks it with `AskFirst.verdict` first, so a
    /// late, used or mismatched yes does nothing.
    func resume(_ id: String, with approval: Approval) -> TaskApproval

    /// The question was closed without a yes: Not now, Close, or the sheet
    /// went away. The task goes on without that step, and its line says
    /// the person closed it, or that it timed out if the rule says so.
    func questionClosed(_ request: ConfirmationRequest)

    /// Looks again at anything that changes with time, such as a question
    /// that timed out.
    func refresh()

    /// True when the tasks are scripted examples and nothing is really
    /// done, so the feed labels them like every other example.
    var isSample: Bool { get }

    /// The tasks this engine can start, for Today to offer.
    var builtIns: [TaskRequest] { get }

    /// True while the engine keeps a file of its tasks on disk, so Forget
    /// everything is offered while there is anything to erase.
    var hasStoredFile: Bool { get }

    /// Called once `note` is forgotten, so nothing the engine kept still
    /// quotes it. Says whether every copy of its words is gone.
    func forgetQuotes(of note: MemoryNote) -> QuotesForgotten
}

extension TaskEngine {
    public var isSample: Bool { false }
    public var builtIns: [TaskRequest] { [] }
    public var hasStoredFile: Bool { false }
    public func forgetQuotes(of note: MemoryNote) -> QuotesForgotten { .notQuoted }
}

/// What became of a forgotten note's words in what a task kept, such as a
/// weekly digest.
public enum QuotesForgotten: Sendable, Equatable {
    /// Nothing a task kept quoted it.
    case notQuoted
    /// Every copy is gone: the line was taken out, or the digest removed.
    case forgotten
    /// Some of its words are still in a kept note, as when the person
    /// changed the digest or it couldn't be written just now.
    case stayed
}

/// What forgetting every task left behind: counts only, so nothing a task
/// held outlives it.
public struct ClearedTasks: Sendable, Equatable {
    /// Tasks forgotten, ended or not.
    public let forgotten: Int
    /// Steps the person had said yes to that were under way, so may be done.
    public let underway: Int
    /// False when the engine's file of tasks couldn't be erased. The tasks
    /// stopped and left the screen, but may come back next launch, so the
    /// person is told and can try again.
    public let erased: Bool

    public init(forgotten: Int = 0, underway: Int = 0, erased: Bool = true) {
        self.forgotten = forgotten
        self.underway = underway
        self.erased = erased
    }

    public static let none = ClearedTasks()

    /// The line to keep on screen once the tasks are gone, or nil when no
    /// step said yes to was under way. It names nothing the task held.
    public var underwayLine: String? {
        underway > 0 ? TaskWords.forgotUnderway(underway) : nil
    }
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
/// that ends, is said straight away, and so is one the person just started.
public struct TaskAnnouncer: Sendable {
    public static let minimumGap: Duration = .seconds(4)

    private struct Heard: Equatable {
        let state: TaskState
        let step: String
    }

    private var heard: [String: Heard] = [:]
    /// What was last said for each task, so a line is never said twice.
    private var said: [String: Heard] = [:]
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
            // A task that already ended says nothing more when only its
            // line changes, as when the person removes what it kept: they
            // did it, so they know.
            if let before, before.state == task.state, task.state.isFinished { continue }
            let line = Self.line(for: task)
            if Self.isUrgent(task.state) && before?.state != task.state {
                waiting[task.id] = nil
                said[task.id] = current
                out.append(Line(text: line, urgent: true))
            } else {
                waiting[task.id] = line
            }
        }
        // Tasks that went away have nothing left to say.
        let ids = Set(tasks.map(\.id))
        waiting = waiting.filter { ids.contains($0.key) }
        heard = heard.filter { ids.contains($0.key) }
        said = said.filter { ids.contains($0.key) }

        if !out.isEmpty {
            lastSpoken = now
            return out
        }
        if let lastSpoken, now - lastSpoken < Self.minimumGap { return [] }
        guard let next = tasks.first(where: { waiting[$0.id] != nil }), let text = waiting[next.id] else { return [] }
        waiting[next.id] = nil
        said[next.id] = heard[next.id]
        lastSpoken = now
        return [Line(text: text, urgent: false)]
    }

    /// The line for a task the person just started, said at once rather
    /// than waiting its turn: the button they were on is gone, so this is
    /// how they hear it began. Nil when that line was already said.
    public mutating func started(_ task: AgentTask, at now: ContinuousClock.Instant) -> Line? {
        let current = Heard(state: task.state, step: task.step)
        heard[task.id] = current
        waiting[task.id] = nil
        guard said[task.id] != current else { return nil }
        said[task.id] = current
        lastSpoken = now
        return Line(text: Self.line(for: task), urgent: true)
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
    /// New instructions for a step the person already said yes to. The yes
    /// stands and the step may be under way, so it is finished, not dropped.
    public static let finishingApproved = "You'd already said yes to this, so I'm finishing it."
    /// A step the person said yes to, under way when they stopped the task.
    public static func mayBeDone(_ todo: String) -> String { "You said yes, so I'd already started to \(todo). It may be done." }
    /// A yes from the sheet the task couldn't use. Nothing was done with it.
    public static let yesNotUsed = "That yes didn't go through, so I didn't act on it."
    /// Approve tapped after the question timed out on screen. Nothing was done.
    public static let questionTimedOut = "That question timed out, so I didn't act on it."

    /// Forgetting tasks when the notes can't be opened, so Forget everything
    /// isn't there. Honest that the notes stay.
    ///
    /// The detail says "this device" without asking `PrivacyPlace`, like
    /// `MemoryWords.forgetEverythingDetail`: it says where the tasks are
    /// erased from, not that nothing ever left, so it is true with a cloud
    /// model too. Any line that promises words stay here must be gated.
    public static let forgetTasksTitle = "Forget all tasks"
    public static let forgetTasksQuestion = "Forget all tasks?"
    public static let forgetTasksDetail = "This stops any task still going, and removes every task and what you told me for it from this device. It can't be undone. Your notes aren't touched."
    /// Said and shown once the tasks are gone.
    public static let tasksForgotten = "Your tasks are forgotten."
    /// Forgetting tasks when their file couldn't be erased. They stopped
    /// and left the screen, but may come back, so it says so.
    public static let forgotNotesNotTasks = "Your notes are gone. I stopped your tasks, but I couldn't erase them just now. Please try Forget everything again in a moment."
    public static let couldNotEraseTasks = "I stopped your tasks, but I couldn't erase them just now. Please try Forget everything again in a moment."
    /// Kept on Today after forgetting, while a step the person said yes to
    /// may have happened. Names nothing the task held.
    public static func forgotUnderway(_ count: Int) -> String {
        count == 1
            ? "You'd said yes to a step that was already under way when I forgot your tasks. It may be done."
            : "You'd said yes to some steps that were already under way when I forgot your tasks. They may be done."
    }
    public static let forgotUnderwayDismissTitle = "Got it"

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
