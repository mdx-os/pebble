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
    case foreground
    case background
}

/// Which scenes are active. One window leaving does not count while another
/// is still active. The gate closes when the last one deactivates.
struct OnDeviceActiveScenes: Equatable {
    private var active: Set<ObjectIdentifier> = []

    var isInFront: Bool { !active.isEmpty }

    /// True when this scene is the one that made the app active.
    mutating func activate(_ id: ObjectIdentifier) -> Bool {
        let wasEmpty = active.isEmpty
        active.insert(id)
        return wasEmpty
    }

    /// True when no scene is active after this one deactivates.
    mutating func deactivate(_ id: ObjectIdentifier) -> Bool {
        active.remove(id)
        return active.isEmpty
    }
}

/// Ties on-device replies to the app being active, on iPhone and iPad.
///
/// There the system refuses new work on the graphics chip once the app is
/// no longer active, and the model can end the app over it. The gate closes
/// when the last scene deactivates, the reply under way is cancelled, and
/// loading, prompt reading, and generation synchronize the chip before the
/// background callback returns. A stopped reply's message stays in the chat,
/// ready to send again. On the Mac replies go on as before.
@MainActor
public final class OnDeviceForeground {
    private let runner: OnDeviceRunner
    private let stopsInBackground: Bool
    private var place = AppPlace.foreground
    private var scenes = OnDeviceActiveScenes()
    private let sceneWatch = SceneWatch()

    /// - Parameter stopsInBackground: True on iPhone and iPad, false on the Mac.
    public init(runner: OnDeviceRunner = .shared,
                stopsInBackground: Bool = OnDeviceForeground.platformStopsInBackground) {
        self.runner = runner
        self.stopsInBackground = stopsInBackground
    }

    public nonisolated static var platformStopsInBackground: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The app moved. Leaving blocks until the reply under way has
    /// synchronized the graphics chip, so a background callback that calls
    /// this does not return while that work is still submitted.
    public func moved(to next: AppPlace) {
        guard stopsInBackground, next != place else { return }
        place = next
        switch next {
        case .background: runner.leaveForegroundAndWait()
        case .foreground: runner.returnToForegroundNow()
        }
    }

    /// A scene became active. The app is in front again when the first one does.
    func sceneActivated(_ id: ObjectIdentifier) {
        guard scenes.activate(id) else { return }
        moved(to: .foreground)
    }

    /// A scene will deactivate. When it is the last active scene, close the
    /// gate now, before the background callback.
    func sceneDeactivated(_ id: ObjectIdentifier) {
        guard scenes.deactivate(id) else { return }
        moved(to: .background)
    }

    /// A scene entered the background. If nothing is still active, do not
    /// return until the graphics chip is idle. Deactivation usually did this
    /// already; this is the callback that has to have it done.
    func sceneEnteredBackground(_ id: ObjectIdentifier) {
        _ = scenes.deactivate(id)
        guard !scenes.isInFront else { return }
        moved(to: .background)
    }

    #if os(iOS)
    /// Scene notifications, delivered on the thread that posts them so the
    /// background callback is still on the stack while the chip drains.
    public func watchSystemScenes() {
        guard stopsInBackground, sceneWatch.isEmpty else { return }
        let center = NotificationCenter.default
        sceneWatch.add(center.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            let id = ObjectIdentifier(scene)
            self?.performOnMain { $0.sceneActivated(id) }
        })
        sceneWatch.add(center.addObserver(
            forName: UIScene.willDeactivateNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            let id = ObjectIdentifier(scene)
            self?.performOnMain { $0.sceneDeactivated(id) }
        })
        sceneWatch.add(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            let id = ObjectIdentifier(scene)
            self?.performOnMain { $0.sceneEnteredBackground(id) }
        })
    }
    #else
    public func watchSystemScenes() {}
    #endif

    #if canImport(SwiftUI)
    /// The app's scene phase as a place. Inactive is the last scene leaving
    /// the active state, which is when submissions have to stop.
    public nonisolated static func place(for phase: ScenePhase) -> AppPlace {
        switch phase {
        case .active: .foreground
        case .inactive, .background: .background
        @unknown default: .background
        }
    }

    public func follow(_ phase: ScenePhase) {
        moved(to: Self.place(for: phase))
    }
    #endif

    private nonisolated func performOnMain(_ body: @MainActor (OnDeviceForeground) -> Void) {
        let run = {
            MainActor.assumeIsolated {
                body(self)
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.sync(execute: run)
        }
    }
}

/// Notification tokens for the scene watch. Removed when the watcher goes.
private final class SceneWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty
    }

    func add(_ token: any NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
