import Foundation
import PebbleCore
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Gives the runner time while the app is closed, the way each platform
/// allows, and tells it what the moment is like: Low Power Mode, a locked
/// device, and how long it has.
///
/// On iPhone and iPad this is `BGTaskScheduler`, with an app refresh task
/// for the morning and a processing task the system may run overnight
/// while charging. The system decides when either runs, and may not run
/// them at all, so the app also catches up whenever it comes to the front.
/// On the Mac a light `NSBackgroundActivityScheduler` looks every quarter
/// hour while the app is running, with or without a window.
///
/// Nothing here decides what to run. `BackgroundPlan` does, from the
/// moment this reads, so every decision is a pure function the tests drive.
@MainActor
public final class BackgroundService {
    public let runner: BackgroundRunner
    private var planWatch: BackgroundRunner.Observation?
    #if os(macOS)
    private var activity: NSBackgroundActivityScheduler?
    #endif

    public init(runner: BackgroundRunner) {
        self.runner = runner
    }

    /// Registers the tasks with the system. On iPhone and iPad this must
    /// run before the app finishes launching, so the app calls it from its
    /// `init`. Then it follows the runner: each change to its queue asks
    /// the system for time again, or cancels the ask once the queue is empty.
    public func start() {
        #if canImport(BackgroundTasks) && os(iOS)
        for kind in [BackgroundIdentifiers.refresh, BackgroundIdentifiers.processing] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: kind, using: .main) { [weak self] task in
                // Registered on the main queue, so this is the main actor.
                MainActor.assumeIsolated { self?.handle(task) }
            }
        }
        #endif
        planWatch = runner.observe { [weak self] in
            Task { @MainActor in self?.plan() }
        }
        plan()
    }

    /// Asks the system for time at the runner's next wake, or stops asking.
    func plan() {
        let wake = runner.nextWake(now: Date())
        #if canImport(BackgroundTasks) && os(iOS)
        let scheduler = BGTaskScheduler.shared
        guard let wake else {
            scheduler.cancel(taskRequestWithIdentifier: BackgroundIdentifiers.refresh)
            scheduler.cancel(taskRequestWithIdentifier: BackgroundIdentifiers.processing)
            return
        }
        let refresh = BGAppRefreshTaskRequest(identifier: BackgroundIdentifiers.refresh)
        refresh.earliestBeginDate = wake
        let processing = BGProcessingTaskRequest(identifier: BackgroundIdentifiers.processing)
        processing.earliestBeginDate = wake
        processing.requiresNetworkConnectivity = false
        processing.requiresExternalPower = false
        // Submitting again replaces the earlier ask. A refusal, as in the
        // Simulator or with Background App Refresh off, leaves the catch
        // up when the app opens, which always runs.
        try? scheduler.submit(refresh)
        try? scheduler.submit(processing)
        #elseif os(macOS)
        if wake == nil {
            activity?.invalidate()
            activity = nil
        } else if activity == nil {
            let next = NSBackgroundActivityScheduler(identifier: BackgroundIdentifiers.mac)
            next.repeats = true
            next.interval = BackgroundPlan.retryAfterHold
            next.tolerance = 5 * 60
            next.qualityOfService = .utility
            next.schedule { [weak self] done in
                Task { @MainActor in
                    guard let self, let activity = self.activity else { return done(.finished) }
                    if activity.shouldDefer { return done(.deferred) }
                    self.runner.runDue(now: Date(), conditions: Self.conditions(budget: nil))
                    done(.finished)
                }
            }
            activity = next
        }
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func handle(_ task: BGTask) {
        // Ask for the next time first, so a run cut short still has one.
        plan()
        let runner = runner
        task.expirationHandler = {
            // Called on a queue of the system's; the runner takes its own lock.
            runner.timeIsUp()
        }
        let budget: TimeInterval = task is BGProcessingTask ? 60 : 20
        runner.runDue(now: Date(), conditions: Self.conditions(budget: budget))
        task.setTaskCompleted(success: true)
    }
    #endif

    /// The moment as the system reports it. `budget` is how long a
    /// background run may take, well inside what the system gives.
    static func conditions(budget: TimeInterval?) -> BackgroundConditions {
        let now = Date()
        #if os(iOS)
        let locked = !UIApplication.shared.isProtectedDataAvailable
        #else
        // The Mac has no file protection to wait for while locked.
        let locked = false
        #endif
        return BackgroundConditions(moment: .background,
                                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                    locked: locked,
                                    deadline: budget.map { now + $0 })
    }
}
