import Foundation

/// Something the agent could do that reaches past this device or spends
/// something of the person's.
public enum ConsequentialAction: String, CaseIterable, Codable, Sendable {
    /// A message, email or post that someone else will read.
    case send
    /// Anything that spends money.
    case purchase
    /// Giving out the person's details, such as an address, phone number or health facts.
    case sharePersonalInfo
    /// Keeping something new in the person's notes that they didn't type,
    /// such as a task's digest. It stays with them, but it is theirs to
    /// decide, so it is asked like the rest.
    case save
}

/// Who an action goes to: a resolved contact, address or merchant `id`, plus
/// the name and exact handle the person is shown. All three must match for
/// an approval to hold, so what runs is exactly what was shown.
public struct Recipient: Sendable, Equatable, Hashable {
    /// Stable identity, such as a contact ID plus the exact address used.
    public let id: String
    /// Shown in the question only. Never used to match.
    public let displayName: String
    /// The exact address, number or site it goes to, as shown to the person.
    /// Nil when none was given or it was too long to show in full; either
    /// way `AskFirst.ask` refuses to ask. The resolver that builds a
    /// recipient must derive the handle from the same record as `id`.
    public let handle: String?

    public static let maxDisplayLength = 40

    public static let maxHandleLength = 254

    public init(id: String, displayName: String, handle: String? = nil) {
        self.id = id
        self.displayName = Self.tidyName(displayName) ?? "someone"
        // Handles are shown exactly or not at all: never shortened, never
        // cleaned. Hidden characters or odd spacing make the handle nil, and
        // then nothing is asked.
        self.handle = handle.flatMap { raw in
            let clean = Self.tidy(raw, limit: Self.maxHandleLength, truncate: false)
            return clean == raw && !AskFirst.hasHiddenScalars(raw) ? clean : nil
        }
    }

    /// What the question names: the exact handle when there is one. The
    /// display name is free text, so it is shown on its own line, never in
    /// the same sentence as the handle or price where it could pose as them.
    public var shownAs: String { handle ?? displayName }

    private static func tidyName(_ text: String) -> String? {
        // A name must not pose as an address: drop "@" so only the handle carries one.
        tidy(text.replacingOccurrences(of: "@", with: " "), limit: maxDisplayLength)
    }

    private static func tidy(_ text: String, limit: Int, truncate: Bool = true) -> String? {
        let collapsed = text
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
            .map(String.init).joined()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return nil }
        guard collapsed.count > limit else { return collapsed }
        return truncate ? String(collapsed.prefix(limit)) + "..." : nil
    }
}

/// An exact amount of money in the currency's smallest unit (cents for CAD,
/// yen for JPY, fils for KWD).
public struct Price: Sendable, Equatable, Hashable {
    public let minorUnits: Int
    /// ISO 4217 code, such as "CAD".
    public let currency: String

    /// Nil unless the amount is above zero and the code is three letters.
    public init?(minorUnits: Int, currency: String) {
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard minorUnits > 0, code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        self.minorUnits = minorUnits
        self.currency = code
    }

    /// Digits after the decimal point for this currency, from ISO 4217.
    /// Every currency not listed here uses two.
    public var fractionDigits: Int {
        switch currency {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
             "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF":
            return 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            return 3
        case "CLF", "UYW":
            return 4
        default:
            return 2
        }
    }

    /// The amount as the person will be charged, such as "CA$14.50".
    public func formatted(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = locale
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        var amount = Decimal(minorUnits)
        for _ in 0..<fractionDigits { amount /= 10 }
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }
}

/// What the agent proposes to do, described in the person's words.
public struct ProposedAction: Sendable, Equatable, Hashable {
    public let kind: ConsequentialAction
    public let recipient: Recipient
    /// What exactly would go out or be bought.
    public let details: String
    /// Required for a purchase. A purchase without a price is never approved.
    public let price: Price?
    /// What will happen once the person says yes, in the agent's words, such
    /// as "I'll hold Saturday at 10:30 for you." Part of what is approved, so
    /// a yes for one outcome never covers another.
    public let outcome: String?

    public init(kind: ConsequentialAction, recipient: Recipient, details: String, price: Price? = nil,
                outcome: String? = nil) {
        self.kind = kind
        self.recipient = recipient
        self.details = details
        self.price = price
        self.outcome = outcome
    }

    /// The question shown before anything happens.
    public func question(locale: Locale = .current) -> String {
        let who = recipient.shownAs
        switch kind {
        case .send: return "Send this to \(who)?"
        case .purchase:
            guard let price else { return "Buy this from \(who)?" }
            return "Pay \(price.formatted(locale: locale)) to \(who)?"
        case .sharePersonalInfo: return "Share this with \(who)?"
        case .save: return "Keep this in \(who)?"
        }
    }

    public var question: String { question() }

    public static let yesTitle = "Yes, go ahead"
    public static let noTitle = "Not now"
    public static let declined = "Okay, I won't."
}

/// A yes for exactly one action, tied to the question that was asked.
public struct Approval: Sendable, Equatable {
    /// Same as the request it answers. Tapping yes twice gives the same id.
    public let id: UUID
    public let action: ProposedAction
    /// The asking task's key, as the question had it. Nil when no task asked.
    public let task: String?

    fileprivate init(request: ConfirmationRequest) {
        self.id = request.id
        self.action = request.action
        self.task = request.task
    }
}

/// A question issued by `AskFirst.ask`. Only `AskFirst` can make one, and
/// only the confirmation sheet turns it into an `Approval`.
public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: ProposedAction
    /// The key of the task that asked, unique to that task and its engine,
    /// so the sheet can offer a yes for this task. Nil when no task asked.
    public let task: String?

    fileprivate init(action: ProposedAction, task: String? = nil) {
        self.id = UUID()
        self.action = action
        self.task = task
    }

    /// Called by the confirmation sheet when the person taps yes. A test in
    /// `AskFirstGateTests` fails if anything else in the sources calls it.
    ///
    /// It asks the rule nothing, and the rule honors an approval for a
    /// question still open, so this alone would let code say yes without
    /// the sheet. That gate test is what stops it: only the sheet, and
    /// `sayYes` here, may call it. Tests call it to prove a yes is refused
    /// once a question has closed or its task has moved on.
    package func approve() -> Approval {
        Approval(request: self)
    }
}

/// The rule: the agent asks before it sends, buys or shares, whenever no
/// grant the person gave covers that exact step.
///
/// There is no setting that turns this off. There is one rule for the app.
/// It honors only approvals for questions it asked, for the identical
/// action, once. A yes that lasts longer is a `Grant`, which only the
/// question sheet's answer can make, and the rule alone decides when one
/// covers a step (`ask(_:forTask:)`, through `GrantGate`).
public final class AskFirst: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case proceed
        case stop
    }

    /// The app's one rule.
    public static let shared = AskFirst()

    /// How long a question stays open. After this an answer can't approve
    /// it; the agent has to ask again with what is true now.
    public static let defaultWindow: TimeInterval = 5 * 60

    /// How long a yes given in time stays good while the action is checked.
    /// Short, so little can change between the yes and what happens.
    public static let yesGrace: Duration = .seconds(30)

    /// When a question was asked and, once the person said yes in time,
    /// when they said it.
    private struct Open {
        let askedAt: ContinuousClock.Instant
        var yesAt: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var pending: [UUID: Open] = [:]
    /// Questions withdrawn while still open, by when they were asked, so
    /// `wasWithdrawn` can tell a no from a timeout. Each is kept only as
    /// long as the question could have stayed open. Ids only.
    private var withdrawn: [UUID: ContinuousClock.Instant] = [:]
    private let window: Duration
    /// A monotonic clock that keeps counting while the device sleeps.
    /// Changing the date and time in Settings can't move it, so it can't
    /// bring a timed out question back.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The person's grants. Until the app gives the rule its book, every
    /// consequential step needs a fresh yes.
    private var book: GrantBook?

    private init(
        window: TimeInterval = AskFirst.defaultWindow,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        grants: GrantBook? = nil
    ) {
        self.window = .milliseconds(Int64((window * 1000).rounded()))
        self.now = now
        self.book = grants
    }

    /// A separate rule for tests, so they don't share state. Tests can pass
    /// a clock to move time forward, and a book of grants.
    package static func isolated(
        window: TimeInterval = AskFirst.defaultWindow,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        grants: GrantBook? = nil
    ) -> AskFirst {
        AskFirst(window: window, now: now, grants: grants)
    }

    /// The grants this rule consults before it asks, if any.
    public var grants: GrantBook? {
        lock.lock()
        defer { lock.unlock() }
        return book
    }

    /// Gives the rule its book of grants, once, as the app starts. A later
    /// call changes nothing, so the book can't be swapped for another.
    public func keepGrants(in grants: GrantBook) {
        lock.lock()
        if book == nil { book = grants }
        lock.unlock()
    }

    /// What `ask(_:forTask:)` decided.
    public enum Asked: Sendable, Equatable {
        /// A grant covers the step: it goes ahead without a question, and
        /// its receipt names the grant.
        case granted(GrantedStep)
        /// No grant covers it: the question to show the person.
        case asking(ConfirmationRequest)
        /// It can't be asked, so it must not happen.
        case cannotAsk
    }

    /// Asks about a task's step, after `GrantGate` looks at the grants
    /// first. `task` is the task's key, unique to that task and its engine.
    /// With no grant that covers it, this is `ask(_:)`, with the key on the
    /// question so the sheet can offer a yes for this task.
    public func ask(_ action: ProposedAction, forTask task: String) -> Asked {
        guard Self.canAsk(action) else { return .cannotAsk }
        if let step = grants?.use(action, task: task) { return .granted(step) }
        return ask(action, askedAgo: .zero, task: task).map(Asked.asking) ?? .cannotAsk
    }

    /// A task ended, so its task grants end too.
    public func taskEnded(_ task: String) {
        grants?.taskEnded(task)
    }

    /// Record a question to show the person. Nil when the question can't say
    /// exactly where it goes (no handle that fits in full) or, for a
    /// purchase, how much. Such a question must not be asked.
    public func ask(_ action: ProposedAction) -> ConfirmationRequest? {
        ask(action, askedAgo: .zero)
    }

    /// How long a question stays open, in seconds.
    public var questionWindow: TimeInterval {
        Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
    }

    /// Asks again, after the app was closed and opened, a question first
    /// asked `age` seconds ago. It keeps the deadline it had: its window
    /// counts from the first time it was asked, never from now, so opening
    /// the app again never buys it more time. Nil, as for `ask`, when it
    /// can't be asked, and nil when its time is already up or `age` is
    /// below zero, as when the date was moved back.
    ///
    /// `age` comes from the device's wall clock, since nothing else lasts
    /// while the app is closed. Setting that clock back while the app is
    /// closed can give a question more time, so the deadline holds only
    /// within one launch. The question still needs a fresh yes.
    ///
    /// `task` is the asking task's key in this launch, so the sheet can
    /// still offer a yes for this task. No grant is looked at: a question
    /// already asked is answered by the person.
    public func askAgain(_ action: ProposedAction, askedAgo age: TimeInterval,
                         forTask task: String? = nil) -> ConfirmationRequest? {
        guard age.isFinite, age >= 0, age <= questionWindow else { return nil }
        return ask(action, askedAgo: .milliseconds(Int64((age * 1000).rounded(.up))), task: task)
    }

    /// False when a question about `action` can't say exactly where it
    /// goes, or for a purchase how much, so it must not be asked.
    static func canAsk(_ action: ProposedAction) -> Bool {
        guard action.recipient.handle != nil else { return false }
        // What is shown must read the same as what goes out: no hidden or
        // reordering characters in the details or the outcome.
        if hasHiddenScalars(action.details) { return false }
        if let outcome = action.outcome, hasHiddenScalars(outcome) { return false }
        if action.kind == .purchase, action.price == nil { return false }
        return true
    }

    private func ask(_ action: ProposedAction, askedAgo age: Duration, task: String? = nil) -> ConfirmationRequest? {
        guard Self.canAsk(action) else { return nil }
        let request = ConfirmationRequest(action: action, task: task)
        lock.lock()
        let time = now()
        pending = pending.filter { isOpen($0.value) || isFreshYes($0.value) }
        withdrawn = withdrawn.filter { isOpen(Open(askedAt: $0.value)) }
        pending[request.id] = Open(askedAt: time.advanced(by: .zero - age))
        lock.unlock()
        return request
    }

    /// True when text carries anything a person can't see: control and format
    /// characters, default ignorable code points (variation selectors, fillers)
    /// and the blank braille cell. Newlines and tabs are fine, and so are the
    /// joiner and emoji selector right after an emoji.
    static func hasHiddenScalars(_ text: String) -> Bool {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            if scalar == "\n" || scalar == "\t" { continue }
            if (scalar.value == 0xFE0F || scalar.value == 0x200D),
               let previous, previous.properties.isEmoji || previous.value == 0x200D { continue }
            let p = scalar.properties
            if p.generalCategory == .format || p.generalCategory == .control
                || p.isDefaultIgnorableCodePoint || scalar.value == 0x2800 || scalar.value == 0x3164
                || scalar.value == 0x115F || scalar.value == 0x1160 || scalar.value == 0xFFA0 {
                return true
            }
        }
        return false
    }

    /// The person said no or closed the question. It can't be approved later.
    public func withdraw(_ request: ConfirmationRequest) {
        lock.lock()
        // One that had already timed out stays a timeout.
        if let open = pending.removeValue(forKey: request.id), isOpen(open) || isFreshYes(open) {
            withdrawn[request.id] = open.askedAt
        }
        lock.unlock()
    }

    /// True when the question closed because it was withdrawn while still
    /// open, not because its time ran out. Only says why; it never opens
    /// or closes anything.
    public func wasWithdrawn(_ request: ConfirmationRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return withdrawn[request.id] != nil
    }

    /// True once a yes can no longer be given: the question expired, was
    /// withdrawn, or was checked. A yes already given in time but not yet
    /// checked keeps it open until `yesGrace` runs out.
    public func isClosed(_ request: ConfirmationRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let open = pending[request.id] else { return true }
        if open.yesAt != nil {
            if isFreshYes(open) { return false }
            pending[request.id] = nil
            return true
        }
        if !isOpen(open) {
            pending[request.id] = nil
            return true
        }
        return false
    }

    /// Seconds before an open question times out, or nil once it is closed
    /// or already answered. Only reads: it never opens or closes anything.
    public func timeLeft(_ request: ConfirmationRequest) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let open = pending[request.id], open.yesAt == nil, isOpen(open) else { return nil }
        let left = window - (now() - open.askedAt)
        return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
    }

    /// What the sheet gets when the person taps yes.
    package enum Yes: Equatable {
        case approved(Approval)
        case timedOut
    }

    /// The person tapped yes. Inside the window this records the time of the
    /// yes, so the action can still go ahead if it is checked a moment
    /// later. After the window it approves nothing and says so.
    package func sayYes(to request: ConfirmationRequest) -> Yes {
        lock.lock()
        defer { lock.unlock() }
        guard var open = pending[request.id] else { return .timedOut }
        // A second tap on yes changes nothing; the first one stands.
        if open.yesAt != nil {
            return isFreshYes(open) ? .approved(request.approve()) : .timedOut
        }
        // A late yes drops the question, so a later check reads `.stop`.
        guard isOpen(open) else {
            pending[request.id] = nil
            return .timedOut
        }
        open.yesAt = now()
        pending[request.id] = open
        return .approved(request.approve())
    }

    /// Decide whether an action may happen now. A `.proceed` spends the approval.
    public func decide(_ action: ProposedAction, approval: Approval?) -> Outcome {
        verdict(action, approval: approval) == .proceed ? .proceed : .stop
    }

    /// Like `decide`, but says when the stop was a timeout, so the caller can
    /// tell the person instead of failing quietly.
    public enum Verdict: Sendable, Equatable {
        case proceed
        case stop
        case timedOut
    }

    /// A `.proceed` spends the approval. A yes given inside the window counts
    /// even if this check runs a little later; a yes after it never does.
    public func verdict(_ action: ProposedAction, approval: Approval?) -> Verdict {
        guard let approval, approval.action == action, action.recipient.handle != nil else { return .stop }
        if action.kind == .purchase, action.price == nil { return .stop }
        lock.lock()
        defer { lock.unlock() }
        guard let open = pending.removeValue(forKey: approval.id) else { return .stop }
        if open.yesAt != nil {
            return isFreshYes(open) ? .proceed : .timedOut
        }
        return isOpen(open) ? .proceed : .timedOut
    }

    /// A yes given inside the window, still recent enough to act on. A yes
    /// is never a standing permission: it lapses `yesGrace` after it was given.
    private func isFreshYes(_ open: Open) -> Bool {
        guard let yesAt = open.yesAt else { return false }
        let since = now() - yesAt
        return yesAt - open.askedAt <= window && since >= .zero && since <= Self.yesGrace
    }

    /// The one test for whether a question is still open.
    private func isOpen(_ open: Open) -> Bool {
        let age = now() - open.askedAt
        return age >= .zero && age <= window
    }
}
