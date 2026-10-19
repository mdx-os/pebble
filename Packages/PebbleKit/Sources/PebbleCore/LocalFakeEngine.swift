import Foundation

/// A scripted task for `LocalFakeEngine`: its steps, how long each takes,
/// and where it gets slow or needs a yes.
public struct TaskScript: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Works, after `stalls` tries that hang past the timeout.
            case work(stalls: Int)
            /// Asks `AskFirst` about this action and waits for a yes. With
            /// `askLine` as the step while it waits.
            case ask(ProposedAction, askLine: String)
            /// Can't be done at all.
            case fails
        }

        /// What the agent is doing, such as "Checking which ones open on Saturdays".
        public let text: String
        public let kind: Kind
        /// How long the step takes when it works, in seconds.
        public let duration: TimeInterval
        /// What this step leaves behind, such as "three dentists open Saturdays".
        public let kept: String?
        /// What the step does, to finish "I didn't ...", such as "check Saturday hours".
        public let todo: String
        /// The step while the agent waits to try again.
        public let slowLine: String
        /// The step while the agent tries again.
        public let retryLine: String

        public init(_ text: String, kind: Kind = .work(stalls: 0), duration: TimeInterval = 6,
                    kept: String? = nil, todo: String,
                    slowLine: String = TaskWords.stalled, retryLine: String = TaskWords.retrying) {
            self.text = text
            self.kind = kind
            self.duration = duration
            self.kept = kept
            self.todo = todo
            self.slowLine = slowLine
            self.retryLine = retryLine
        }
    }

    public let title: String
    public let steps: [Step]
    /// True when the agent can say how far along it is.
    public let determinate: Bool
    /// The step once everything is done, such as "I found three dentists open Saturdays."
    public let doneLine: String
    /// The finished result to read.
    public let result: String?
    /// What the finished task says shows its result. Scripted, so nothing
    /// here was really read or made.
    public let proofs: [TaskProof]

    public init(title: String, steps: [Step], determinate: Bool = true, doneLine: String, result: String? = nil,
                proofs: [TaskProof] = []) {
        self.title = title
        self.steps = steps
        self.determinate = determinate
        self.doneLine = doneLine
        self.result = result
        self.proofs = proofs
    }
}

/// How the engine recovers when a step hangs.
public struct RetryPolicy: Sendable, Equatable {
    /// How long a step may run before it counts as stalled.
    public let timeout: TimeInterval
    /// Tries after the first, before the agent asks the person.
    public let maxRetries: Int
    /// The wait before the first retry. Doubles each time, up to `maxBackoff`.
    public let backoff: TimeInterval
    public let maxBackoff: TimeInterval

    public init(timeout: TimeInterval = 20, maxRetries: Int = 2, backoff: TimeInterval = 2, maxBackoff: TimeInterval = 30) {
        self.timeout = timeout
        self.maxRetries = max(0, maxRetries)
        self.backoff = backoff
        self.maxBackoff = maxBackoff
    }

    public static let standard = RetryPolicy()

    /// The wait before retry number `retry`, counting from zero.
    public func delay(beforeRetry retry: Int) -> TimeInterval {
        min(maxBackoff, backoff * pow(2, Double(retry)))
    }
}

/// Runs scripted tasks on a clock the caller moves, so tests never sleep.
/// Nothing here reaches the network, and nothing is really done: the
/// showcase labels its cards as examples.
///
/// Time moves only through `advance(by:)`. The app's showcase calls it
/// with real time; tests call it with whatever they like.
public final class LocalFakeEngine: KeepsTasks, @unchecked Sendable {
    private enum Phase: Equatable {
        /// Trying the current step. `attempt` counts from zero.
        case working(attempt: Int, since: TimeInterval)
        /// Waiting `until` before trying again. `attempt` is the try to come.
        case waitingToRetry(attempt: Int, until: TimeInterval)
        /// At an ask step, before `AskFirst` has been asked. The question is
        /// asked once the lock is let go.
        case toAsk
        /// `AskFirst` is being asked, outside the lock.
        case asking
        case askingYes(ConfirmationRequest)
        /// Retries ran out; the person decides.
        case stuck
        case ended
    }

    private struct Run {
        var task: AgentTask
        let script: TaskScript
        var index: Int
        var phase: Phase
        /// Hanging tries left for each step, by index.
        var stallsLeft: [Int]
        var kept: [String] = []
        var notDone: [String] = []
        /// The current step is one the person said yes to. It is committed:
        /// a redirect lets it finish, and a stop never calls it undone.
        var approved = false
        /// What the person said yes to, and when, for the step's receipt.
        var approvedAction: ProposedAction?
        var approvedAt: Date?
        /// When the open question was first asked, as the card's clock tells it.
        var askedAt: Date?
        /// For a question picked up after the app closed: how long ago it
        /// was first asked, so it is asked again with the deadline it had.
        var askedAgo: TimeInterval?
        /// A snapshot with this task ended has reached every observer, so
        /// retention may let it go.
        var endTold = false
    }

    /// A question to put to `AskFirst` once the lock is let go.
    private struct PendingAsk {
        let id: String
        let index: Int
        let action: ProposedAction
        let askedAgo: TimeInterval?
    }

    public let rule: AskFirst
    public let policy: RetryPolicy
    /// Scripted, so always an example.
    public var isSample: Bool { true }
    private let origin: Date
    /// Where card times come from, when given. See `init(rule:policy:scripts:wallClock:)`.
    private let wallClock: (@Sendable () -> Date)?
    private let scripts: [TaskScript]
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var runs: [Run] = []
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var made = 0
    /// Goes up with every change observers hear about.
    private var sequence = 0
    /// Questions to withdraw once the lock is let go.
    private var withdrawals: [ConfirmationRequest] = []
    /// Receipts made and not yet taken by `takeReceipts`.
    private var receiptsMade: [Receipt] = []
    #if DEBUG
    private var publicationHook: (@Sendable () -> Void)?

    /// Pauses one mutation after its first unlock, before any publication.
    /// Taken under the run lock, so a concurrent mutation cannot reuse it.
    func beforeNextPublication(_ hook: @escaping @Sendable () -> Void) {
        lockRuns()
        publicationHook = hook
        unlockRuns()
    }

    /// For tests: calls to `AskFirst`, and how many came while this
    /// engine's lock was held. The second must stay zero.
    private let countLock = NSLock()
    private var ruleCallCount = 0
    private var ruleCallsHoldingLockCount = 0
    var ruleCalls: Int { countLock.lock(); defer { countLock.unlock() }; return ruleCallCount }
    var ruleCallsHoldingLock: Int { countLock.lock(); defer { countLock.unlock() }; return ruleCallsHoldingLockCount }
    #endif

    /// Ended tasks kept at most. Past this the oldest ended ones go, so what
    /// a task held never piles up. Tasks still going are never dropped.
    public static let endedLimit = 12

    /// `scripts` are matched to `start` by title; anything else gets a short
    /// generic script. `origin` is the wall time the clock starts at, used
    /// only for the times shown on cards.
    public init(rule: AskFirst = .shared, policy: RetryPolicy = .standard,
                scripts: [TaskScript] = SampleTasks.all, origin: Date = Date()) {
        self.rule = rule
        self.policy = policy
        self.scripts = scripts
        self.origin = origin
        self.wallClock = nil
    }

    /// The same, with the times on cards read from `wallClock` rather than
    /// counted from an origin. For an engine that plays in real time but is
    /// only moved while a card is live: its own clock stands still while
    /// nothing is going, so a card started after a quiet spell would show a
    /// time long past. The steps still play on the engine's own clock.
    /// `wallClock` is read under the engine's lock, so it must not call the engine.
    public init(rule: AskFirst = .shared, policy: RetryPolicy = .standard,
                scripts: [TaskScript] = SampleTasks.all, wallClock: @escaping @Sendable () -> Date) {
        self.rule = rule
        self.policy = policy
        self.scripts = scripts
        self.origin = wallClock()
        self.wallClock = wallClock
    }

    /// Seconds since the engine began.
    public var now: TimeInterval {
        lockRuns(); defer { unlockRuns() }
        return elapsed
    }

    /// The wall time the clock has reached, as the cards show it.
    public var currentDate: Date {
        lockRuns(); defer { unlockRuns() }
        return date
    }

    public var tasks: [AgentTask] {
        lockRuns(); defer { unlockRuns() }
        return runs.reversed().map(\.task)
    }

    public func task(_ id: String) -> AgentTask? {
        tasks.first { $0.id == id }
    }

    @discardableResult
    public func start(_ request: TaskRequest) -> String {
        let script = scripts.first { $0.title == request.title } ?? Self.generic(request.title)
        return start(script)
    }

    /// Begins a given script.
    @discardableResult
    public func start(_ script: TaskScript) -> String {
        let id = mutate { () -> String in
            made += 1
            let id = "task:\(made)"
            let date = self.date
            var run = Run(
                task: AgentTask(id: id, title: script.title, step: script.steps.first?.text ?? script.doneLine,
                                progress: script.determinate ? .fraction(0) : .indeterminate, startedAt: date),
                script: script, index: 0, phase: .working(attempt: 0, since: elapsed),
                stallsLeft: script.steps.map { if case .work(let stalls) = $0.kind { stalls } else { 0 } }
            )
            begin(&run)
            runs.append(run)
            return id
        }
        return id
    }

    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        let key = UUID()
        lockRuns()
        observers[key] = onChange
        let snapshot = TaskSnapshot(sequence: sequence, tasks: runs.reversed().map(\.task))
        unlockRuns()
        onChange(snapshot)
        return TaskObservation { [weak self] in
            guard let self else { return }
            self.lockRuns()
            self.observers[key] = nil
            self.unlockRuns()
        }
    }

    /// Moves the clock forward, playing every step that falls inside.
    public func advance(by seconds: TimeInterval) {
        let closed = closedQuestions()
        mutate {
            settle(closed)
            let target = elapsed + max(0, seconds)
            // Play events in time order, so a long jump lands where many
            // short ones would.
            while let (index, time) = nextEvent(), time <= target {
                elapsed = max(elapsed, time)
                fire(index)
            }
            elapsed = target
            for index in runs.indices { updateProgress(&runs[index]) }
        }
    }

    public func refresh() {
        let closed = closedQuestions()
        mutate { settle(closed) }
    }

    @discardableResult
    public func redirect(_ id: String, with instructions: String) -> Bool {
        let words = instructions
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !words.isEmpty else { return false }
        let said = words.count > Self.maxInstructionLength
            ? String(words.prefix(Self.maxInstructionLength)) + "..." : words
        return mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].task.isActive else { return false }
            withdrawQuestion(&runs[index])
            runs[index].task.record(TaskStep(TaskWords.youSaid(said), mark: .redirected, at: date))
            let run = runs[index]
            if run.approved {
                // The person said yes, so the step may already be under
                // way. It is committed: let it finish, and say so.
                runs[index].task.step = TaskWords.finishingApproved
                runs[index].task.updatedAt = date
            } else if run.index < run.script.steps.count, case .ask = run.script.steps[run.index].kind {
                // A script can't change what it asks, so the question would
                // come back as it was. Leave the step undone and say so,
                // rather than say the change was taken and ask the old thing.
                skip(&runs[index], line: TaskWords.changedCourse(run.script.steps[run.index].todo))
            } else {
                begin(&runs[index], line: TaskWords.redirected)
            }
            return true
        }
    }

    public static let maxInstructionLength = 200

    @discardableResult
    public func stop(_ id: String) -> Bool {
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].task.isActive else { return false }
            withdrawQuestion(&runs[index])
            let run = runs[index]
            var left = run.script.steps[min(run.index, run.script.steps.count)...].map(\.todo)
            // A step the person said yes to may have happened, so it is
            // never said to be undone, and its receipt says it may be done.
            let underway = run.approved ? left.removeFirst() : nil
            if run.approved { makeReceipt(run, outcome: .mayBeDone) }
            end(&runs[index], as: .stopped, line: TaskWords.stopped,
                wrapUp: TaskWrapUp(kept: run.kept, notDone: run.notDone + left, underway: underway))
            return true
        }
    }

    @discardableResult
    public func dismiss(_ id: String) -> Bool {
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), !runs[index].task.isActive else { return false }
            runs.remove(at: index)
            return true
        }
    }

    @discardableResult
    public func clear() -> ClearedTasks {
        mutate {
            for index in runs.indices { withdrawQuestion(&runs[index]) }
            let cleared = ClearedTasks(forgotten: runs.count,
                                       underway: runs.filter { $0.approved && $0.task.isActive }.count)
            runs.removeAll()
            // Receipts not yet handed over go too: nothing a task held stays.
            receiptsMade.removeAll()
            return cleared
        }
    }

    @discardableResult
    public func retry(_ id: String) -> Bool {
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].phase == .stuck else { return false }
            runs[index].phase = .working(attempt: 0, since: elapsed)
            runs[index].task.state = .running
            runs[index].task.step = runs[index].script.steps[runs[index].index].text
            runs[index].task.updatedAt = date
            return true
        }
    }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval {
        // Find the question under the lock, and check the yes outside it.
        lockRuns()
        let asked: ConfirmationRequest? = runs.first { $0.task.id == id }.flatMap { run in
            if case .askingYes(let request) = run.phase, request.id == approval.id { return request }
            return nil
        }
        unlockRuns()
        guard let asked else { return .refused }
        let verdict = withRule { $0.verdict(asked.action, approval: approval) }
        return mutate {
            // Moved on while the yes was checked, so nothing is done with it.
            guard let index = runs.firstIndex(where: { $0.task.id == id }),
                  runs[index].phase == .askingYes(asked) else { return .refused }
            switch verdict {
            case .proceed:
                runs[index].task.record(TaskStep(TaskWords.youSaidYes, mark: .approved, at: date))
                runs[index].task.question = nil
                runs[index].task.state = .running
                runs[index].task.step = runs[index].script.steps[runs[index].index].text
                runs[index].task.updatedAt = date
                runs[index].phase = .working(attempt: 0, since: elapsed)
                runs[index].approved = true
                runs[index].approvedAction = asked.action
                runs[index].approvedAt = date
                return .proceeding
            case .timedOut:
                skip(&runs[index], line: TaskWords.timedOut(runs[index].script.steps[runs[index].index].todo))
                return .timedOut
            case .stop:
                return .refused
            }
        }
    }

    public func questionClosed(_ request: ConfirmationRequest) {
        // Close on a question that had already run out of time is a
        // timeout, not a no. Asked with the lock let go.
        let ranOut = withRule { $0.isClosed(request) && !$0.wasWithdrawn(request) }
        mutate {
            guard let index = runs.firstIndex(where: { $0.phase == .askingYes(request) }) else { return }
            withdrawals.append(request)
            let todo = runs[index].script.steps[runs[index].index].todo
            skip(&runs[index], line: ranOut ? TaskWords.timedOut(todo) : TaskWords.declined(todo))
        }
    }

    // MARK: Keeping tasks while the app is closed

    public func saved() -> [SavedTask] {
        lockRuns(); defer { unlockRuns() }
        return runs.filter { $0.task.isActive && $0.index < $0.script.steps.count }.map { run in
            let phase: SavedTask.Phase
            switch run.phase {
            case .askingYes: phase = .waiting
            // Being asked again after the app closed: still the question it
            // was, so it keeps the time it was first asked.
            case .toAsk where run.askedAt != nil, .asking where run.askedAt != nil: phase = .waiting
            // A yes is kept whatever the step is doing, so Try again after
            // a restart can never run it twice.
            default: phase = run.approved ? .approved : run.phase == .stuck ? .stuck : .working
            }
            return SavedTask(id: run.task.id, title: run.script.title, step: run.index, phase: phase,
                             askedAt: phase == .waiting ? run.askedAt : nil,
                             approvedAt: phase == .approved ? run.approvedAt : nil,
                             approvedAction: phase == .approved ? run.approvedAction.map(SavedAction.init) : nil,
                             kept: run.kept, notDone: run.notDone,
                             history: run.task.history.map { .init(text: $0.text, mark: $0.mark, at: $0.at, undone: $0.undone) },
                             startedAt: run.task.startedAt)
        }
    }

    public func restore(_ saved: [SavedTask], now: Date) {
        // Read before the lock: the rule is never asked anything under it.
        let window = rule.questionWindow
        mutate {
            for entry in saved where !runs.contains(where: { $0.task.id == entry.id }) {
                let script = scripts.first { $0.title == entry.title } ?? Self.generic(entry.title)
                guard entry.step >= 0, entry.step < script.steps.count else { continue }
                if let number = Int(entry.id.dropFirst("task:".count)) { made = max(made, number) }
                let step = script.steps[entry.step]
                var run = Run(
                    task: AgentTask(id: entry.id, title: script.title, step: step.text,
                                    progress: script.determinate ? .fraction(Double(entry.step) / Double(script.steps.count))
                                        : .indeterminate,
                                    history: entry.history.map { TaskStep($0.text, mark: $0.mark, at: $0.at, undone: $0.undone) },
                                    startedAt: entry.startedAt, updatedAt: date),
                    script: script, index: entry.step, phase: .working(attempt: 0, since: elapsed),
                    stallsLeft: script.steps.map { if case .work(let stalls) = $0.kind { stalls } else { 0 } },
                    kept: entry.kept, notDone: entry.notDone
                )
                switch entry.phase {
                case .working:
                    begin(&run)
                case .stuck:
                    run.phase = .stuck
                    run.task.state = .waitingOnYou
                    run.task.step = TaskWords.stuck
                case .waiting:
                    // Asked again with the deadline it had, or, once that has
                    // passed or the clock went back, ended as a timeout. The
                    // deadline is the saved one, the action today's script's:
                    // a step an update changed inherits the old time left,
                    // and still needs a fresh yes.
                    let age = entry.askedAt.map { now.timeIntervalSince($0) } ?? .infinity
                    if case .ask = step.kind, age >= 0, age <= window {
                        run.askedAgo = age
                        begin(&run)
                        run.askedAt = entry.askedAt
                    } else {
                        skip(&run, line: TaskWords.timedOut(step.todo))
                    }
                case .approved:
                    // The yes was for that moment. The step may have
                    // happened, so it is never run again, and never called
                    // undone. Its receipt says only what the person saw when
                    // they said yes, as it was kept then; today's script
                    // may say something else. Without it, or with one
                    // changed into something no question could show, there
                    // is no receipt, and the card still says it may be done.
                    // Ended as stopped, not failed: it may have happened.
                    if let action = entry.approvedAction?.action {
                        run.approvedAction = action
                        run.approvedAt = entry.approvedAt ?? date
                        run.approved = true
                        makeReceipt(run, outcome: .mayBeDone)
                    }
                    end(&run, as: .stopped, line: TaskWords.interrupted,
                        wrapUp: TaskWrapUp(kept: run.kept,
                                           notDone: run.notDone + script.steps[(entry.step + 1)...].map(\.todo),
                                           underway: step.todo))
                    run.approved = false
                }
                runs.append(run)
            }
        }
    }

    public func takeReceipts() -> [Receipt] {
        lockRuns(); defer { unlockRuns() }
        let out = receiptsMade
        receiptsMade = []
        return out
    }

    /// A receipt for the step the person said yes to, as it ends.
    private func makeReceipt(_ run: Run, outcome: Receipt.Outcome) {
        guard let action = run.approvedAction else { return }
        receiptsMade.append(Receipt(action: action, taskTitle: run.task.title, approvedAt: run.approvedAt ?? date,
                                    endedAt: date, outcome: outcome, isSample: isSample))
    }

    // MARK: The state machine. Everything below runs inside the lock, except
    // `withRule`, `closedQuestions` and the rule calls in `mutate`.

    private var date: Date { wallClock?() ?? origin + elapsed }

    /// Takes the lock. In DEBUG it also marks this thread as its holder, so
    /// `withRule` can tell this thread holding it from another one.
    private func lockRuns() {
        lock.lock()
        #if DEBUG
        holding = true
        #endif
    }

    private func unlockRuns() {
        #if DEBUG
        holding = false
        #endif
        lock.unlock()
    }

    #if DEBUG
    /// This thread's mark, kept per thread so no other thread reads or sets it.
    private var holdingKey: String { "LocalFakeEngine.holding.\(ObjectIdentifier(self).hashValue)" }

    private var holding: Bool {
        get { Thread.current.threadDictionary[holdingKey] as? Bool ?? false }
        set { Thread.current.threadDictionary[holdingKey] = newValue ? true : nil }
    }

    /// True when the lock is held by this thread.
    var holdsLock: Bool { holding }

    /// For tests: runs `body` holding the lock, as the engine itself would.
    func holdingLock(_ body: () -> Void) {
        lockRuns()
        body()
        unlockRuns()
    }
    #endif

    /// Every call to `AskFirst` goes through here, never holding the lock.
    private func withRule<T>(_ call: (AskFirst) -> T) -> T {
        #if DEBUG
        // Only this thread holding it counts. Another thread holding the
        // lock at the same moment is no fault here.
        let held = holdsLock
        countLock.lock()
        ruleCallCount += 1
        if held { ruleCallsHoldingLockCount += 1 }
        countLock.unlock()
        #endif
        return call(rule)
    }

    /// A question `AskFirst` closed, and whether it was withdrawn (the
    /// person said Not now or closed the sheet) rather than timed out.
    private struct Closed {
        let request: ConfirmationRequest
        let withdrawn: Bool
    }

    /// The open questions `AskFirst` has closed, and why. Asked with the
    /// lock let go.
    private func closedQuestions() -> [Closed] {
        lockRuns()
        let open = runs.compactMap { run -> ConfirmationRequest? in
            if case .askingYes(let request) = run.phase { return request }
            return nil
        }
        unlockRuns()
        return open.compactMap { request in
            guard withRule({ $0.isClosed(request) }) else { return nil }
            return Closed(request: request, withdrawn: withRule { $0.wasWithdrawn(request) })
        }
    }

    /// A question that closed without a yes lets the task go on without it.
    /// Its line says which: the person said no, or the question timed out.
    private func settle(_ closed: [Closed]) {
        for question in closed {
            guard let index = runs.firstIndex(where: { $0.phase == .askingYes(question.request) }) else { continue }
            let todo = runs[index].script.steps[runs[index].index].todo
            skip(&runs[index], line: question.withdrawn ? TaskWords.declined(todo) : TaskWords.timedOut(todo))
        }
    }

    /// Starts the current step: asks, works, or fails. Past the last step,
    /// the task is done.
    private func begin(_ run: inout Run, line: String? = nil) {
        run.approved = false
        run.approvedAction = nil
        run.approvedAt = nil
        run.askedAt = nil
        guard run.index < run.script.steps.count else {
            run.phase = .ended
            end(&run, as: .done, line: run.script.doneLine,
                wrapUp: run.notDone.isEmpty ? nil : TaskWrapUp(kept: run.kept, notDone: run.notDone))
            run.task.result = run.script.result
            run.task.proofs = run.script.proofs
            run.task.progress = .fraction(1)
            return
        }
        let step = run.script.steps[run.index]
        run.task.updatedAt = date
        switch step.kind {
        case .work:
            run.phase = .working(attempt: 0, since: elapsed)
            run.task.state = .running
            run.task.step = line ?? step.text
        case .ask:
            // Asked by `mutate` once the lock is let go; `asked` takes the answer.
            run.phase = .toAsk
        case .fails:
            end(&run, as: .failed, line: TaskWords.failed,
                wrapUp: TaskWrapUp(kept: run.kept, notDone: run.notDone + run.script.steps[run.index...].map(\.todo)))
        }
    }

    /// The step is left undone, and the task goes on to the next.
    private func skip(_ run: inout Run, line: String) {
        let step = run.script.steps[run.index]
        run.task.question = nil
        run.notDone.append(step.todo)
        run.task.record(TaskStep(line, mark: .skipped, at: date, undone: step.todo))
        run.index += 1
        begin(&run)
    }

    private func end(_ run: inout Run, as state: TaskState, line: String, wrapUp: TaskWrapUp?) {
        run.phase = .ended
        run.task.state = state
        run.task.step = line
        run.task.question = nil
        run.task.wrapUp = wrapUp
        run.task.updatedAt = date
    }

    /// The question goes once the lock is let go. One still being asked is
    /// withdrawn when its answer comes, since the run will have moved on.
    private func withdrawQuestion(_ run: inout Run) {
        if case .askingYes(let request) = run.phase { withdrawals.append(request) }
        run.task.question = nil
    }

    /// Hands over what `AskFirst` must be told, and claims each question
    /// waiting to be asked, so no one else asks it too.
    private func takeRuleWork() -> (withdrawals: [ConfirmationRequest], asks: [PendingAsk]) {
        let out = withdrawals
        withdrawals = []
        var asks: [PendingAsk] = []
        for index in runs.indices where runs[index].phase == .toAsk {
            guard case .ask(let action, _) = runs[index].script.steps[runs[index].index].kind else { continue }
            runs[index].phase = .asking
            asks.append(PendingAsk(id: runs[index].task.id, index: runs[index].index, action: action,
                                   askedAgo: runs[index].askedAgo))
            runs[index].askedAgo = nil
        }
        return (out, asks)
    }

    /// `AskFirst`'s answer to a question asked outside the lock. A run that
    /// moved on meanwhile (stopped, redirected, cleared) has its question
    /// withdrawn at once.
    private func asked(_ ask: PendingAsk, _ request: ConfirmationRequest?) {
        guard let index = runs.firstIndex(where: { $0.task.id == ask.id }),
              runs[index].phase == .asking, runs[index].index == ask.index else {
            if let request { withdrawals.append(request) }
            return
        }
        let step = runs[index].script.steps[ask.index]
        guard let request, case .ask(_, let askLine) = step.kind else {
            // Asked once already, so only its time running out can stop it now.
            skip(&runs[index], line: ask.askedAgo == nil ? TaskWords.couldNotAsk(step.todo) : TaskWords.timedOut(step.todo))
            return
        }
        runs[index].phase = .askingYes(request)
        runs[index].task.state = .waitingOnYou
        runs[index].task.question = request
        runs[index].task.step = askLine
        runs[index].task.updatedAt = date
        runs[index].askedAt = date - (ask.askedAgo ?? 0)
    }

    /// The soonest thing due, across every task.
    private func nextEvent() -> (Int, TimeInterval)? {
        var soonest: (Int, TimeInterval)?
        for (index, run) in runs.enumerated() {
            let due: TimeInterval
            switch run.phase {
            case .working(_, let since):
                let step = run.script.steps[run.index]
                due = since + (run.stallsLeft[run.index] > 0 ? policy.timeout : step.duration)
            case .waitingToRetry(_, let until):
                due = until
            case .toAsk, .asking, .askingYes, .stuck, .ended:
                continue
            }
            if soonest == nil || due < soonest!.1 { soonest = (index, due) }
        }
        return soonest
    }

    private func fire(_ index: Int) {
        var run = runs[index]
        defer { runs[index] = run }
        let step = run.script.steps[run.index]
        switch run.phase {
        case .working(let attempt, _):
            if run.stallsLeft[run.index] > 0 {
                // Hung past the timeout. Try another way, or ask once the
                // retries are spent.
                run.stallsLeft[run.index] -= 1
                run.task.updatedAt = date
                if attempt < policy.maxRetries {
                    run.phase = .waitingToRetry(attempt: attempt + 1, until: elapsed + policy.delay(beforeRetry: attempt))
                    run.task.state = .stalled
                    run.task.step = step.slowLine
                } else {
                    run.phase = .stuck
                    run.task.state = .waitingOnYou
                    run.task.step = TaskWords.stuck
                }
            } else {
                run.task.record(attempt > 0
                    ? TaskStep(TaskWords.tookAnotherWay(step.todo), mark: .retried, at: date)
                    : TaskStep(step.text, mark: .done, at: date))
                if let kept = step.kept { run.kept.append(kept) }
                if run.approved { makeReceipt(run, outcome: .done) }
                run.index += 1
                begin(&run)
            }
        case .waitingToRetry(let attempt, _):
            run.phase = .working(attempt: attempt, since: elapsed)
            run.task.state = .retrying
            run.task.step = step.retryLine
            run.task.updatedAt = date
        case .toAsk, .asking, .askingYes, .stuck, .ended:
            break
        }
    }

    /// Steps done, plus how far into the current one, for determinate scripts.
    private func updateProgress(_ run: inout Run) {
        guard run.script.determinate, run.task.isActive else { return }
        let total = Double(max(1, run.script.steps.count))
        var within = 0.0
        if case .working(_, let since) = run.phase, run.stallsLeft[run.index] == 0 {
            let duration = max(0.001, run.script.steps[run.index].duration)
            within = min(1, max(0, (elapsed - since) / duration))
        }
        // Never moves backward, so a retry doesn't undo what was shown.
        let next = (Double(run.index) + within) / total
        let shown = run.task.progress.fraction ?? 0
        run.task.progress = .fraction(max(shown, min(1, next)))
    }

    /// Runs a change inside the lock, then tells observers. Retention is a
    /// separate change, and lets go only of ends a delivered snapshot told.
    /// An end still on its way, in this mutation or one running beside it,
    /// is kept, and the mutation that tells it trims after. So retention
    /// never waits for a quiet moment that steady work may never give.
    ///
    /// `AskFirst` is told and asked only with the lock let go, so if it ever
    /// calls out, and someone calls back in, nothing deadlocks. An answer
    /// can start the next step, which may ask again, so this goes round
    /// until nothing is left to tell the rule.
    private func mutate<T>(_ change: () -> T) -> T {
        lockRuns()
        let before = runs.map(\.task)
        let value = change()
        var work = takeRuleWork()
        #if DEBUG
        let hook = publicationHook
        publicationHook = nil
        #endif
        unlockRuns()
        #if DEBUG
        hook?()
        #endif
        while !work.withdrawals.isEmpty || !work.asks.isEmpty {
            for request in work.withdrawals { withRule { $0.withdraw(request) } }
            let answers = work.asks.map { ask in
                (ask, withRule { rule in
                    // A question picked up after the app closed keeps its deadline.
                    ask.askedAgo.map { rule.askAgain(ask.action, askedAgo: $0) } ?? rule.ask(ask.action)
                })
            }
            lockRuns()
            for (ask, request) in answers { asked(ask, request) }
            work = takeRuleWork()
            unlockRuns()
        }
        lockRuns()
        let after = runs.map(\.task)
        let changed = before != after
        if changed { sequence += 1 }
        let snapshot = TaskSnapshot(sequence: sequence, tasks: Array(after.reversed()))
        let listeners = changed ? Array(observers.values) : []
        unlockRuns()
        for listener in listeners { listener(snapshot) }
        lockRuns()
        if changed { markEndsTold(in: snapshot) }
        let trim = !oldEnded().isEmpty
        unlockRuns()
        if trim {
            // Everyone has heard those outcomes. Publish retention as its
            // own change, so the feed also receives the bounded list of cards.
            mutate { dropOldEnded() }
        }
        return value
    }

    /// Every observer there was has heard the ends in `snapshot`.
    private func markEndsTold(in snapshot: TaskSnapshot) {
        let ended = Set(snapshot.tasks.filter { !$0.isActive }.map(\.id))
        for index in runs.indices where ended.contains(runs[index].task.id) && !runs[index].task.isActive {
            runs[index].endTold = true
        }
    }

    /// Ended tasks past the `endedLimit` that ended last, whose ends have
    /// been told. A task that ends now outlasts those that ended before it,
    /// whenever it began.
    private func oldEnded() -> [Int] {
        // Runs are oldest first, so a tie goes to the one begun first.
        let ended = runs.indices.filter { !runs[$0].task.isActive }
            .sorted { (runs[$0].task.updatedAt, $0) < (runs[$1].task.updatedAt, $1) }
        guard ended.count > Self.endedLimit else { return [] }
        return ended.prefix(ended.count - Self.endedLimit).filter { runs[$0].endTold }
    }

    /// Keeps at most `endedLimit` ended tasks, the ones that ended last,
    /// past which only an end not told yet stays, until it is told.
    private func dropOldEnded() {
        for index in oldEnded().sorted().reversed() { runs.remove(at: index) }
    }

    /// For a request no script covers: a few plain steps.
    static func generic(_ title: String) -> TaskScript {
        TaskScript(title: title, steps: [
            .init("Getting started", duration: 4, todo: "get started"),
            .init("Working through it", duration: 8, todo: "work through it"),
            .init("Tidying up what I found", duration: 4, kept: "what I found", todo: "tidy up"),
        ], determinate: false, doneLine: "All done. It's ready when you are.")
    }
}

/// Scripted tasks for the showcase and tests. Nothing here is really done.
public enum SampleTasks {
    public static let dentistTitle = "Find a dentist near you open Saturdays"
    public static let planTitle = "Tidy this week's plan"
    public static let lunchTitle = "Find the school lunch menu"

    /// What holding the dentist visit would share, asked through `AskFirst`.
    public static let holdVisit = ProposedAction(
        kind: .sharePersonalInfo,
        // A reserved name, so the example never points at a real site.
        recipient: Recipient(id: "clinic:sample-maple-dental", displayName: "Maple Dental", handle: "mapledental.example"),
        details: "Your name and phone number, to hold Saturday at 10:30",
        outcome: "I'll hold a visit for you on Saturday at 10:30."
    )

    public static let dentist = TaskScript(
        title: dentistTitle,
        steps: [
            .init("Looking at dentists near you", duration: 6, kept: "a list of dentists nearby",
                  todo: "look for dentists nearby"),
            .init("Checking which ones open on Saturdays", kind: .work(stalls: 1), duration: 8,
                  kept: "three that open Saturdays", todo: "check Saturday hours",
                  slowLine: "That clinic's page is slow. I'll try another way in a moment.",
                  retryLine: "That page was slow, so I'm trying another way."),
            .init("Reading what people say about them", duration: 6, kept: "a few notes on their reviews",
                  todo: "read their reviews"),
            .init("Holding Saturday at 10:30 at Maple Dental",
                  kind: .ask(holdVisit, askLine: "Maple Dental has Saturday at 10:30. I'll wait for your yes before I hold it."),
                  duration: 4, kept: "a hold for Saturday at 10:30", todo: "hold a Saturday visit"),
        ],
        doneLine: "I found three dentists open Saturdays.",
        result: """
            Maple Dental  Saturdays 9 to 2, a ten minute walk. People say they are gentle with nervous patients.
            Harbour Smiles  Saturdays 10 to 4. Easy parking.
            Elm Street Dental  Every other Saturday, 9 to 1.
            """,
        // Reserved names, so the example never points at a real site.
        proofs: [
            .source(title: "Maple Dental hours", url: URL(string: "https://mapledental.example/hours")!),
            .source(title: "Harbour Smiles visits", url: URL(string: "https://harboursmiles.example/visit")!),
            .artifact(name: "Saturday dentists", kind: .list, reference: dentistListReference),
        ]
    )

    /// Where the dentist search's list would be kept, for a ledger that
    /// knows it. Nothing is really written there.
    public static let dentistListReference = "made/saturday-dentists.json"

    public static let plan = TaskScript(
        title: planTitle,
        steps: [
            .init("Reading this week's calendar", duration: 5, todo: "read this week's calendar"),
            .init("Finding the busy evenings", duration: 7, todo: "find the busy evenings"),
            .init("Grouping errands into one trip", duration: 6, kept: "errands grouped into one trip",
                  todo: "group the errands"),
            .init("Leaving room after lunch", duration: 4, kept: "a quiet hour after lunch", todo: "leave room after lunch"),
        ],
        determinate: false,
        doneLine: "Your week is tidier. Two errands now share one trip.",
        result: """
            Tuesday  Groceries and the pharmacy, one trip at 5
            Wednesday  Book club at 7
            Thursday  A quiet hour after lunch
            Saturday  Still free
            """
    )

    public static let lunch = TaskScript(
        title: lunchTitle,
        steps: [
            .init("Opening the school's page", kind: .work(stalls: 3), duration: 5, kept: "this month's lunch menu",
                  todo: "find the menu",
                  slowLine: "The school's page isn't loading. I'll try another way in a moment.",
                  retryLine: "That page was slow, so I'm trying another way."),
        ],
        doneLine: "This month's lunch menu is ready."
    )

    public static let all = [dentist, plan, lunch]
}
