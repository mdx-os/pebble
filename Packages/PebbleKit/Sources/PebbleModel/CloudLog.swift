import Foundation
#if canImport(os)
import os
#endif

/// The one way the cloud code writes to the log. It takes only fixed words
/// (`StaticString`), written into the source, so no sign-in token, nonce,
/// key, session or anything from a chat can ever reach the log through it:
/// a value made at run time doesn't compile here. Nothing in the cloud code
/// prints or logs any other way (`nothingInTheCloudCodeLogsAValue`).
public enum CloudLog {
    #if canImport(os)
    private static let logger = Logger(subsystem: "pebble", category: "cloud")
    #endif

    private static let lock = NSLock()
    nonisolated(unsafe) private static var watchers: [UUID: @Sendable (String) -> Void] = [:]

    /// Writes `event` to the system log, and hands it to anyone watching.
    public static func note(_ event: StaticString) {
        let line = event.description
        #if canImport(os)
        logger.info("\(line)")
        #endif
        for watcher in lock.withLock({ Array(watchers.values) }) { watcher(line) }
    }

    /// Hands every line written from now on to `watcher`, until the
    /// returned value is passed to `stopWatching`. For tests, which read
    /// every line the cloud code writes.
    package static func watch(_ watcher: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { watchers[id] = watcher }
        return id
    }

    package static func stopWatching(_ id: UUID) {
        _ = lock.withLock { watchers.removeValue(forKey: id) }
    }
}
