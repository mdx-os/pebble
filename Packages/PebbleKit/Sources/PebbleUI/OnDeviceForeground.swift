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

/// Ties on-device replies to the app being in front, on iPhone and iPad.
///
/// There the system refuses work on the graphics chip from the background,
/// and the model can end the app over it. So as soon as no window is active,
/// before the app reaches the background, the runner takes no new reply and
/// stops the one under way, and the app is kept open until its work on the
/// graphics chip has drained. A stopped reply's message stays in the chat,
/// ready to send again. On the Mac replies go on as before.
@MainActor
public final class OnDeviceForeground {
    private let runner: OnDeviceRunner
    private let stopsInBackground: Bool
    private let keepOpen: @MainActor (Task<Void, Never>) -> Void
    private var place = AppPlace.foreground
    /// The latest drain. Tests await it.
    private(set) var settling: Task<Void, Never>?

    /// - Parameters:
    ///   - stopsInBackground: True on iPhone and iPad, false on the Mac.
    ///   - keepOpen: Asks the system for time to finish `Task`, as the app
    ///     leaves the screen, and gives it back once `Task` has ended.
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

    /// The app moved. Leaving closes the runner's gate before this returns,
    /// so nothing starts on the model from here, and keeps the app open
    /// until the stopped reply has drained. Coming back opens the gate; a
    /// reply asked for then still waits for that drain.
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
        case .foreground:
            runner.returnToForeground()
        }
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

#if os(iOS)
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
