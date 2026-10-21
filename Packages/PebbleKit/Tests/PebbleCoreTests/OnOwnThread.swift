import Foundation

/// Runs `body` on a thread of its own and awaits its answer, so a blocking
/// wait never holds a thread of a pool other tests share.
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { done in
        Thread.detachNewThread { done.resume(returning: body()) }
    }
}
