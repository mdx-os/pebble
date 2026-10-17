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

    /// What VoiceOver says first, so each card reads as one thought.
    public var spokenKind: String {
        switch kind {
        case .did: FeedWords.didLabel
        case .ready: FeedWords.readyLabel
        case .noticed: FeedWords.noticedLabel
        case .needsYou: FeedWords.needsYouHeading
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

    public var title: String {
        switch self {
        case .open: FeedWords.openTitle
        case .talk: FeedWords.talkTitle
        case .review: FeedWords.reviewTitle
        }
    }

    /// What VoiceOver says the card does, such as "Opens the question."
    public var hint: String {
        switch self {
        case .open: FeedWords.openHint
        case .talk: FeedWords.talkHint
        case .review: FeedWords.reviewHint
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
    private let lock = NSLock()
    private var waiting: [Waiting] = []
    private let locale: Locale

    public init(rule: AskFirst = .shared, locale: Locale = .current) {
        self.rule = rule
        self.locale = locale
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
        defer { lock.unlock() }
        // Asked and recorded under one lock, so the list keeps the rule's order.
        guard let request = rule.ask(action) else { return nil }
        waiting.append(Waiting(request: request, askedAt: time, onApprove: onApprove))
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
    }

    /// The sheet closed without a yes. The sheet has already withdrawn the
    /// question; this takes the card away.
    public func dismissed(_ request: ConfirmationRequest) {
        lock.lock()
        waiting.removeAll { $0.request.id == request.id }
        lock.unlock()
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
    public let groups: [FeedGroup]

    public var isEmpty: Bool { needsYou.isEmpty && groups.isEmpty }
    public var showsNeedsYou: Bool { !needsYou.isEmpty }
    public var count: Int { needsYou.count + groups.reduce(0) { $0 + $1.items.count } }

    /// `items` can never ask anything: question cards and questions hidden
    /// in other cards are dropped. Only `questions`, from `NeedsYou`, are
    /// pinned, in the order given, and only while `isClosed` says the rule
    /// still holds them open.
    public static func build(_ items: [FeedItem], questions: [FeedItem] = [],
                             isClosed: (ConfirmationRequest) -> Bool = { _ in true },
                             now: Date, calendar: Calendar = .current) -> Feed {
        let pinned = questions.filter { item in
            guard item.kind == .needsYou, let request = item.request else { return false }
            return !isClosed(request)
        }
        let rest = items
            .filter { $0.kind != .needsYou && $0.request == nil }
            .sorted { ($0.time, $0.id) > ($1.time, $1.id) }
        let byPeriod = Dictionary(grouping: rest) { FeedPeriod.of($0.time, now: now, calendar: calendar) }
        let groups = FeedPeriod.allCases.compactMap { period in
            byPeriod[period].map { FeedGroup(period: period, items: $0) }
        }
        return Feed(needsYou: pinned, groups: groups)
    }

    /// The feed from its sources, with questions taken only from `needsYou`.
    /// A `NeedsYou` passed among the sources asks nothing.
    public static func build(from sources: [any FeedSource], needsYou: NeedsYou? = nil,
                             now: Date, calendar: Calendar = .current) -> Feed {
        build(sources.flatMap { $0.items(now: now) },
              questions: needsYou?.items(now: now) ?? [],
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
    public static let empty = "When I finish something for you, it will show up here. I'll only ask when a choice is yours to make."
    public static let emptyActionTitle = "Say hello"
    public static let sampleNote = "These are examples for now. They were made on this device, and nothing was sent or bought."
    /// Over an example opened to read.
    public static let sampleLabel = "This is an example. Nothing here was really done."
    public static let doneTitle = "Done"

    /// The chat button on a narrow screen, such as "Chat with Pip".
    public static func chatWith(_ name: String) -> String { "Chat with \(name)" }
}
