import Foundation

/// One card in the Today feed: something the agent did, made, spotted, or
/// needs a yes for.
public struct FeedItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Something the agent finished on its own.
        case did
        /// A result the person can open.
        case ready
        /// Something the agent spotted. Gentle and optional.
        case noticed
        /// A question waiting for the person's yes or no.
        case needsYou
        /// Longer work, shown live on a task card.
        case task
    }

    public let id: String
    public let kind: Kind
    public let time: Date
    /// A plain line, such as "Your morning plan is set".
    public let title: String
    /// One or two short sentences.
    public let body: String
    public let action: FeedAction?

    public init(id: String, kind: Kind, time: Date, title: String, body: String, action: FeedAction? = nil) {
        self.id = id
        self.kind = kind
        self.time = time
        self.title = title
        self.body = body
        self.action = action
    }

    /// The question this card asks, when it is a real one from `AskFirst`.
    public var request: ConfirmationRequest? {
        if case .review(let request) = action { return request }
        return nil
    }

    /// The task this card shows, when it is a task card.
    public var task: AgentTask? {
        if kind == .task, case .task(let task) = action { return task }
        return nil
    }

    /// What VoiceOver says first, so each card reads as one thought.
    public var spokenKind: String {
        switch kind {
        case .did: FeedWords.didLabel
        case .ready: FeedWords.readyLabel
        case .noticed: FeedWords.noticedLabel
        case .needsYou: FeedWords.needsYouHeading
        case .task: task?.state.label ?? TaskWords.runningLabel
        }
    }
}

/// What a card's one button does.
public enum FeedAction: Sendable, Equatable {
    /// Shows the full result to read.
    case open(String)
    /// Opens the chat with this line in the composer. Nothing is sent until
    /// the person sends it.
    case talk(String)
    /// Opens the same question sheet the agent always uses before it sends,
    /// buys or shares. Only `NeedsYou` makes these, from a question
    /// `AskFirst` agreed to ask.
    case review(ConfirmationRequest)
    /// A live task card, with its own buttons. Its Approve opens the same
    /// question sheet as `review`, for the question the task's engine asked
    /// through `AskFirst`. Holds the task without live progress.
    case task(AgentTask)

    public var title: String {
        switch self {
        case .open: FeedWords.openTitle
        case .talk: FeedWords.talkTitle
        case .review: FeedWords.reviewTitle
        case .task(let task): task.waitsForApproval ? TaskWords.approveTitle : FeedWords.openTitle
        }
    }

    /// What VoiceOver says the card does, such as "Opens the question."
    public var hint: String {
        switch self {
        case .open: FeedWords.openHint
        case .talk: FeedWords.talkHint
        case .review: FeedWords.reviewHint
        case .task(let task): task.waitsForApproval ? FeedWords.reviewHint : FeedWords.openHint
        }
    }
}

/// Where feed items come from. Sources are local: nothing here goes to the
/// network.
public protocol FeedSource: Sendable {
    func items(now: Date) -> [FeedItem]
    /// True when the items are examples, so the screen can say so.
    var isSample: Bool { get }
}

extension FeedSource {
    public var isSample: Bool { false }
}

/// No items. What a brand new person sees until the agent has done anything.
public struct EmptyFeedSource: FeedSource {
    public init() {}
    public func items(now: Date) -> [FeedItem] { [] }
}

/// Example items made on the device, for screenshots, previews and tests.
/// Nothing here was really done, so the screen labels them as examples.
public struct SampleFeedSource: FeedSource {
    public init() {}
    public var isSample: Bool { true }

    public func items(now: Date) -> [FeedItem] {
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        return [
            FeedItem(
                id: "sample:morning-plan", kind: .did, time: now - 48 * minute,
                title: "Your morning plan is set",
                body: "School drop off at 8:15, the gym at 9:30, and groceries on the way home.",
                action: .open("""
                    8:15  School drop off
                    9:30  Gym
                    11:00  Groceries on the way home
                    After lunch  Answer Priya

                    I left a little room after lunch, since that part of the day tends to run long.
                    """)
            ),
            FeedItem(
                id: "sample:priya-draft", kind: .ready, time: now - 1.5 * hour,
                title: "A reply to Priya, ready to read",
                body: "I wrote a short draft you can change. Nothing has been sent.",
                action: .open("""
                    Hi Priya, thanks for checking in. Thursday works for me. Could we meet at 4 instead of 3? I have the dentist until then.
                    """)
            ),
            FeedItem(
                id: "sample:sam-birthday", kind: .noticed, time: now - 2.2 * hour,
                title: "Sam's birthday is coming up",
                body: "It's on \((now + 12 * day).formatted(.dateTime.month(.wide).day())), and Sam loves lemon cake. Want a few ideas?",
                action: .talk("Help me plan something for Sam's birthday.")
            ),
            FeedItem(
                id: "sample:grocery-list", kind: .did, time: now - day + 7.5 * hour,
                title: "Your grocery list is tidy",
                body: "I grouped it by aisle and took off what you already bought.",
                action: .open("""
                    Produce: lemons, spinach, apples
                    Bakery: sandwich bread
                    Dairy: yogurt, butter
                    Pantry: oats, honey
                    """)
            ),
            FeedItem(
                id: "sample:dentist", kind: .noticed, time: now - day + 3 * hour,
                title: "Your dentist visit is coming up",
                body: "It's in your notes. Want a reminder the day before?",
                action: .talk("Remind me the day before my dentist visit.")
            ),
            FeedItem(
                id: "sample:week", kind: .ready, time: now - 2 * day,
                title: "Your week at a glance",
                body: "Three busy evenings and a free Saturday.",
                action: .open("""
                    Monday  Soccer pickup at 6
                    Tuesday  Quiet
                    Wednesday  Book club at 7
                    Thursday  Dentist at 3, then Priya at 4
                    Friday  Dinner with Sam at 7
                    Saturday  Free all day
                    """)
            ),
        ]
    }
}

/// Questions waiting for the person, built on `AskFirst`.
///
/// This adds no new way to act. A question gets here only if `AskFirst`
/// agreed to ask it, and the feed answers it with the same confirmation
/// sheet as everywhere else. A question that timed out, was answered, or
/// was withdrawn leaves the feed, because `AskFirst` says it is closed.
public final class NeedsYou: FeedSource, @unchecked Sendable {
    private struct Waiting {
        let request: ConfirmationRequest
        let askedAt: Date
        let onApprove: (@Sendable (Approval) -> Void)?
    }

    public let rule: AskFirst
    /// True for the showcase's sample questions, so the cards and the sheet
    /// say they are examples. The rule asks and answers them as always.
    public let isSample: Bool
    private let lock = NSLock()
    private var waiting: [Waiting] = []
    private var observers: [Observation: @Sendable () -> Void] = [:]
    private let locale: Locale

    public init(rule: AskFirst = .shared, isSample: Bool = false, locale: Locale = .current) {
        self.rule = rule
        self.isSample = isSample
        self.locale = locale
    }

    /// One watcher of the questions, kept so it can stop watching.
    public struct Observation: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Calls `hook` after a question is asked, answered with a yes, or
    /// dismissed, so whatever shows the count can update at once. Several
    /// can watch at once, such as one Today per window on iPad, and each
    /// hears every change. Hooks are never called with the lock held.
    public func observe(_ hook: @escaping @Sendable () -> Void) -> Observation {
        let observation = Observation()
        lock.lock()
        observers[observation] = hook
        lock.unlock()
        return observation
    }

    /// Stops calling the hook `observe` returned this for.
    public func stopObserving(_ observation: Observation) {
        lock.lock()
        observers[observation] = nil
        lock.unlock()
    }

    /// How many are watching, for tests.
    package var observerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observers.count
    }

    private func didChange() {
        lock.lock()
        let hooks = Array(observers.values)
        lock.unlock()
        for hook in hooks { hook() }
    }

    /// Ask the person about `action`. Nil, and nothing on the feed, when
    /// `AskFirst` won't ask it. `onApprove` gets the approval after a yes,
    /// and must still pass it to `AskFirst.decide` before acting.
    ///
    /// `time` is only what the card shows. The order comes from `AskFirst`:
    /// it gives every question the same window from the moment it asks, so
    /// the question asked first is the one that times out first.
    @discardableResult
    public func ask(_ action: ProposedAction, at time: Date = Date(),
                    onApprove: (@Sendable (Approval) -> Void)? = nil) -> ConfirmationRequest? {
        lock.lock()
        // Asked and recorded under one lock, so the list keeps the rule's order.
        guard let request = rule.ask(action) else {
            lock.unlock()
            return nil
        }
        waiting.append(Waiting(request: request, askedAt: time, onApprove: onApprove))
        lock.unlock()
        didChange()
        return request
    }

    /// The sheet said yes. Hands the approval on and takes the card away.
    ///
    /// Only a yes to a question this rule asked, for the same action, and
    /// still held open by the rule counts. Anything else does nothing.
    /// Turning a request into an `Approval` is package only, and inside the
    /// package only `AskFirst.sayYes` does it (`AskFirstGateTests`), so the
    /// sheet's yes is the only way to make one.
    public func approved(_ approval: Approval) {
        lock.lock()
        guard let index = waiting.firstIndex(where: { $0.request.id == approval.id }),
              waiting[index].request.action == approval.action,
              !rule.isClosed(waiting[index].request) else {
            lock.unlock()
            return
        }
        let answered = waiting.remove(at: index)
        lock.unlock()
        answered.onApprove?(approval)
        didChange()
    }

    /// The sheet closed without a yes. The sheet has already withdrawn the
    /// question; this takes the card away.
    public func dismissed(_ request: ConfirmationRequest) {
        lock.lock()
        let before = waiting.count
        waiting.removeAll { $0.request.id == request.id }
        let removed = waiting.count != before
        lock.unlock()
        if removed { didChange() }
    }

    /// Only questions `AskFirst` still holds open, the one that times out
    /// first on top.
    public func items(now: Date) -> [FeedItem] {
        lock.lock()
        waiting.removeAll { rule.isClosed($0.request) }
        let open = waiting
        lock.unlock()
        return open.map { entry in
            FeedItem(
                id: "ask:\(entry.request.id.uuidString)", kind: .needsYou, time: entry.askedAt,
                title: entry.request.action.question(locale: locale),
                body: entry.request.action.details,
                action: .review(entry.request)
            )
        }
    }
}

/// Tasks from an engine, as live cards. `Feed.build` places them: a task
/// that needs the person is pinned in Needs you, one still going sits in
/// Working on it, and one that ended joins the rest of the feed at the
/// time it ended. Passed as a plain source it adds nothing.
public struct TaskFeed: FeedSource {
    public let engine: any TaskEngine

    public init(engine: any TaskEngine) {
        self.engine = engine
    }

    /// Scripted tasks are examples, labelled like every other example.
    public var isSample: Bool { engine.isSample }

    public func items(now: Date) -> [FeedItem] {
        engine.tasks.map(Self.item)
    }

    /// Holds the task without its live progress (`AgentTask.card`), so a
    /// tick of progress never changes the feed. The card reads progress
    /// from the engine.
    public static func item(_ task: AgentTask) -> FeedItem {
        FeedItem(id: task.id, kind: .task, time: task.isActive ? task.startedAt : task.updatedAt,
                 title: task.title, body: task.step, action: .task(task.card))
    }
}

/// When a card happened, as the feed groups it.
public enum FeedPeriod: Sendable, Equatable, Hashable, CaseIterable {
    case thisEvening, thisAfternoon, thisMorning, earlier

    public var title: String {
        switch self {
        case .thisEvening: FeedWords.thisEvening
        case .thisAfternoon: FeedWords.thisAfternoon
        case .thisMorning: FeedWords.thisMorning
        case .earlier: FeedWords.earlier
        }
    }

    /// Today before noon is the morning, noon to five the afternoon, and
    /// later the evening. Anything before today is earlier. A time a little
    /// ahead of the clock counts as now.
    public static func of(_ time: Date, now: Date, calendar: Calendar) -> FeedPeriod {
        let time = min(time, now)
        guard calendar.isDate(time, inSameDayAs: now) else { return .earlier }
        switch calendar.component(.hour, from: time) {
        case ..<12: return .thisMorning
        case ..<17: return .thisAfternoon
        default: return .thisEvening
        }
    }
}

public struct FeedGroup: Sendable, Equatable, Identifiable {
    public let period: FeedPeriod
    public let items: [FeedItem]
    public var id: FeedPeriod { period }
    public var title: String { period.title }
}

/// The Today feed, ready to show: questions pinned on top, then everything
/// else grouped by time, newest first.
public struct Feed: Sendable, Equatable {
    /// Questions waiting for the person, the one that will time out first on
    /// top. Empty means the section is not shown at all.
    public let needsYou: [FeedItem]
    /// Tasks still going, newest first, shown under Needs you.
    public let working: [FeedItem]
    public let groups: [FeedGroup]

    public var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && groups.isEmpty }
    public var showsNeedsYou: Bool { !needsYou.isEmpty }
    public var showsWorking: Bool { !working.isEmpty }
    public var count: Int { needsYou.count + working.count + groups.reduce(0) { $0 + $1.items.count } }

    /// `items` can never ask anything: question cards, task cards and
    /// questions hidden in other cards are dropped. Only `questions`, from
    /// `NeedsYou`, are pinned, in the order given, and only while
    /// `isClosed` says the rule still holds them open.
    ///
    /// `tasks` come only from the feed's own engine. A task waiting on a yes
    /// is pinned after the questions, oldest first, only while `isClosed`
    /// says the same rule holds its question open. A stuck task, which asks
    /// nothing, is pinned too. A task still going sits in Working on it,
    /// and one that ended joins the time groups.
    public static func build(_ items: [FeedItem], questions: [FeedItem] = [], tasks: [FeedItem] = [],
                             isClosed: (ConfirmationRequest) -> Bool = { _ in true },
                             now: Date, calendar: Calendar = .current) -> Feed {
        let pinned = questions.filter { item in
            guard item.kind == .needsYou, let request = item.request else { return false }
            return !isClosed(request)
        }
        let tasks = tasks.filter { $0.task != nil }
        let waiting = tasks
            .filter { item in
                guard let task = item.task, task.state == .waitingOnYou else { return false }
                return task.question.map { !isClosed($0) } ?? true
            }
            .sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        let working = tasks
            .filter { item in item.task?.isActive == true && !waiting.contains { $0.id == item.id } }
            .sorted { ($0.time, $0.id) > ($1.time, $1.id) }
        let ended = tasks.filter { $0.task?.isActive == false }
        let rest = (items.filter { $0.kind != .needsYou && $0.kind != .task && $0.request == nil } + ended)
            .sorted { ($0.time, $0.id) > ($1.time, $1.id) }
        let byPeriod = Dictionary(grouping: rest) { FeedPeriod.of($0.time, now: now, calendar: calendar) }
        let groups = FeedPeriod.allCases.compactMap { period in
            byPeriod[period].map { FeedGroup(period: period, items: $0) }
        }
        return Feed(needsYou: pinned + waiting, working: working, groups: groups)
    }

    /// The feed from its sources, with questions taken only from `needsYou`
    /// and task cards only from `tasks`. A `NeedsYou` or `TaskFeed` passed
    /// among the sources adds nothing. A task's question is pinned only
    /// when the engine asked it through the rule of `needsYou`, so its
    /// Approve opens the same sheet, with the same rule, as any question.
    public static func build(from sources: [any FeedSource], needsYou: NeedsYou? = nil,
                             tasks: (any TaskEngine)? = nil,
                             now: Date, calendar: Calendar = .current) -> Feed {
        build(sources.flatMap { $0.items(now: now) },
              questions: needsYou?.items(now: now) ?? [],
              tasks: tasks.map { TaskFeed(engine: $0).items(now: now) } ?? [],
              isClosed: { needsYou?.rule.isClosed($0) ?? true },
              now: now, calendar: calendar)
    }
}

/// Words for the Today feed.
public enum FeedWords {
    public static let title = "Today"
    public static let needsYouHeading = "Needs you"
    public static let needsYouDetail = "I'll wait for you before I do these."
    public static let thisMorning = "This morning"
    public static let thisAfternoon = "This afternoon"
    public static let thisEvening = "This evening"
    public static let earlier = "Earlier"
    public static let yesterday = "Yesterday"
    public static let didLabel = "Done"
    public static let readyLabel = "Ready for you"
    public static let noticedLabel = "Noticed"
    public static let openTitle = "Open"
    public static let talkTitle = "Talk about it"
    public static let reviewTitle = "Have a look"
    public static let openHint = "Opens it to read."
    public static let talkHint = "Opens the chat with a line ready. Nothing is sent."
    public static let reviewHint = "Opens the question."
    public static let emptyTitle = "A quiet start"
    /// Only what is true today: the chat is right below. Nothing here says
    /// the agent works in the background until a real feed source does.
    /// True whether or not a chat is already going, so it never promises a
    /// new one: a line sent from here joins the chat there is.
    public static let empty = "It's just us for now. Write to me below, and I'll answer in the chat."
    /// VoiceOver's hint on Today's composer, which shares the chat's
    /// placeholder, so the person knows where the words go.
    public static let composerHint = "Sends to the chat and opens it."
    /// Said first on an example card, so VoiceOver never takes it for real
    /// work. A live task card that is an example, such as a scripted task,
    /// also shows it as a tag, since its buttons look like real work.
    public static let exampleMarker = "Example"
    /// Over the example cards. The device promise is made only when `place`
    /// says every word stays here, as with `MemoryWords`.
    public static func sampleNote(_ place: PrivacyPlace) -> String {
        place.staysOnDevice
            ? "These are examples for now. They were made on this device, and nothing was sent or bought."
            : "These are examples for now. Nothing was sent or bought."
    }
    /// Over an example opened to read.
    public static let sampleLabel = "This is an example. Nothing here was really done."
    public static let doneTitle = "Done"

    /// The chat button on a narrow screen, such as "Chat with Pip".
    public static func chatWith(_ name: String) -> String { "Chat with \(name)" }
}
