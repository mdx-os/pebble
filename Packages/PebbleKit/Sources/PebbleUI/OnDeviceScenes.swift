import PebbleModel
import SwiftUI

/// How many scenes are in front, and what that means for on-device work.
///
/// Metal rejects GPU work once an iPhone or iPad app is in the background,
/// and that rejection ends the process. The last scene to leave stops
/// loading and generation and waits until the GPU is idle. The first scene
/// back lets replies run again. A glance that only goes inactive, such as
/// Control Center, does not.
enum OnDeviceScenes {
    private static let lock = NSLock()
    private static var inFront = 0

    enum Action: Equatable {
        case stop
        case resume
        case none
    }

    struct Outcome: Equatable {
        var inFront: Int
        var counted: Bool
        var action: Action
    }

    /// `counted` is true while this scene has been in front since it last
    /// went to the background. Inactive keeps it counted.
    static func account(inFront: Int, counted: Bool, phase: ScenePhase) -> Outcome {
        switch phase {
        case .active:
            if counted {
                return Outcome(inFront: inFront, counted: true, action: .none)
            }
            let leading = inFront == 0
            return Outcome(inFront: inFront + 1, counted: true, action: leading ? .resume : .none)
        case .background:
            if counted {
                let next = max(0, inFront - 1)
                return Outcome(inFront: next, counted: false, action: next == 0 ? .stop : .none)
            }
            // Never came to the front. Stop only when nothing else is in front,
            // so a scene created in the background does not stop one that is showing.
            return Outcome(inFront: inFront, counted: false, action: inFront == 0 ? .stop : .none)
        default:
            return Outcome(inFront: inFront, counted: counted, action: .none)
        }
    }

    /// Records `phase` for one scene and, on iPhone and iPad, stops or
    /// resumes on-device work. Returns whether this scene is now counted.
    /// Stopping waits until GPU work has drained, so it has finished before
    /// the app is running in the background.
    static func note(counted: Bool, phase: ScenePhase, model: any ModelClient) -> Bool {
        #if os(iOS)
        lock.lock()
        let outcome = account(inFront: inFront, counted: counted, phase: phase)
        inFront = outcome.inFront
        lock.unlock()
        switch outcome.action {
        case .stop:
            wait { await model.stopForBackground() }
        case .resume:
            wait { await model.resumeAfterBackground() }
        case .none:
            break
        }
        return outcome.counted
        #else
        _ = (phase, model)
        return counted
        #endif
    }

    private static func wait(_ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await work()
            done.signal()
        }
        done.wait()
    }
}
