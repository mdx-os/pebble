#if canImport(SwiftUI)
import SwiftUI
import Testing
@testable import PebbleUI

@Suite
struct OnDeviceSceneTests {
    @Test func theLastSceneToLeaveStopsAndTheFirstBackResumes() {
        var inFront = 0
        var first = false
        var second = false

        var outcome = OnDeviceScenes.account(inFront: inFront, counted: first, phase: .active)
        inFront = outcome.inFront
        first = outcome.counted
        #expect(outcome.action == .resume)
        #expect(inFront == 1 && first)

        outcome = OnDeviceScenes.account(inFront: inFront, counted: second, phase: .active)
        inFront = outcome.inFront
        second = outcome.counted
        #expect(outcome.action == .none)
        #expect(inFront == 2 && second)

        // Control Center and the like are inactive, and the scene stays counted.
        outcome = OnDeviceScenes.account(inFront: inFront, counted: first, phase: .inactive)
        inFront = outcome.inFront
        first = outcome.counted
        #expect(outcome.action == .none)
        #expect(inFront == 2 && first)

        outcome = OnDeviceScenes.account(inFront: inFront, counted: first, phase: .background)
        inFront = outcome.inFront
        first = outcome.counted
        #expect(outcome.action == .none)
        #expect(inFront == 1 && !first)

        outcome = OnDeviceScenes.account(inFront: inFront, counted: second, phase: .background)
        inFront = outcome.inFront
        second = outcome.counted
        #expect(outcome.action == .stop)
        #expect(inFront == 0 && !second)

        outcome = OnDeviceScenes.account(inFront: inFront, counted: first, phase: .active)
        inFront = outcome.inFront
        first = outcome.counted
        #expect(outcome.action == .resume)
        #expect(inFront == 1 && first)
    }

    /// A scene that launches in the background stops work only when no scene is in front.
    @Test func aSceneCreatedInTheBackgroundDoesNotStopOneThatIsShowing() {
        let idle = OnDeviceScenes.account(inFront: 0, counted: false, phase: .background)
        #expect(idle.action == .stop)
        #expect(idle.inFront == 0)

        let showing = OnDeviceScenes.account(inFront: 1, counted: false, phase: .background)
        #expect(showing.action == .none)
        #expect(showing.inFront == 1)
    }
}
#endif
