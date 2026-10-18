import Foundation
import PebbleCore

/// The one way to make the app's task engine. Its place is read from the
/// model that runs here, never written by hand, and a model that may send
/// words away gets no engine at all.
public enum OnDeviceTasks {
    /// What `DeviceTaskEngine` is made from: the place, read from a model
    /// that keeps every word on this device. Only this file can make one,
    /// so nothing else can make an engine, and the compiler says so.
    struct Key: Sendable {
        let place: PrivacyPlace

        fileprivate init?(model: any ModelClient) {
            let place = model.privacyPlace
            guard place.staysOnDevice else { return nil }
            self.place = place
        }
    }

    /// The engine for the person's notes, its tasks kept in a file next to
    /// them. Nil unless `model` keeps every word on this device.
    public static func engine(model: any ModelClient, notes: MemoryStore, rule: AskFirst = .shared) -> DeviceTaskEngine? {
        engine(model: model, notes: notes, rule: rule, pace: .milliseconds(900))
    }

    /// The same, with the pace steps move at. Nil leaves them to
    /// `DeviceTaskEngine.runPending()`, for tests.
    package static func engine(model: any ModelClient, notes: MemoryStore, rule: AskFirst, pace: Duration?,
                               clock: @escaping @Sendable () -> Date = { Date() }) -> DeviceTaskEngine? {
        guard let key = Key(model: model) else { return nil }
        return DeviceTaskEngine(key: key, notes: notes, fileURL: DeviceTaskEngine.fileURL(besides: notes),
                                rule: rule, pace: pace, clock: clock)
    }
}
