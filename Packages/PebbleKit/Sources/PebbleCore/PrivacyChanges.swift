import Foundation

/// One lock for the notes and the private words, the inputs `Redactor` is
/// built from, held while either is changed and while a cloud request is
/// checked against them and handed to its transport.
///
/// A request is redacted, shown and only then sent. Just before it goes,
/// `CloudModel` reads the notes and private words again and sends nothing
/// if they changed. Without this lock a word saved in another window
/// between that read and the hand over would miss the check, and bytes
/// redacted without it would leave. With it, a change made then waits
/// until the request is handed over, so every request that goes was
/// checked against every word saved before it went.
///
/// `MemoryStore` owns one and takes it for every write. The cloud setting
/// takes the same one, through its notes store, to save private words,
/// and gives it to each cloud chat's `CloudModel`. Recursive, so a change
/// that makes another change on the same thread never waits on itself.
public final class PrivacyChanges: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let waiting: @Sendable () -> Void

    /// `waiting` is told when a caller finds the lock held and is about to
    /// wait for it, so a test can see a change held back without a clock.
    public init(waiting: @escaping @Sendable () -> Void = {}) {
        self.waiting = waiting
    }

    /// Runs `change`, a write to the notes or private words, while no
    /// request is being checked and handed over.
    public func change<T>(_ change: () throws -> T) rethrows -> T {
        try holding(change)
    }

    /// Runs `handOver`, the last check of a request against the notes and
    /// private words and its hand over to the transport, or a reply's
    /// first read of them and what its chat keeps of it, while nothing
    /// changes them.
    public func handOver<T>(_ handOver: () throws -> T) rethrows -> T {
        try holding(handOver)
    }

    private func holding<T>(_ body: () throws -> T) rethrows -> T {
        if !lock.try() {
            waiting()
            lock.lock()
        }
        defer { lock.unlock() }
        return try body()
    }
}
