import Foundation
import PebbleCore

/// The one way to make the app's task engine. Its place is read from the
/// model that runs here, never written by hand. With a model that may send
/// words away the engine starts no task, but still follows the notes, so a
/// forgotten note's line leaves a kept digest whatever model is chosen.
public enum OnDeviceTasks {
    /// What `DeviceTaskEngine` is made from: the place, read from the
    /// model. Only this file can make one, so nothing else can make an
    /// engine, and the compiler says so.
    struct Key: Sendable {
        let place: PrivacyPlace

        fileprivate init(model: any ModelClient) {
            place = model.privacyPlace
        }
    }

    /// The engine for the person's notes, its tasks kept in `store`, the
    /// app's one task store. It starts tasks only while `model` keeps every
    /// word on this device.
    public static func engine(model: any ModelClient, notes: MemoryStore, store: TaskStore,
                              rule: AskFirst = .shared) -> DeviceTaskEngine {
        engine(model: model, notes: notes, store: store, rule: rule, pace: .milliseconds(900))
    }

    /// The same, with the pace steps move at. Nil leaves them to
    /// `DeviceTaskEngine.runPending()`, for tests.
    package static func engine(model: any ModelClient, notes: MemoryStore, store: TaskStore, rule: AskFirst,
                               pace: Duration?, clock: @escaping @Sendable () -> Date = { Date() }) -> DeviceTaskEngine {
        DeviceTaskEngine(key: Key(model: model), notes: notes, store: store, rule: rule, pace: pace, clock: clock)
    }
}
