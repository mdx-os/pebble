import Foundation

/// Where the person's words go, and so whether the copy may promise they
/// stay on this device.
///
/// There is one source for this: the active model. The app reads it from
/// `ModelClient.privacyPlace` and passes it down, so no screen keeps a flag
/// of its own that could drift. Copy that mentions the device takes this
/// value and only makes the promise when it is `.onDevice`.
///
/// The cloud setting can change where words go while the app runs. A chat
/// keeps the model it started with, so its opening line stays true. Today
/// and the memory follow `HomeView.place`, which is the model's place unless
/// the cloud is on, and `HomeView` sets `FeedModel.place` and
/// `MemoryModel.place` again whenever it changes.
public enum PrivacyPlace: Sendable, Equatable {
    /// The model runs here and nothing the person says leaves the device.
    case onDevice
    /// Some words may leave the device, as with a cloud model. Copy makes
    /// no promise about the device either way.
    case mayLeaveDevice

    public init(staysOnDevice: Bool) {
        self = staysOnDevice ? .onDevice : .mayLeaveDevice
    }

    /// True only when every word stays on this device.
    public var staysOnDevice: Bool { self == .onDevice }
}
