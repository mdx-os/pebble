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
/// On iPhone and iPad this is `BGTaskScheduler`, with one app refresh task
/// for the morning. The summary is a two second count, so it needs nothing
/// longer. The system decides when it runs, and may not run it at all, so
/// the app also catches up whenever it comes to the front. On the Mac a
/// light `NSBackgroundActivityScheduler` looks every quarter hour while
/// the app is running, with or without a window.
///
/// Nothing here decides what to run. `BackgroundPlan` does, from the
/// moment this reads, so every decision is a pure function the tests drive.
@MainActor
public final class BackgroundService {
    /// Nil when the runner's folder couldn't be made. The task is still
    /// registered then, since an ask from an earlier launch may still
    /// come, and the system ends an app that gets a task it never registered.
    public let runner: BackgroundRunner?
    private var planWatch: BackgroundRunner.Observation?
    #if os(macOS)
    private var activity: NSBackgroundActivityScheduler?
    #endif

    public init(runner: BackgroundRunner?) {
        self.runner = runner
    }

    /// Registers the task with the system. On iPhone and iPad this must
    /// run before the app finishes launching, so the app calls it from its
    /// `init`. Then it follows the runner: each change to its queue asks
    /// the system for time again, or cancels the ask once the queue is empty.
    public func start() {
        #if canImport(BackgroundTasks) && os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundIdentifiers.refresh(), using: .main) {
            [weak self] task in
            // Registered on the main queue, so this is the main actor.
            MainActor.assumeIsolated {
                guard let self else { return task.setTaskCompleted(success: false) }
                self.handle(task)
            }
        }
        #endif
        guard let runner else { return }
        planWatch = runner.observe { [weak self] in
            Task { @MainActor in self?.plan() }
        }
        plan()
    }

    /// Asks the system for time at the runner's next wake, or stops asking.
    func plan() {
        let wake = runner?.nextWake(now: Date())
        #if canImport(BackgroundTasks) && os(iOS)
        let scheduler = BGTaskScheduler.shared
        let identifier = BackgroundIdentifiers.refresh()
        guard let wake else {
            scheduler.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let refresh = BGAppRefreshTaskRequest(identifier: identifier)
        refresh.earliestBeginDate = wake
        // Submitting again replaces the earlier ask. A refusal, as in the
        // Simulator or with Background App Refresh off, leaves the catch
        // up when the app opens, which always runs.
        try? scheduler.submit(refresh)
        #elseif os(macOS)
        if wake == nil {
            activity?.invalidate()
            activity = nil
        } else if activity == nil {
            let next = NSBackgroundActivityScheduler(identifier: BackgroundIdentifiers.mac())
            next.repeats = true
            next.interval = BackgroundPlan.retryAfterHold
            next.tolerance = 5 * 60
            next.qualityOfService = .utility
            next.schedule { [weak self] done in
                Task { @MainActor in
                    guard let self, let runner = self.runner, let activity = self.activity else {
                        return done(.finished)
                    }
                    if activity.shouldDefer { return done(.deferred) }
                    runner.runDue(now: Date(), conditions: Self.conditions(budget: nil))
                    done(.finished)
                }
            }
            activity = next
        }
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func handle(_ task: BGTask) {
        guard let runner else { return task.setTaskCompleted(success: false) }
        // Ask for the next time first, so a run cut short still has one.
        plan()
        // This run's time alone: a late call can't reach the next run.
        let time = BackgroundTime()
        task.expirationHandler = {
            // Called on a queue of the system's; the token takes its own lock.
            time.timeIsUp()
        }
        runner.runDue(now: Date(), conditions: Self.conditions(budget: 20), time: time)
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
