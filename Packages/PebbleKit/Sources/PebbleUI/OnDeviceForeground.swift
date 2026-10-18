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

/// Ties on-device replies to the app being in front, on iPhone and iPad.
///
/// There the system refuses work on the graphics chip from the background,
/// and the model can end the app over it. So when the app leaves the
/// foreground, the runner takes no new reply and stops the one under way,
/// and the app is kept open until it has ended. A stopped reply's message
/// stays in the chat, ready to send again. On the Mac replies go on as before.
@MainActor
public final class OnDeviceForeground {
    private let runner: OnDeviceRunner
    private let stopsInBackground: Bool
    private let keepOpen: @MainActor (Task<Void, Never>) -> Void
    private var place = AppPlace.foreground
    /// The latest move, run after the one before it. Tests await it.
    private(set) var settling: Task<Void, Never>?

    /// - Parameters:
    ///   - stopsInBackground: True on iPhone and iPad, false on the Mac.
    ///   - keepOpen: Asks the system for time to finish `Task` once the app
    ///     has gone to the background.
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

    /// The app moved. Each move runs after the one before, in order.
    public func moved(to next: AppPlace) {
        guard stopsInBackground, next != place else { return }
        place = next
        let runner = runner
        let before = settling
        let move = Task {
            await before?.value
            switch next {
            case .background: await runner.leaveForeground()
            case .foreground: await runner.returnToForeground()
            }
        }
        settling = move
        if next == .background { keepOpen(move) }
    }

    #if canImport(SwiftUI)
    /// The app's scene phase as a place. Inactive, as with Control Center
    /// pulled down, is still in front and changes nothing.
    public nonisolated static func place(for phase: ScenePhase) -> AppPlace? {
        switch phase {
        case .active: .foreground
        case .background: .background
        default: nil
        }
    }

    public func follow(_ phase: ScenePhase) {
        if let place = Self.place(for: phase) { moved(to: place) }
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
