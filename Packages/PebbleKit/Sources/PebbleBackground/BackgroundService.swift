import Foundation
import PebbleCore
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#elseif os(macOS)
import AppKit
#endif

/// Gives the runner time while the app is closed, the way each platform
/// allows, and tells it what the moment is like: Low Power Mode, whether
/// its file can be opened yet, and how long it has.
///
/// On iPhone and iPad this is `BGTaskScheduler`, with one app refresh task
/// for the morning. The summary is a two second count, so it needs nothing
/// longer. The system decides when it runs, and may not run it at all, so
/// the app also catches up whenever it comes to the front. On the Mac a
/// light `NSBackgroundActivityScheduler` looks every
/// `BackgroundPlan.macLookInterval` while the app is running, with or
/// without a window.
///
/// Nothing here decides what to run. `BackgroundPlan` does, from the
/// moment this reads, so every decision is a pure function the tests drive.
@MainActor
public final class BackgroundService {
    /// Nil when the runner's folder couldn't be made. The task is still
    /// registered then, since an ask from an earlier launch may still
    /// come, and the system ends an app that gets a task it never registered.
    public let runner: BackgroundRunner?
    private var scheduler: (any BackgroundScheduling)?
    private let clock: () -> Date
    private var planWatch: BackgroundRunner.Observation?

    /// `scheduler` is the system's unless a test passes its own.
    public init(runner: BackgroundRunner?, scheduler: (any BackgroundScheduling)? = nil,
                clock: @escaping () -> Date = { Date() }) {
        self.runner = runner
        self.clock = clock
        self.scheduler = scheduler
        if scheduler == nil { self.scheduler = SystemScheduler(service: self) }
    }

    /// Registers the task with the system. On iPhone and iPad this must
    /// run before the app finishes launching, so the app calls it from its
    /// `init`. Then it follows the runner: each change to its queue asks
    /// the system for time again, or cancels the ask once it is off.
    public func start() {
        scheduler?.register()
        guard let runner else { return }
        planWatch = runner.observe { [weak self] in
            Task { @MainActor in self?.plan() }
        }
        plan()
    }

    /// Asks the system for time at the runner's next wake, or stops asking.
    /// The runner gives no wake when it is off for certain, so a switch
    /// that can't be read yet never cancels an ask at once; one that still
    /// can't be read once a morning has passed stops asking.
    func plan() {
        guard let wake = runner?.nextWake(now: clock()) else {
            scheduler?.cancel()
            return
        }
        scheduler?.ask(at: wake)
    }

    /// A run the system gave time for. It asks for the next time first, so
    /// a run cut short still has one, runs what is due, and asks again now
    /// the run moved the job on, before the app can be suspended: the
    /// watch's own ask waits for a later turn of the main actor, which may
    /// not come until the next launch.
    ///
    /// True only if the run did its work. Off, or not known to be on, or
    /// with a file that couldn't be read, or held back, or out of time, it
    /// didn't, and the system hears so.
    @discardableResult
    func run(now: Date, conditions: BackgroundConditions, time: BackgroundTime) -> Bool {
        guard let runner else { return false }
        plan()
        runner.runDue(now: now, conditions: conditions, time: time)
        plan()
        return !time.isUp && runner.didItsWork(now: now)
    }

    /// The moment as the system reports it. `budget` is how long a
    /// background run may take, well inside what the system gives.
    func conditions(budget: TimeInterval?) -> BackgroundConditions {
        let deadline = budget.map { clock() + $0 }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if os(iOS)
        // Whether the file is shut comes from trying it, never from the
        // screen: locked after the first unlock, it still opens.
        guard let store = runner?.store else {
            return BackgroundConditions(moment: .background, lowPower: lowPower, deadline: deadline)
        }
        return .background(store: store, lowPower: lowPower, deadline: deadline)
        #else
        // The Mac has no file protection to wait for.
        return BackgroundConditions(moment: .background, lowPower: lowPower, deadline: deadline)
        #endif
    }
}

/// Where the service asks the system for time. The system's own, unless a
/// test passes one that only writes down what it was asked.
@MainActor
public protocol BackgroundScheduling: AnyObject {
    /// Called once, before the app finishes launching.
    func register()
    /// Asks for time at `wake` or later. Asking again replaces the ask.
    func ask(at wake: Date)
    /// Stops asking.
    func cancel()
}

#if canImport(BackgroundTasks) && os(iOS)
/// `BGTaskScheduler`, with one app refresh task.
@MainActor
final class SystemScheduler: BackgroundScheduling {
    private weak var service: BackgroundService?
    private let identifier = BackgroundIdentifiers.refresh()

    init(service: BackgroundService) {
        self.service = service
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            // Registered on the main queue, so this is the main actor.
            MainActor.assumeIsolated {
                guard let service = self?.service else { return task.setTaskCompleted(success: false) }
                // This run's time alone: a late call can't reach the next run.
                let time = BackgroundTime()
                task.expirationHandler = {
                    // Called on a queue of the system's; the token takes its own lock.
                    time.timeIsUp()
                }
                let success = service.run(now: Date(), conditions: service.conditions(budget: 20), time: time)
                task.setTaskCompleted(success: success)
            }
        }
    }

    func ask(at wake: Date) {
        let refresh = BGAppRefreshTaskRequest(identifier: identifier)
        refresh.earliestBeginDate = wake
        // Submitting again replaces the earlier ask. A refusal, as in the
        // Simulator or with Background App Refresh off, leaves the catch
        // up when the app opens, which always runs.
        try? BGTaskScheduler.shared.submit(refresh)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
#elseif os(macOS)
/// `NSBackgroundActivityScheduler`, looking every
/// `BackgroundPlan.macLookInterval` while the app runs.
@MainActor
final class SystemScheduler: BackgroundScheduling {
    private weak var service: BackgroundService?
    private var activity: NSBackgroundActivityScheduler?

    init(service: BackgroundService) {
        self.service = service
    }

    func register() {}

    func ask(at wake: Date) {
        guard activity == nil else { return }
        let next = NSBackgroundActivityScheduler(identifier: BackgroundIdentifiers.mac())
        next.repeats = true
        next.interval = BackgroundPlan.macLookInterval
        next.tolerance = 5 * 60
        next.qualityOfService = .utility
        next.schedule { [weak self] done in
            Task { @MainActor in
                guard let self, let service = self.service, let activity = self.activity else {
                    return done(.finished)
                }
                if activity.shouldDefer { return done(.deferred) }
                service.run(now: Date(), conditions: service.conditions(budget: nil), time: BackgroundTime())
                done(.finished)
            }
        }
        activity = next
    }

    func cancel() {
        activity?.invalidate()
        activity = nil
    }
}
#else
@MainActor
final class SystemScheduler: BackgroundScheduling {
    init(service: BackgroundService) {}
    func register() {}
    func ask(at wake: Date) {}
    func cancel() {}
}
#endif

/// The app's wiring for work while it's away, in one place, so the tests
/// read the same wiring the app runs: the task engine Today and the runner
/// share, and the service that gives the runner time.
@MainActor
public struct BackgroundWiring {
    /// The app's task engine. There is none yet, so the summary says
    /// nothing about tasks rather than count zero, and the switch promises
    /// nothing about them.
    public let tasks: (any TaskEngine)?
    public let service: BackgroundService

    /// The app's own, on the device's store and switch. Tests pass their own.
    public static func app(needsYou: NeedsYou,
                           store: () throws -> BackgroundStore = { try BackgroundStore.onDevice() },
                           toggle: () throws -> any BackgroundSwitch = { try FileBackgroundSwitch.onDevice() })
        -> BackgroundWiring {
        let tasks: (any TaskEngine)? = nil
        let runner = BackgroundRunner.onDevice(needsYou: needsYou, tasks: tasks, store: store, toggle: toggle)
        return BackgroundWiring(tasks: tasks, service: BackgroundService(runner: runner))
    }
}
