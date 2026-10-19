import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

/// Answers the fetcher's session in place of the network, with a body
/// planned for each address. It sends the body a piece at a time and
/// notes how much went before the session stopped it.
final class PlannedServer: URLProtocol, @unchecked Sendable {
    struct Plan {
        /// The Content-Length header, or nil to send none.
        var stated: Int?
        var body: Data
        var piece = 16 * 1024
    }

    final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var sentBytes = 0
        private var wasStopped = false

        var sent: Int {
            lock.lock()
            defer { lock.unlock() }
            return sentBytes
        }

        var stopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return wasStopped
        }

        func add(_ count: Int) {
            lock.lock()
            sentBytes += count
            lock.unlock()
        }

        func stop() {
            lock.lock()
            wasStopped = true
            lock.unlock()
        }

        /// The session may stop the server just after the fetch has thrown,
        /// so this waits for it, up to a few seconds.
        func stoppedSoon() async -> Bool {
            for _ in 0..<300 where !stopped {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return stopped
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var plans: [URL: (Plan, Record)] = [:]

    /// Serves `plan` at `url` and returns what happened there.
    static func serve(_ plan: Plan, at url: URL) -> Record {
        let record = Record()
        lock.lock()
        plans[url] = (plan, record)
        lock.unlock()
        return record
    }

    private static func plan(for url: URL?) -> (Plan, Record)? {
        lock.lock()
        defer { lock.unlock() }
        return url.flatMap { plans[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (plan, record) = Self.plan(for: request.url), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let headers = plan.stated.map { ["Content-Length": "\($0)"] } ?? [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let client = client
        DispatchQueue.global().async { [self] in
            var offset = 0
            while offset < plan.body.count {
                if record.stopped { return }
                let end = min(offset + plan.piece, plan.body.count)
                client?.urlProtocol(self, didLoad: plan.body.subdata(in: offset..<end))
                record.add(end - offset)
                offset = end
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !record.stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        Self.plan(for: request.url)?.1.stop()
    }
}

/// Every byte count the fetcher reports.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int64] = []

    func add(_ count: Int64) {
        lock.lock()
        counts.append(count)
        lock.unlock()
    }

    var all: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

/// What a task ended with, once it has.
private final class Ended<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    var result: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The real fetcher, through its own session and delegate, answered by
/// `PlannedServer` so nothing reaches the network.
struct ModelFetchTests {
    private let fetcher = URLSessionModelFetcher(handlers: [PlannedServer.self])

    private func address() -> URL {
        URL(string: "https://huggingface.co/example/fetch-\(UUID().uuidString)/resolve/main/model.safetensors")!
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aBodyOfThePinnedSizeIsWritten() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = Data((0..<40_000).map { UInt8($0 % 251) })
        let url = address()
        _ = PlannedServer.serve(.init(stated: body.count, body: body), at: url)
        let destination = folder.appendingPathComponent("model.safetensors.download")
        try await fetcher.fetch(ModelDownloadRequest.make(url), to: destination, bytes: Int64(body.count)) { _ in }
        #expect(try Data(contentsOf: destination) == body)
    }

    /// A body with no length said, and far more than the pin, is stopped
    /// soon after it passes the pin, and leaves no file.
    @Test func aStreamLargerThanThePinIsStoppedAndKeepsNoFile() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let limit = 20 * 1024
        let body = Data(repeating: 1, count: 4 * 1024 * 1024)
        let url = address()
        let record = PlannedServer.serve(.init(stated: nil, body: body), at: url)
        let destination = folder.appendingPathComponent("model.safetensors.download")
        let heard = Heard()
        await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try await fetcher.fetch(ModelDownloadRequest.make(url), to: destination, bytes: Int64(limit),
                                    progress: heard.add)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(heard.all.allSatisfy { $0 <= limit })
        // Stopped long before the whole body went.
        #expect(await record.stoppedSoon())
        #expect(record.sent < body.count / 4, "sent \(record.sent)")
    }

    /// A Content-Length over the pin is refused before any of the body is written.
    @Test func aStatedLengthOverThePinIsRefusedBeforeTheBody() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let limit = 20 * 1024
        let body = Data(repeating: 2, count: 4 * 1024 * 1024)
        let url = address()
        let record = PlannedServer.serve(.init(stated: body.count, body: body), at: url)
        let destination = folder.appendingPathComponent("model.safetensors.download")
        let heard = Heard()
        await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try await fetcher.fetch(ModelDownloadRequest.make(url), to: destination, bytes: Int64(limit),
                                    progress: heard.add)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(heard.all.isEmpty)
        #expect(await record.stoppedSoon())
    }

    /// A fetch cancelled before it starts ends cancelled, never waits for
    /// ever, and keeps no file. The session can report the cancel before
    /// the fetch is listening for it, so this runs many times to meet that.
    @Test func aFetchCancelledBeforeItStartsEndsCancelled() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = Data(repeating: 3, count: 1024)
        for round in 0..<200 {
            // Every other round waits before listening, so the cancel is
            // surely reported first; the rest leave it to timing.
            let waits = round.isMultiple(of: 2)
            let fetcher = URLSessionModelFetcher(handlers: [PlannedServer.self]) {
                if waits { Thread.sleep(forTimeInterval: 0.02) }
            }
            let url = address()
            _ = PlannedServer.serve(.init(stated: body.count, body: body), at: url)
            let destination = folder.appendingPathComponent("model-\(round).safetensors.download")
            let fetch = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await fetcher.fetch(ModelDownloadRequest.make(url), to: destination,
                                        bytes: Int64(body.count)) { _ in }
            }
            guard let ended = await Self.within(.seconds(20), fetch) else {
                Issue.record("round \(round): the cancelled fetch never ended")
                return
            }
            if case .success = ended { Issue.record("round \(round): a cancelled fetch succeeded") }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// Through the installer: a download stopped before its first file
    /// starts ends not downloaded, and leaves nothing in the folder.
    @Test func anInstallCancelledBeforeItsFirstFetchKeepsNothing() async throws {
        let fetcher = URLSessionModelFetcher(handlers: [PlannedServer.self]) { Thread.sleep(forTimeInterval: 0.02) }
        for round in 0..<20 {
            // Nothing is served: the pin's addresses are shared with other
            // tests, and a stopped fetch never reaches the server anyway.
            let place = try TestPin.place()
            defer { place.remove() }
            let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: fetcher,
                                           freeSpace: { _ in nil })
            let install = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await installer.install(report: { _ in })
            }
            guard let ended = await Self.within(.seconds(20), install) else {
                Issue.record("round \(round): the stopped install never ended")
                return
            }
            #expect(try ended.get() == .notDownloaded)
            #expect(installer.readyFolder() == nil)
            #expect(place.names().isEmpty, "round \(round): \(place.names())")
        }
    }

    /// The task's result, or nil when it hasn't ended within `limit`.
    private static func within<T: Sendable, E: Error>(_ limit: Duration,
                                                      _ task: Task<T, E>) async -> Result<T, Error>? {
        let deadline = ContinuousClock.now + limit
        let ended = Ended<T>()
        let waiter = Task {
            let result: Result<T, Error>
            do { result = .success(try await task.value) } catch { result = .failure(error) }
            ended.set(result)
        }
        while ContinuousClock.now < deadline {
            if let result = ended.result { return result }
            try? await Task.sleep(for: .milliseconds(2))
        }
        waiter.cancel()
        return ended.result
    }

    /// Through the installer: an oversized file ends failed with Try again,
    /// and nothing of the download is kept.
    @Test func anOversizedFileFailsTheInstallAndKeepsNothing() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        for file in place.pin.files {
            var body = TestPin.contents[file.name]!
            if file.name == "weights.safetensors" { body.append(Data(repeating: 0, count: 2 * 1024 * 1024)) }
            _ = PlannedServer.serve(.init(stated: nil, body: body), at: place.pin.url(for: file))
        }
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: fetcher,
                                       freeSpace: { _ in nil })
        let end = await installer.install(report: { _ in })
        #expect(end == .failed(.couldNotFetch))
        #expect(ModelDownloadProblem.couldNotFetch.canTryAgain)
        #expect(installer.readyFolder() == nil)
        #expect(place.names().isEmpty)
    }
}
