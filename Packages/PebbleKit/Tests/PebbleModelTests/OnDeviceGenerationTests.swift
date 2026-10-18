import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

struct OnDeviceGenerationTests {
    @Test func generationsDoNotOverlap() async {
        let gate = OnDeviceGeneration()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await gate.run { _ in
                        try await Task.sleep(for: .milliseconds(30))
                    }
                }
            }
        }
        #expect(await gate.overlapPeak() == 1)
    }

    /// Cancelling the generation lets it record cleanup before the next one starts.
    @Test func aCancelledGenerationCleansUpBeforeTheNextStarts() async throws {
        let gate = OnDeviceGeneration()
        let order = Order()
        let entered = Flag()
        let first = Task {
            try await gate.run { slot in
                let work = Task<Void, Never> {
                    let latch = Latch()
                    await withTaskCancellationHandler {
                        await latch.wait()
                    } onCancel: {
                        latch.release()
                    }
                }
                slot.track(work)
                await withTaskCancellationHandler {
                    entered.mark()
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                order.add("cleaned")
            }
        }
        for _ in 0..<500 where !entered.isSet {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(entered.isSet)
        let second = Task {
            try await gate.run { _ in
                order.add("next")
            }
        }
        first.cancel()
        _ = await first.result
        _ = await second.result
        #expect(order.all == ["cleaned", "next"])
    }

    /// Stopping closes admission, and does not return until the running generation has cleaned up.
    @Test func stopWaitsForCleanupAndRefusesUntilResume() async throws {
        let gate = OnDeviceGeneration()
        let order = Order()
        let entered = Flag()
        let running = Task {
            try await gate.run { slot in
                let work = Task<Void, Never> {
                    let latch = Latch()
                    await withTaskCancellationHandler {
                        await latch.wait()
                    } onCancel: {
                        latch.release()
                    }
                }
                slot.track(work)
                entered.mark()
                await work.value
                order.add("cleaned")
            }
        }
        for _ in 0..<500 where !entered.isSet {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(entered.isSet)
        await gate.stop()
        #expect(order.all == ["cleaned"])
        _ = await running.result
        await #expect(throws: MLXChatModelError.stopped) {
            try await gate.run { _ in }
        }
        await gate.resume()
        try await gate.run { _ in }
    }
}

struct OnDeviceAdmissionTests {
    private func emptyFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two models, as two windows, share a gate so their replies cannot both be inside it.
    @Test func twoModelsShareOneGeneration() async throws {
        let folder = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OnDeviceGeneration()
        let first = MLXChatModel(directory: folder, generation: gate)
        let second = MLXChatModel(directory: folder, generation: gate)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi.")]
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await first.reply(to: turns) }
            group.addTask { _ = try? await second.reply(to: turns) }
        }
        #expect(await gate.overlapPeak() == 1)
    }

    /// Background stops admission. The model stays the model: this is not a failed load.
    /// Coming back, a reply is attempted again.
    @Test func backgroundRefusesAReplyUntilTheAppIsBack() async throws {
        let folder = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OnDeviceGeneration()
        let model = MLXChatModel(directory: folder, generation: gate)
        let chat = OnDeviceChat(model)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi.")]
        await chat.stopForBackground()
        await #expect(throws: MLXChatModelError.stopped) {
            try await chat.reply(to: turns)
        }
        #expect(!MLXChatModelError.stopped.isLoadFailure)
        #expect(chat.active as? MLXChatModel === model)
        await chat.resumeAfterBackground()
        await #expect(throws: MLXChatModelError.unavailable) {
            try await chat.reply(to: turns)
        }
    }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Waits until `release`, including when release wins the race.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func mark() {
        lock.lock()
        set = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return set
    }
}
