import Foundation
@testable import PebbleCore
import Testing

/// What the router is asked about and checked against.
enum RouteFixtures {
    static let now = GrantFixtures.morning + 60
    static let relay = Recipient(id: "relay:fetch", displayName: "Web reader", handle: "relay.example")
    static let runner = Recipient(id: "runs:remote", displayName: "Long runs", handle: "runs.example")
    /// Words of the person's own, which no ledger line may carry.
    static let fetchDetails = "Opening hours of the Riverside pool for Sam"
    static let runDetails = "Find three dentists near 12 Elm Street open Saturdays"

    static let fetch = ProposedAction(kind: .send, recipient: relay, details: fetchDetails)
    static let run = ProposedAction(kind: .send, recipient: runner, details: runDetails)

    /// Asks for every hop, with the calendar as its framework.
    static func ask(task: String? = nil) -> RouteAsk {
        RouteAsk(capability: .calendar, fetch: fetch, run: run, task: task)
    }

    static let on = OutsideHelp(switchedOn: true, endpoint: URL(string: "https://relay.example"))

    /// Everything but the device hops ready, with no grants.
    static func outside(grants: [Grant] = []) -> RouteContext {
        RouteContext(outsideHelp: on, relayConfigured: true, relaySignedIn: true, remoteRunsAllowed: true,
                     remoteRunsLeft: 3, grants: grants, now: now)
    }

    static func always(_ action: ProposedAction) throws -> Grant {
        try #require(try GrantFixtures.grant(.always, for: action))
    }
}

/// The fallback router: one fixed order, leaving hops behind a preview and
/// a grant or a yes, outside help off by default, every decision in the
/// ledger, and asking the person always there at the end.
struct FallbackRouterTests {
    typealias R = RouteFixtures

    /// Every combination of what is available, against the rules written
    /// out on their own here.
    @Test func fallbackTableCoversEveryCombination() throws {
        let fetchGrant = try R.always(R.fetch)
        let runGrant = try R.always(R.run)
        let permissions: [RoutePermission?] = [nil, .denied, .askable, .granted]
        let grantSets: [[Grant]] = [[], [fetchGrant], [runGrant], [fetchGrant, runGrant]]
        var count = 0
        for context in [false, true] {
            for permission in permissions {
                for askNow in [false, true] {
                    for outside in [false, true] {
                        for configured in [false, true] {
                            for signedIn in [false, true] {
                                for runs in [false, true] {
                                    for left in [0, 1] {
                                        for grants in grantSets {
                                            count += 1
                                            let routeContext = RouteContext(
                                                answersFromContext: context,
                                                frameworks: permission.map { [.calendar: $0] } ?? [:],
                                                canAskNow: askNow,
                                                outsideHelp: outside ? R.on : .off,
                                                relayConfigured: configured, relaySignedIn: signedIn,
                                                remoteRunsAllowed: runs, remoteRunsLeft: left,
                                                grants: grants, now: R.now)
                                            let decision = FallbackRouter.route(R.ask(), context: routeContext)

                                            let relayUp = outside && configured && signedIn
                                            let runUp = outside && runs && left > 0
                                            let expected: RouteHop
                                            if context { expected = .deviceContext }
                                            else if permission == .granted || (permission == .askable && askNow) {
                                                expected = .deviceFramework
                                            } else if relayUp { expected = .relayFetch }
                                            else if runUp { expected = .remoteRun }
                                            else { expected = .askPerson }
                                            #expect(decision.hop == expected, "\(routeContext)")

                                            try checkInvariants(decision, context: routeContext)
                                            if expected == .relayFetch {
                                                #expect(decision.clearance == (grants.contains(fetchGrant)
                                                    ? .granted(fetchGrant) : .askFirst))
                                            }
                                            if expected == .remoteRun {
                                                #expect(decision.clearance == (grants.contains(runGrant)
                                                    ? .granted(runGrant) : .askFirst))
                                            }
                                            if expected == .deviceFramework {
                                                #expect(decision.clearance == (permission == .granted ? .ready : .systemAsk))
                                            }
                                            if !outside, expected == .askPerson {
                                                #expect(decision.outsideWasOff)
                                                #expect(decision.words.hasPrefix(RouteWords.outsideOff))
                                            }
                                            for after in RouteHop.order {
                                                let later = FallbackRouter.route(R.ask(), context: routeContext, after: after)
                                                #expect(later.hop.rank > after.rank || later.hop == .askPerson)
                                                try checkInvariants(later, context: routeContext)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(count == 2 * 4 * 2 * 2 * 2 * 2 * 2 * 2 * 4)
    }

    /// What holds for every decision, whatever was available.
    private func checkInvariants(_ decision: RouteDecision, context: RouteContext) throws {
        // Leaving hops show the preview and never go without a grant or a yes.
        #expect((decision.preview != nil) == decision.hop.leavesDevice)
        if decision.hop.leavesDevice {
            #expect(context.outsideHelp.isOn)
            #expect(decision.clearance != .ready && decision.clearance != .systemAsk)
            if case .granted(let grant) = decision.clearance {
                // Only a grant the person gave: the router makes none.
                #expect(context.grants.contains(grant))
            }
        } else {
            #expect(decision.clearance != .askFirst)
            if case .granted = decision.clearance { Issue.record("a grant on a hop that stays") }
        }
        // Every earlier hop is accounted for, in order, and no later one.
        #expect(decision.skipped.map(\.hop) == Array(RouteHop.order.prefix(decision.hop.rank)))
        // The ledger line carries codes, never the person's words.
        for words in [R.fetchDetails, R.runDetails, "relay.example", "runs.example", "Web reader", "Long runs", "Sam"] {
            #expect(!decision.ledgerLine.contains(words))
        }
        #expect(!decision.words.isEmpty)
    }

    @Test func fallbackTriesTheHopsInTheirFixedOrder() throws {
        #expect(RouteHop.order == [.deviceContext, .deviceFramework, .relayFetch, .remoteRun, .askPerson])
        var context = R.outside(grants: [try R.always(R.fetch), try R.always(R.run)])
        #expect(FallbackRouter.route(R.ask(), context: context).hop == .relayFetch)
        context.frameworks = [.calendar: .granted]
        #expect(FallbackRouter.route(R.ask(), context: context).hop == .deviceFramework)
        context.answersFromContext = true
        #expect(FallbackRouter.route(R.ask(), context: context).hop == .deviceContext)
        // A remote run only once the relay can't.
        context = R.outside()
        context.relaySignedIn = false
        let decision = FallbackRouter.route(R.ask(), context: context)
        #expect(decision.hop == .remoteRun)
        #expect(decision.skipped.map(\.why) == [.noContext, .notAllowed, .signedOut])
    }

    @Test func fallbackLeavingHopsAlwaysShowThePreview() throws {
        for grants in [[], [try R.always(R.fetch)]] {
            let decision = FallbackRouter.route(R.ask(), context: R.outside(grants: grants))
            #expect(decision.hop.leavesDevice)
            let preview = try #require(decision.preview)
            #expect(preview.action == R.fetch)
            #expect(preview.title == CloudWords.previewTitle)
            #expect(preview.destination == CloudWords.previewDestination("relay.example"))
        }
        var context = R.outside()
        context.relayConfigured = false
        #expect(FallbackRouter.route(R.ask(), context: context).preview?.action == R.run)
        // A hop that stays never shows one.
        context.answersFromContext = true
        #expect(FallbackRouter.route(R.ask(), context: context).preview == nil)
    }

    @Test func fallbackAsksFirstWithoutAGrantForThatExactActionAndTarget() throws {
        #expect(FallbackRouter.route(R.ask(), context: R.outside()).clearance == .askFirst)
        // A grant for another target covers nothing here.
        let elsewhere = try R.always(GrantFixtures.send())
        #expect(FallbackRouter.route(R.ask(), context: R.outside(grants: [elsewhere])).clearance == .askFirst)
        // Nor does one for the relay that the run's target doesn't share.
        var runOnly = R.outside(grants: [try R.always(R.fetch)])
        runOnly.relaySignedIn = false
        #expect(FallbackRouter.route(R.ask(), context: runOnly).clearance == .askFirst)
        // A task grant covers its own task only.
        let forTask = try #require(try GrantFixtures.grant(.forThisTask, for: R.fetch, task: "task:one"))
        #expect(FallbackRouter.route(R.ask(task: "task:two"), context: R.outside(grants: [forTask])).clearance == .askFirst)
        #expect(FallbackRouter.route(R.ask(task: "task:one"), context: R.outside(grants: [forTask])).clearance
            == .granted(forTask))
        // A grant made later than now covers nothing.
        let early = RouteContext(outsideHelp: R.on, relayConfigured: true, relaySignedIn: true,
                                 grants: [try R.always(R.fetch)], now: GrantFixtures.morning - 1)
        #expect(FallbackRouter.route(R.ask(), context: early).clearance == .askFirst)
        // A target with no exact handle can't be shown, so it can't be asked.
        let noHandle = ProposedAction(kind: .send, recipient: Recipient(id: "relay", displayName: "Relay"),
                                      details: R.fetchDetails)
        let decision = FallbackRouter.route(RouteAsk(fetch: noHandle), context: R.outside())
        #expect(decision.hop == .askPerson)
        #expect(decision.skipped.map(\.why) == [.noContext, .notNeeded, .cantShowWhere, .notNeeded])
    }

    @Test func fallbackOutsideHelpOffSkipsLeavingHopsAndSaysSo() throws {
        let grants = [try R.always(R.fetch), try R.always(R.run)]
        var context = R.outside(grants: grants)
        // Off by default, and off with no endpoint even when switched on.
        for off in [OutsideHelp.off, OutsideHelp(switchedOn: true, endpoint: nil),
                    OutsideHelp(switchedOn: false, endpoint: URL(string: "https://relay.example"))] {
            #expect(!off.isOn)
            context.outsideHelp = off
            let decision = FallbackRouter.route(R.ask(), context: context)
            #expect(decision.hop == .askPerson)
            #expect(decision.skipped.suffix(2).map(\.why) == [.outsideOff, .outsideOff])
            #expect(decision.reason == "outsideOff")
            #expect(decision.words == RouteWords.outsideOff + " " + RouteWords.askPerson)
        }
        #expect(RouteContext(now: R.now).outsideHelp == .off)
    }

    @Test func fallbackWritesEachDecisionToTheLedger() throws {
        var ledger = TaskLedger(key: .init(task: "task:one", startedAt: R.now))
        ledger.append(.queued, at: R.now, artifacts: NoArtifacts())
        var context = R.outside(grants: [try R.always(R.fetch)])
        context.frameworks = [.calendar: .denied]
        let decision = FallbackRouter.route(R.ask(), context: context)
        #expect(FallbackRouter.record(decision, in: &ledger, at: R.now + 1))
        #expect(ledger.entries.last == TaskLedgerEntry(.working(step: decision.ledgerLine), at: R.now + 1))
        #expect(decision.ledgerLine
            == "route hop=relay reason=granted skipped=context:noContext,framework:notAllowed")
        let asked = FallbackRouter.route(R.ask(), context: RouteContext(frameworks: [.calendar: .askable],
                                                                          canAskNow: true, now: R.now))
        #expect(FallbackRouter.record(asked, in: &ledger, at: R.now + 2))
        #expect(ledger.entries.last?.kind == .working(step: "route hop=framework reason=frameworkAsk capability=calendar skipped=context:noContext"))
        // An ended ledger takes nothing more, as always.
        ledger.append(.stopped(why: "Stopped."), at: R.now + 3, artifacts: NoArtifacts())
        #expect(!FallbackRouter.record(decision, in: &ledger, at: R.now + 4))
    }

    @Test func fallbackAskingThePersonIsAlwaysReachableAndNeverLoopsBack() {
        let nothing = RouteContext(now: R.now)
        #expect(FallbackRouter.route(RouteAsk(), context: nothing).hop == .askPerson)
        #expect(FallbackRouter.route(R.ask(), context: nothing).reason == "outsideOff")
        // Everything ready: each hop turned down moves on, never back.
        var everything = R.outside()
        everything.answersFromContext = true
        everything.frameworks = [.calendar: .granted]
        var hop = FallbackRouter.route(R.ask(), context: everything).hop
        var seen = [hop]
        while hop != .askPerson {
            let next = FallbackRouter.route(R.ask(), context: everything, after: hop)
            #expect(next.hop.rank > hop.rank)
            #expect(next.skipped.prefix(hop.rank + 1).allSatisfy { $0.why == .passed })
            hop = next.hop
            seen.append(hop)
        }
        #expect(seen == RouteHop.order)
        #expect(FallbackRouter.route(R.ask(), context: everything, after: .askPerson).hop == .askPerson)
    }

    @Test func fallbackWordsSayEachChoicePlainly() throws {
        var context = R.outside()
        #expect(FallbackRouter.route(R.ask(), context: context).words == RouteWords.needsTheWeb + " " + RouteWords.askFirst)
        context.grants = [try R.always(R.fetch)]
        #expect(FallbackRouter.route(R.ask(), context: context).words == RouteWords.needsTheWeb + " " + RouteWords.granted)
        context.relayConfigured = false
        #expect(FallbackRouter.route(R.ask(), context: context).words == RouteWords.biggerJob + " " + RouteWords.askFirst)
        context.frameworks = [.calendar: .askable]
        context.canAskNow = true
        #expect(FallbackRouter.route(R.ask(), context: context).words == RouteWords.frameworkAsk("your calendar"))
        context.answersFromContext = true
        #expect(FallbackRouter.route(R.ask(), context: context).words == RouteWords.fromContext)
    }
}

extension RouteWords {
    /// Every line a person can read about a route. Read by the copy guards.
    static var all: [String] {
        [fromContext, needsTheWeb, biggerJob, granted, askFirst, askPerson, outsideOff,
         frameworkAsk(somethingHere), frameworkReady(somethingHere)]
            + RouteCapability.allCases.flatMap { [frameworkReady($0.spoken), frameworkAsk($0.spoken)] }
    }
}
