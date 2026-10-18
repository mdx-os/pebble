#if DEBUG
import Foundation
import PebbleCore

/// For the UI tests only. A launch with `-backgroundSeed on` runs the
/// app's own runner and service, started the way the app starts them, over
/// a scratch folder set up as an earlier version left it: the switch on in
/// `UserDefaults`, which the test's launch arguments give, and the morning
/// summary queued in the runner's file. Nothing of the person's is touched.
/// `-backgroundSeed again` opens the same folder as the launch before
/// left it, seeding nothing, so a test can see what that launch kept.
/// Any launch without either removes that folder, so the test leaves
/// nothing behind once the app opens again.
public enum BackgroundSeed {
    public static let launchKey = "backgroundSeed"

    /// Where the seeded runner keeps its files.
    public static var scratchFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ui-background-seed")
    }

    public static func launched(defaults: UserDefaults = .standard, folder: URL = scratchFolder)
        -> (store: BackgroundStore, toggle: any BackgroundSwitch)? {
        let mode = defaults.string(forKey: launchKey)
        if mode != "again" { try? FileManager.default.removeItem(at: folder) }
        guard mode == "on" || mode == "again" else { return nil }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let store = BackgroundStore(fileURL: folder.appendingPathComponent("background.json"))
        if mode == "on" {
            let due = BackgroundPlan.nextMorning(after: Date(), calendar: .current)
            try? store.save(BackgroundState(queue: [BackgroundJob(kind: .morningSummary, due: due)]))
        }
        // With no file yet, the switch is read from `UserDefaults` and moved.
        let toggle = FileBackgroundSwitch(fileURL: folder.appendingPathComponent("background-switch.json"),
                                          defaults: defaults)
        return (store, toggle)
    }
}
#endif
