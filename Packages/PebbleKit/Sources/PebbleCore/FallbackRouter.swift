import Foundation

/// Where a piece of work can be done, in the order `FallbackRouter` tries.
public enum RouteHop: String, CaseIterable, Sendable, Codable {
    /// What is already kept here: notes, tasks and what the agent remembers.
    case deviceContext = "context"
    /// A system framework the app has, such as the calendar.
    case deviceFramework = "framework"
    /// A web page read through the relay. Leaves the device.
    case relayFetch = "relay"
    /// A longer run elsewhere, for research, many steps or code. Leaves
    /// the device.
    case remoteRun = "remote"
    /// Asking the person. Always there, and always last.
    case askPerson = "person"

    /// The order hops are tried in. Nothing else orders them.
    public static let order: [RouteHop] = [.deviceContext, .deviceFramework, .relayFetch, .remoteRun, .askPerson]

    /// True for a hop that sends something past this device. Such a hop
    /// always shows its preview first, and goes only with a grant or a yes.
    public var leavesDevice: Bool { self == .relayFetch || self == .remoteRun }

    /// Its place in `order`.
    var rank: Int { Self.order.firstIndex(of: self) ?? Self.order.count }
}

/// A system framework a hop may use. A fixed list, so a ledger line names
/// only these and never anything of the person's.
public enum RouteCapability: String, CaseIterable, Sendable, Codable {
    case calendar, reminders, contacts, location, photos

    /// How a reason names it.
    var spoken: String {
        switch self {
        case .calendar: "your calendar"
        case .reminders: "your reminders"
        case .contacts: "your contacts"
        case .location: "where you are"
        case .photos: "your photos"
        }
    }
}

/// Where a framework's permission stands now.
public enum RoutePermission: Sendable, Equatable {
    case granted
    /// Not decided yet, so the system can ask.
    case askable
    case denied
}

/// What the person asked for, as the router sees it: which hops could do
/// it at all. A hop the ask leaves out is skipped as not needed.
public struct RouteAsk: Sendable, Equatable {
    /// The framework that could do it here, if any.
    public let capability: RouteCapability?
    /// Exactly what a relay fetch would send, and where.
    public let fetch: ProposedAction?
    /// Exactly what a remote run would send, and where.
    public let run: ProposedAction?
    /// The asking task's key, so a grant for this task can cover it.
    public let task: String?

    public init(capability: RouteCapability? = nil, fetch: ProposedAction? = nil, run: ProposedAction? = nil,
                task: String? = nil) {
        self.capability = capability
        self.fetch = fetch
        self.run = run
        self.task = task
    }
}

/// Whether anything may leave the device for the router's hops. Off by
/// default, and off without an address to send to, as in a Release build
/// with no endpoint set.
public struct OutsideHelp: Sendable, Equatable {
    public let isOn: Bool

    /// On only when the person turned it on and there is somewhere to go.
    public init(switchedOn: Bool, endpoint: URL?) {
        isOn = switchedOn && endpoint != nil
    }

    public static let off = OutsideHelp(switchedOn: false, endpoint: nil)
}

/// What is available right now. Plain values, so later work can fill it
/// from real sources and tests can fill it by hand.
public struct RouteContext: Sendable, Equatable {
    /// What is already kept here can answer this.
    public var answersFromContext: Bool
    /// Each framework the app has, and its permission. One that is missing
    /// isn't available.
    public var frameworks: [RouteCapability: RoutePermission]
    /// The person is here to answer a system question now.
    public var canAskNow: Bool
    public var outsideHelp: OutsideHelp
    public var relayConfigured: Bool
    public var relaySignedIn: Bool
    public var remoteRunsAllowed: Bool
    /// Remote runs this person has left.
    public var remoteRunsLeft: Int
    /// The grants in force. The router only reads them, through `GrantGate`.
    public var grants: [Grant]
    /// The time grants are checked at.
    public var now: Date

    public init(answersFromContext: Bool = false, frameworks: [RouteCapability: RoutePermission] = [:],
                canAskNow: Bool = false, outsideHelp: OutsideHelp = .off, relayConfigured: Bool = false,
                relaySignedIn: Bool = false, remoteRunsAllowed: Bool = false, remoteRunsLeft: Int = 0,
                grants: [Grant] = [], now: Date) {
        self.answersFromContext = answersFromContext
        self.frameworks = frameworks
        self.canAskNow = canAskNow
        self.outsideHelp = outsideHelp
        self.relayConfigured = relayConfigured
        self.relaySignedIn = relaySignedIn
        self.remoteRunsAllowed = remoteRunsAllowed
        self.remoteRunsLeft = remoteRunsLeft
        self.grants = grants
        self.now = now
    }
}

/// Why a hop was passed over. Each is its own short code for the ledger.
public enum RouteSkip: String, Error, Sendable, Codable {
    /// The ask doesn't use this hop.
    case notNeeded
    /// What is kept here can't answer it.
    case noContext
    /// The framework isn't available, or its permission was turned down.
    case notAllowed
    /// The permission could be asked for, but not right now.
    case cantAskNow
    /// Outside help is off.
    case outsideOff
    case relayNotSetUp
    case signedOut
    case runsOff
    case capReached
    /// A question couldn't say exactly where it goes, so it can't be asked.
    case cantShowWhere
    /// An earlier decision already passed this hop.
    case passed
}

/// A hop passed over, and why.
public struct RouteSkipped: Sendable, Equatable {
    public let hop: RouteHop
    public let why: RouteSkip
}

/// What has to happen before a chosen hop runs.
public enum RouteClearance: Sendable, Equatable {
    /// Nothing: it can start.
    case ready
    /// The system asks for the framework's permission first.
    case systemAsk
    /// A grant covers it. The preview still shows before anything goes.
    case granted(Grant)
    /// No grant covers it: ask first, with the preview. Never a silent send.
    case askFirst
}

/// What leaves the device, shown before a leaving hop runs: the same
/// preview the chat shows, naming exactly where it goes and what goes.
public struct RoutePreview: Sendable, Equatable {
    public let action: ProposedAction

    public var title: String { CloudWords.previewTitle }
    /// The exact place it goes, as the question shows it.
    public var destination: String { CloudWords.previewDestination(action.recipient.shownAs) }
}

/// The router's answer: the one hop chosen, what it needs first, and the
/// hops passed over on the way, each with why.
public struct RouteDecision: Sendable, Equatable {
    public let hop: RouteHop
    public let clearance: RouteClearance
    /// Set for every hop that leaves the device, and only for those.
    public let preview: RoutePreview?
    /// The framework the chosen hop uses, if it is that hop.
    public let capability: RouteCapability?
    /// Every earlier hop, in order, with why it was passed over.
    public let skipped: [RouteSkipped]

    /// True when outside help being off is why a leaving hop was passed.
    public var outsideWasOff: Bool { skipped.contains { $0.why == .outsideOff } }

    /// The reason's code: why this hop.
    public var reason: String {
        switch (hop, clearance) {
        case (.deviceContext, _): "fromContext"
        case (.deviceFramework, .systemAsk): "frameworkAsk"
        case (.deviceFramework, _): "frameworkReady"
        case (_, .granted): "granted"
        case (_, .askFirst): "askFirst"
        case (.askPerson, _): outsideWasOff ? "outsideOff" : "nothingElse"
        default: "ready"
        }
    }

    /// The task ledger's step line: hop, reason code, capability and each
    /// hop passed over. Codes and names only, never the person's words.
    public var ledgerLine: String {
        var parts = ["route hop=\(hop.rawValue)", "reason=\(reason)"]
        if let capability { parts.append("capability=\(capability.rawValue)") }
        if !skipped.isEmpty {
            parts.append("skipped=" + skipped.map { "\($0.hop.rawValue):\($0.why.rawValue)" }.joined(separator: ","))
        }
        return parts.joined(separator: " ")
    }

    /// What the person reads about the choice.
    public var words: String {
        let line: String
        switch hop {
        case .deviceContext: line = RouteWords.fromContext
        case .deviceFramework:
            let spoken = capability?.spoken ?? RouteWords.somethingHere
            line = clearance == .systemAsk ? RouteWords.frameworkAsk(spoken) : RouteWords.frameworkReady(spoken)
        case .relayFetch, .remoteRun:
            let start = hop == .remoteRun ? RouteWords.biggerJob : RouteWords.needsTheWeb
            line = start + " " + (clearance == .askFirst ? RouteWords.askFirst : RouteWords.granted)
        case .askPerson: line = RouteWords.askPerson
        }
        return outsideWasOff ? RouteWords.outsideOff + " " + line : line
    }
}

/// Decides where a piece of work is done. It tries each hop in
/// `RouteHop.order` and stops at the first that can do it; asking the
/// person always can. Pure: no clock, no globals, nothing read or written.
///
/// A hop that leaves the device goes only when outside help is on, always
/// shows its preview first, and needs a grant for that exact action and
/// target, or a yes. The router reads grants and never makes one.
public enum FallbackRouter {
    /// The decision for `ask`. With `after`, only hops later than that one
    /// are tried, as when the person turned down a preview, so a decision
    /// never goes back to an earlier hop. Asking the person is always there.
    public static func route(_ ask: RouteAsk, context: RouteContext, after: RouteHop? = nil) -> RouteDecision {
        var skipped: [RouteSkipped] = []
        let floor = after?.rank ?? -1
        for hop in RouteHop.order where hop != .askPerson {
            guard hop.rank > floor else {
                skipped.append(RouteSkipped(hop: hop, why: .passed))
                continue
            }
            switch check(hop, ask: ask, context: context) {
            case .success(let clearance):
                let action = hop == .relayFetch ? ask.fetch : ask.run
                return RouteDecision(hop: hop, clearance: clearance,
                                     preview: hop.leavesDevice ? action.map(RoutePreview.init) : nil,
                                     capability: hop == .deviceFramework ? ask.capability : nil, skipped: skipped)
            case .failure(let why):
                skipped.append(RouteSkipped(hop: hop, why: why))
            }
        }
        return RouteDecision(hop: .askPerson, clearance: .ready, preview: nil, capability: nil, skipped: skipped)
    }

    /// Writes the decision to the task's ledger as a step line.
    @discardableResult
    public static func record(_ decision: RouteDecision, in ledger: inout TaskLedger, at time: Date,
                              artifacts: any TaskArtifactResolving = NoArtifacts()) -> Bool {
        ledger.append(.working(step: decision.ledgerLine), at: time, artifacts: artifacts)
    }

    private static func check(_ hop: RouteHop, ask: RouteAsk, context: RouteContext) -> Result<RouteClearance, RouteSkip> {
        switch hop {
        case .deviceContext:
            return context.answersFromContext ? .success(.ready) : .failure(.noContext)
        case .deviceFramework:
            guard let capability = ask.capability else { return .failure(.notNeeded) }
            switch context.frameworks[capability] {
            case .granted: return .success(.ready)
            case .askable: return context.canAskNow ? .success(.systemAsk) : .failure(.cantAskNow)
            case .denied, nil: return .failure(.notAllowed)
            }
        case .relayFetch:
            guard let action = ask.fetch else { return .failure(.notNeeded) }
            guard context.outsideHelp.isOn else { return .failure(.outsideOff) }
            guard context.relayConfigured else { return .failure(.relayNotSetUp) }
            guard context.relaySignedIn else { return .failure(.signedOut) }
            return leaving(action, ask: ask, context: context)
        case .remoteRun:
            guard let action = ask.run else { return .failure(.notNeeded) }
            guard context.outsideHelp.isOn else { return .failure(.outsideOff) }
            guard context.remoteRunsAllowed else { return .failure(.runsOff) }
            guard context.remoteRunsLeft > 0 else { return .failure(.capReached) }
            return leaving(action, ask: ask, context: context)
        case .askPerson:
            return .success(.ready)
        }
    }

    /// A leaving hop's clearance: the grant that covers this exact action
    /// and target, or ask first.
    private static func leaving(_ action: ProposedAction, ask: RouteAsk,
                                context: RouteContext) -> Result<RouteClearance, RouteSkip> {
        guard AskFirst.canAsk(action) else { return .failure(.cantShowWhere) }
        var covered: Grant?
        if case .allowed(let grant) = GrantGate.check(action, task: ask.task, grants: context.grants, now: context.now) {
            covered = grant
        }
        return .success(covered.map(RouteClearance.granted) ?? .askFirst)
    }
}

/// Words for why work went where it did. docs/VOICE.md: plain, kind, no
/// dashes, and no promise about the device.
public enum RouteWords {
    public static let fromContext = "I can do this with what I already know."
    public static func frameworkReady(_ what: String) -> String { "I can do this with \(what)." }
    public static func frameworkAsk(_ what: String) -> String { "I can do this with \(what) once you allow it." }
    static let somethingHere = "what this app can reach"
    public static let needsTheWeb = "I need to look this up online."
    public static let biggerJob = "This is a bigger job, so I need to go online for it."
    public static let granted = "You said yes to this before. I'll still show you exactly what goes first."
    public static let askFirst = "I'll show you exactly what goes and ask you first."
    public static let askPerson = "I can't do this on my own yet. Can you help me with it?"
    public static let outsideOff = "Outside help is off, so I won't go online for this."
}
