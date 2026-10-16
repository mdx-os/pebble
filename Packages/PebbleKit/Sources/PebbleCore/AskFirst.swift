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

/// What the agent proposes to do, described in the person's words.
public struct ProposedAction: Sendable, Equatable {
    public let kind: ConsequentialAction
    /// Who or what it goes to, such as "Sam" or "the bakery".
    public let recipient: String
    /// What exactly would go out or be bought.
    public let details: String

    public init(kind: ConsequentialAction, recipient: String, details: String) {
        self.kind = kind
        self.recipient = recipient
        self.details = details
    }

    /// The question shown before anything happens.
    public var question: String {
        switch kind {
        case .send: "Send this to \(recipient)?"
        case .purchase: "Buy this from \(recipient)?"
        case .sharePersonalInfo: "Share this with \(recipient)?"
        }
    }

    public static let yesTitle = "Yes, go ahead"
    public static let noTitle = "Not now"
    public static let declined = "Okay, I won't."
}

/// The person's answer to one question.
public enum AskFirstAnswer: Sendable, Equatable {
    case approved
    case declined
}

/// The rule: the agent asks before it sends, buys or shares, every time.
///
/// There is no setting that turns this off and no "always allow". An answer
/// covers only the exact action it was given for. Anything changed after the
/// person said yes needs a new answer.
public struct AskFirst: Sendable {
    public enum Outcome: Sendable, Equatable {
        case proceed
        case stop
    }

    public init() {}

    /// Every consequential action needs a question. Nothing is exempt.
    public func needsQuestion(_ kind: ConsequentialAction) -> Bool { true }

    /// Decide whether a proposed action may happen.
    ///
    /// - Parameters:
    ///   - action: what the agent is about to do now.
    ///   - answer: the person's answer, if any.
    ///   - answeredFor: the action the person was actually shown.
    public func decide(
        _ action: ProposedAction,
        answer: AskFirstAnswer?,
        answeredFor: ProposedAction?
    ) -> Outcome {
        guard answer == .approved, let shown = answeredFor, shown == action else {
            return .stop
        }
        return .proceed
    }
}
