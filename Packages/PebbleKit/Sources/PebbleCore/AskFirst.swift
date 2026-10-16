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
        self.displayName = Self.tidy(displayName, limit: Self.maxDisplayLength) ?? "someone"
        // Handles are never shortened: the end of an address is often the part that matters.
        self.handle = handle.flatMap { Self.tidy($0, limit: Self.maxHandleLength, truncate: false) }
    }

    /// Name plus handle, so two people with one name read differently.
    public var shownAs: String {
        guard let handle else { return displayName }
        return "\(displayName) at \(handle)"
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

    public init(kind: ConsequentialAction, recipient: Recipient, details: String, price: Price? = nil) {
        self.kind = kind
        self.recipient = recipient
        self.details = details
        self.price = price
    }

    /// The question shown before anything happens.
    public func question(locale: Locale = .current) -> String {
        let who = recipient.shownAs
        switch kind {
        case .send: return "Send this to \(who)?"
        case .purchase:
            guard let price else { return "Buy this from \(who)?" }
            return "Buy this from \(who) for \(price.formatted(locale: locale))?"
        case .sharePersonalInfo: return "Share this with \(who)?"
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

    fileprivate init(request: ConfirmationRequest) {
        self.id = request.id
        self.action = request.action
    }
}

/// A question issued by `AskFirst.ask`. Only `AskFirst` can make one, and
/// only the confirmation sheet turns it into an `Approval`.
public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: ProposedAction

    fileprivate init(action: ProposedAction) {
        self.id = UUID()
        self.action = action
    }

    /// Called by the confirmation sheet when the person taps yes. A test in
    /// `AskFirstGateTests` fails if anything else in the sources calls it.
    package func approve() -> Approval {
        Approval(request: self)
    }
}

/// The rule: the agent asks before it sends, buys or shares, every time.
///
/// There is no "always allow" and no setting that turns this off. There is
/// one rule for the app. It honors only approvals for questions it asked,
/// for the identical action, once.
public final class AskFirst: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case proceed
        case stop
    }

    /// The app's one rule.
    public static let shared = AskFirst()

    private let lock = NSLock()
    private var pending: Set<UUID> = []

    private init() {}

    /// A separate rule for tests, so they don't share state.
    package static func isolated() -> AskFirst { AskFirst() }

    /// Record a question to show the person. Nil when the question can't say
    /// exactly where it goes (no handle that fits in full) or, for a
    /// purchase, how much. Such a question must not be asked.
    public func ask(_ action: ProposedAction) -> ConfirmationRequest? {
        guard action.recipient.handle != nil else { return nil }
        if action.kind == .purchase, action.price == nil { return nil }
        let request = ConfirmationRequest(action: action)
        lock.lock()
        pending.insert(request.id)
        lock.unlock()
        return request
    }

    /// The person said no or closed the question. It can't be approved later.
    public func withdraw(_ request: ConfirmationRequest) {
        lock.lock()
        pending.remove(request.id)
        lock.unlock()
    }

    /// Decide whether an action may happen now. A `.proceed` spends the approval.
    public func decide(_ action: ProposedAction, approval: Approval?) -> Outcome {
        guard let approval, approval.action == action, action.recipient.handle != nil else { return .stop }
        if action.kind == .purchase, action.price == nil { return .stop }
        lock.lock()
        defer { lock.unlock() }
        guard pending.remove(approval.id) != nil else { return .stop }
        return .proceed
    }
}
