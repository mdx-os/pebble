import Foundation
import PebbleCore

/// The one way to make the app's task engine. Its place is read from the
/// model that runs here, never written by hand, and a model that may send
/// words away gets no engine at all.
public enum OnDeviceTasks {
    /// The engine for the person's notes, its tasks kept in a file next to
    /// them. Nil unless `model` keeps every word on this device.
    public static func engine(model: any ModelClient, notes: MemoryStore, rule: AskFirst = .shared) -> DeviceTaskEngine? {
        engine(model: model, notes: notes, rule: rule, pace: .milliseconds(900))
    }

    /// The same, with the pace steps move at. Nil leaves them to
    /// `DeviceTaskEngine.runPending()`, for tests.
    package static func engine(model: any ModelClient, notes: MemoryStore, rule: AskFirst, pace: Duration?,
                               clock: @escaping @Sendable () -> Date = { Date() }) -> DeviceTaskEngine? {
        let place = model.privacyPlace
        guard place.staysOnDevice else { return nil }
        return DeviceTaskEngine(place: place, notes: notes, fileURL: DeviceTaskEngine.fileURL(besides: notes),
                                rule: rule, pace: pace, clock: clock)
    }
}
