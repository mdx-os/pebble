import Foundation
import PebbleModel
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Where the app is, as on-device replies need to know it.
public enum AppPlace: Sendable, Equatable {
    /// Active: a window is in front and taking touches.
    case foreground
    /// Inactive or in the background: on its way off the screen, or gone.
    case background
}

/// Which scenes are in front. The last one to leave is when replies stop.
struct OnDeviceScenes: Equatable {
    private var active: Set<ObjectIdentifier> = []

    /// True when this scene is the first one in front.
    mutating func activate(_ id: ObjectIdentifier) -> Bool {
        let wasEmpty = active.isEmpty
        active.insert(id)
        return wasEmpty
    }

    /// True when this scene was active and no scene is left in front.
    /// A scene already counted out does not ask again.
    mutating func deactivate(_ id: ObjectIdentifier) -> Bool {
        guard active.remove(id) != nil else { return false }
        return active.isEmpty
    }
}

/// Ties on-device replies to the app being in front, on iPhone and iPad.
///
/// There the system refuses work on the graphics chip from the background,
/// and the model can end the app over it. The weight load ignores a stop
/// and can still evaluate after it was cancelled, so leaving does not
/// return until that work has finished and the chip is synchronized.
/// A stopped reply's message stays in the chat, ready to send again. On
/// the Mac replies go on as before.
@MainActor
public final class OnDeviceForeground {
    private let runner: OnDeviceRunner
    private let stopsInBackground: Bool
    private let keepOpen: @MainActor (Task<Void, Never>) -> Void
    private var place = AppPlace.foreground
    private var scenes = OnDeviceScenes()
    /// The latest drain. Tests await it.
    private(set) var settling: Task<Void, Never>?
    #if os(iOS)
    private var sceneWatch: SceneWatch?
    #endif

    /// - Parameters:
    ///   - stopsInBackground: True on iPhone and iPad, false on the Mac.
    ///   - keepOpen: Asks the system for time while the app leaves the
    ///     screen. That time does not allow more work on the graphics chip.
    ///     The drain itself finishes before `moved(to:)` returns.
    public init(runner: OnDeviceRunner = .shared,
                stopsInBackground: Bool = OnDeviceForeground.platformStopsInBackground,
                keepOpen: @escaping @MainActor (Task<Void, Never>) -> Void = OnDeviceForeground.keepOpen) {
        self.runner = runner
        self.stopsInBackground = stopsInBackground
        self.keepOpen = keepOpen
    }

    public nonisolated static var platformStopsInBackground: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The app moved. Leaving closes the runner's gate and does not return
    /// until the reply under way, including a load that ignores the stop,
    /// has finished and its work on the graphics chip has drained. Coming
    /// back opens the gate.
    public func moved(to next: AppPlace) {
        guard stopsInBackground, next != place else { return }
        place = next
        switch next {
        case .background:
            runner.closeGate()
            let runner = runner
            let drain = Task.detached { await runner.drained() }
            settling = drain
            keepOpen(drain)
            DrainWait.wait(drain)
        case .foreground:
            runner.returnToForeground()
        }
    }

    /// A scene came to the front. The first one opens the gate.
    func sceneActivated(_ id: ObjectIdentifier) {
        guard stopsInBackground, scenes.activate(id) else { return }
        moved(to: .foreground)
    }

    /// A scene left the front. The last one drains before this returns.
    func sceneDeactivated(_ id: ObjectIdentifier) {
        guard stopsInBackground, scenes.deactivate(id) else { return }
        moved(to: .background)
    }

    /// Listens to scene activation on iPhone and iPad. The handler runs on
    /// the thread that posts the notification, which is the main thread,
    /// inside UIKit's callback, and `sceneDeactivated` does not return
    /// until the chip is synchronized.
    public func watchSystemScenes() {
        #if os(iOS)
        guard sceneWatch == nil else { return }
        sceneWatch = SceneWatch { [weak self] note, activate in
            guard let scene = note.object as? UIScene else { return }
            let id = ObjectIdentifier(scene)
            let run = {
                guard let self else { return }
                if activate {
                    self.sceneActivated(id)
                } else {
                    self.sceneDeactivated(id)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(run)
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated(run) }
            }
        }
        #endif
    }

    #if canImport(SwiftUI)
    /// The app's scene phase as a place. The app's phase is active while
    /// any window is, so it turns inactive when the last active one does.
    /// Inactive, as with the app switcher or Control Center, already counts
    /// as away, so nothing new reaches the graphics chip on the way out.
    public nonisolated static func place(for phase: ScenePhase) -> AppPlace {
        switch phase {
        case .active: .foreground
        default: .background
        }
    }

    public func follow(_ phase: ScenePhase) {
        moved(to: Self.place(for: phase))
    }
    #endif

    /// Asks for background time on iPhone and iPad until `work` ends.
    /// The time is not permission to keep using the graphics chip.
    public static func keepOpen(_ work: Task<Void, Never>) {
        #if os(iOS)
        let application = UIApplication.shared
        let ticket = BackgroundTicket()
        ticket.id = application.beginBackgroundTask(withName: "OnDeviceModelStop") {
            ticket.end(application)
        }
        Task { @MainActor in
            await work.value
            ticket.end(application)
        }
        #endif
    }
}

/// Blocks the caller until `drain` has finished.
private enum DrainWait {
    static func wait(_ drain: Task<Void, Never>) {
        let box = Box()
        Task.detached {
            await drain.value
            box.finish()
        }
        box.block()
    }

    private final class Box: @unchecked Sendable {
        private let condition = NSCondition()
        private var done = false

        func finish() {
            condition.lock()
            done = true
            condition.broadcast()
            condition.unlock()
        }

        func block() {
            condition.lock()
            while !done { condition.wait() }
            condition.unlock()
        }
    }
}

#if os(iOS)
/// Scene notifications, removed with the watcher.
private final class SceneWatch: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    init(_ handle: @escaping @Sendable (Notification, Bool) -> Void) {
        let center = NotificationCenter.default
        let names: [(Notification.Name, Bool)] = [
            (UIScene.didActivateNotification, true),
            (UIScene.willDeactivateNotification, false),
            (UIScene.didEnterBackgroundNotification, false),
        ]
        for (name, activate) in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                handle(note, activate)
            })
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

/// One background task's id, ended once.
@MainActor
private final class BackgroundTicket {
    var id = UIBackgroundTaskIdentifier.invalid

    func end(_ application: UIApplication) {
        guard id != .invalid else { return }
        application.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
