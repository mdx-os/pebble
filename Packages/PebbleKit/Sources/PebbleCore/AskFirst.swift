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
}

/// Who an action goes to. Identity is `id`, a resolved contact, address or
/// merchant. Two people both called Sam are different recipients.
public struct Recipient: Sendable, Equatable, Hashable {
    /// Stable identity, such as a contact ID plus the exact address used.
    public let id: String
    /// Shown in the question only. Never used to match.
    public let displayName: String

    public static let maxDisplayLength = 40

    public init(id: String, displayName: String) {
        self.id = id
        let collapsed = displayName
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        self.displayName = collapsed.count > Self.maxDisplayLength
            ? String(collapsed.prefix(Self.maxDisplayLength)) + "..."
            : (collapsed.isEmpty ? "someone" : collapsed)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// An exact amount of money, in minor units such as cents.
public struct Price: Sendable, Equatable, Hashable {
    public let minorUnits: Int
    /// ISO 4217 code, such as "CAD".
    public let currency: String

    public init(minorUnits: Int, currency: String) {
        self.minorUnits = minorUnits
        self.currency = currency.uppercased()
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

    public init(kind: ConsequentialAction, recipient: Recipient, details: String, price: Price? = nil) {
        self.kind = kind
        self.recipient = recipient
        self.details = details
        self.price = price
    }

    /// The question shown before anything happens.
    public var question: String {
        let name = recipient.displayName
        switch kind {
        case .send: return "Send this to \(name)?"
        case .purchase: return "Buy this from \(name)?"
        case .sharePersonalInfo: return "Share this with \(name)?"
        }
    }

    public static let yesTitle = "Yes, go ahead"
    public static let noTitle = "Not now"
    public static let declined = "Okay, I won't."
}

/// A yes for exactly one action. Only the confirmation surface can create
/// one, through `ConfirmationRequest.approve()`. Code that wants to act
/// cannot make its own.
public struct Approval: Sendable, Equatable {
    public let id: UUID
    public let action: ProposedAction

    fileprivate init(action: ProposedAction) {
        self.id = UUID()
        self.action = action
    }
}

/// The question as shown to the person. The confirmation sheet holds one of
/// these and turns a tap on yes into an `Approval`.
public struct ConfirmationRequest: Sendable, Equatable {
    public let action: ProposedAction

    public init(action: ProposedAction) {
        self.action = action
    }

    /// Called by the confirmation sheet when the person taps yes. Package
    /// access keeps it out of reach of code outside the app's own packages.
    package func approve() -> Approval {
        Approval(action: action)
    }
}

/// The rule: the agent asks before it sends, buys or shares, every time.
///
/// There is no "always allow" and no setting that turns this off. An
/// approval covers only the exact action it was given for and can be spent
/// once. Anything changed after the yes needs a new one.
public final class AskFirst: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case proceed
        case stop
    }

    private let lock = NSLock()
    private var spent: Set<UUID> = []

    public init() {}

    /// Decide whether an action may happen now. A `.proceed` spends the approval.
    public func decide(_ action: ProposedAction, approval: Approval?) -> Outcome {
        guard let approval, approval.action == action else { return .stop }
        if action.kind == .purchase, action.price == nil { return .stop }
        lock.lock()
        defer { lock.unlock() }
        guard spent.insert(approval.id).inserted else { return .stop }
        return .proceed
    }
}
