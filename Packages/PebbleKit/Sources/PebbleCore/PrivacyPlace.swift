import Foundation

/// Where the person's words go, and so whether the copy may promise they
/// stay on this device.
///
/// There is one source for this: the active model. The app reads it from
/// `ModelClient.privacyPlace` and passes it down, so no screen keeps a flag
/// of its own that could drift. Copy that mentions the device takes this
/// value and only makes the promise when it is `.onDevice`.
///
/// The active model can change while the app runs: with help from the
/// cloud on, each new chat gets the cloud model. So there are two readings,
/// both from models and nothing else:
/// - A chat reads its own model (`ChatController.privacyPlace`). Its opening
///   and header are fixed with that chat, which keeps its model for life,
///   so an on-device chat started before the cloud was turned on keeps its
///   promise, and is never sent.
/// - Every line outside a chat (memory, Today's sample note, the hello and
///   the cloud setting) reads `all(_:)` of the open chat's place and the
///   place of the model a new chat would get. With the cloud on, that is
///   never `.onDevice`. `HomeView` works it out and pushes every change into
///   `FeedModel.place` and `MemoryModel.place`, so no copy goes stale.
///
/// The model that runs here can change too. `HomeView` keys its screen on
/// it, so another one builds the chat, `FeedModel` and `MemoryModel` again.
/// Anything new that keeps the place must either follow the pushes above
/// or be rebuilt the same way.
///
/// Switching the model that runs here clears the chat. The new screen starts
/// with only its own opening line, nothing said to the old model, and no
/// Forget everything left waiting for an answer. That is the privacy-safe
/// default: words told to a model on this device are never carried to one
/// whose words may leave, and a question asked under one promise is never
/// answered under another. Whether a switch may keep the chat is decided
/// before any model picker ships. `aNewModelStartsAFreshChat` fails if a
/// change keeps either one.
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

    /// `.onDevice` only when every place given is. A line read by more than
    /// one chat, or by a chat and the next one, promises only what all of
    /// them keep. It takes at least one place, since an empty list would
    /// promise the device with no model behind it.
    public static func all(_ first: PrivacyPlace, _ rest: PrivacyPlace...) -> PrivacyPlace {
        ([first] + rest).allSatisfy(\.staysOnDevice) ? .onDevice : .mayLeaveDevice
    }
}
