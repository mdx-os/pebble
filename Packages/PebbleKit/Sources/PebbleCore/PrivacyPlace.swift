import Foundation

/// Where the person's words go, and so whether the copy may promise they
/// stay on this device.
///
/// There is one source for this: the active model. The app reads it from
/// `ModelClient.privacyPlace` and passes it down, so no screen keeps a flag
/// of its own that could drift. Copy that mentions the device takes this
/// value and only makes the promise when it is `.onDevice`.
///
/// Some models take a copy once, when they are made: `FeedModel.place`,
/// `MemoryModel.place` and the chat's opening line. `HomeView` keys its
/// screen on the model, so another model builds them all again and no copy
/// goes stale. Anything new that keeps the place must be rebuilt the same way.
///
/// Switching models clears the chat. The new screen starts with only its own
/// opening line, nothing said to the old model, and no Forget everything left
/// waiting for an answer. That is the privacy-safe default: words told to a
/// model on this device are never carried to one whose words may leave, and
/// a question asked under one promise is never answered under another. Mandeep
/// decides whether a switch may keep the chat before any model picker ships.
/// `aNewModelStartsAFreshChat` fails if a change keeps either one.
public enum PrivacyPlace: Sendable, Hashable {
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
