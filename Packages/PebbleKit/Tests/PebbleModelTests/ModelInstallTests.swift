import CryptoKit
import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

/// A small pinned model with real hashes, and a scratch models folder.
struct TestPin {
    static let contents: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
        "tokenizer.json": Data(#"{"model":{}}"#.utf8),
        "weights.safetensors": Data((0..<4096).map { UInt8($0 % 251) }),
    ]

    static let pin = PinnedModel(
        repository: "example/tiny-model",
        revision: "0123456789abcdef0123456789abcdef01234567",
        files: ["config.json", "tokenizer.json", "weights.safetensors"].map { name in
            let data = contents[name]!
            return PinnedModelFile(name: name, bytes: Int64(data.count), sha256: sha256(data))
        }
    )

    let folders: ModelFolders
    var pin: PinnedModel { Self.pin }
    var ready: URL { folders.ready(for: pin) }

    static func place() throws -> TestPin {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TestPin(folders: ModelFolders(root: root))
    }

    func writeReady() throws {
        try writeFiles(in: ready)
    }

    func writeFiles(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in Self.contents {
            try data.write(to: folder.appendingPathComponent(name))
        }
    }

    /// Everything under the models folder, by name.
    func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folders.root.path))?.sorted() ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(at: folders.root)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Writes each pinned file's bytes, with a way to break one, and records
/// every request. Never touches the network.
final class FakeFetcher: ModelFetching, @unchecked Sendable {
    enum Way {
        case serve
        /// Serves this file with its last byte changed: same size, wrong hash.
        case corrupt(String)
        /// Serves this file with a byte too many.
        case tooLong(String)
        /// Throws on this file, as a dropped connection would.
        case drop(String)
        /// Waits on this file until the task is cancelled.
        case hang(String)
    }

    private let lock = NSLock()
    private var made: [URLRequest] = []
    let way: Way
    let started = AsyncStream<String>.makeStream()

    init(_ way: Way = .serve) {
        self.way = way
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        made.append(request)
        lock.unlock()
    }

    func fetch(_ request: URLRequest, to destination: URL, bytes: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        record(request)
        let name = request.url!.lastPathComponent
        started.continuation.yield(name)
        var data = TestPin.contents[name]!
        switch way {
        case .serve: break
        case .corrupt(let file) where file == name: data[data.count - 1] ^= 0xFF
        case .tooLong(let file) where file == name: data.append(0)
        case .drop(let file) where file == name: throw URLError(.networkConnectionLost)
        case .hang(let file) where file == name:
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.prefix(10).write(to: destination)
            progress(10)
            try await Task.sleep(for: .seconds(600))
        default: break
        }
        progress(Int64(data.count) / 2)
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

/// Collects every step an install reports.
final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ModelDownloadState] = []

    func add(_ step: ModelDownloadState) {
        lock.lock()
        seen.append(step)
        lock.unlock()
    }

    var all: [ModelDownloadState] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

struct ModelInstallTests {
    @Test func everyFileMatchingEndsReadyAndLeavesNothingHalfDone() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let steps = Steps()
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: FakeFetcher(),
                                       freeSpace: { _ in nil })
        let end = await installer.install(report: steps.add)
        #expect(end == .installed(place.ready))
        #expect(installer.readyFolder() == place.ready)
        for (name, data) in TestPin.contents {
            #expect(try Data(contentsOf: place.ready.appendingPathComponent(name)) == data)
        }
        #expect(place.names() == [place.pin.folderName])
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.ready.path).sorted()
            == place.pin.files.map(\.name).sorted())
        #expect(steps.all.first == .downloading(received: 0, total: place.pin.totalBytes))
        #expect(steps.all.last == .verifying)
        #expect(steps.all.contains(.downloading(received: place.pin.totalBytes, total: place.pin.totalBytes)))
        // Left out of backups: it can always be fetched again.
        let values = try place.folders.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func aHashMismatchFailsAndKeepsNoReadyFolder() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let installer = ModelInstaller(pin: place.pin, folders: place.folders,
                                       fetcher: FakeFetcher(.corrupt("weights.safetensors")), freeSpace: { _ in nil })
        #expect(await installer.install(report: { _ in }) == .failed(.didNotMatch))
        #expect(installer.readyFolder() == nil)
        #expect(place.names().isEmpty)
        #expect(OnDeviceModel.kind(environment: [:], defaults: .standard, folders: place.folders, pin: place.pin,
                                   availableMemory: plentyOfMemory) == .stub(.notDownloaded))
    }

    @Test func aWrongSizeFailsAndKeepsNoReadyFolder() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let installer = ModelInstaller(pin: place.pin, folders: place.folders,
                                       fetcher: FakeFetcher(.tooLong("config.json")), freeSpace: { _ in nil })
        #expect(await installer.install(report: { _ in }) == .failed(.didNotMatch))
        #expect(installer.readyFolder() == nil)
        #expect(place.names().isEmpty)
    }

    @Test func aDroppedConnectionFailsAndKeepsNothing() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let installer = ModelInstaller(pin: place.pin, folders: place.folders,
                                       fetcher: FakeFetcher(.drop("tokenizer.json")), freeSpace: { _ in nil })
        #expect(await installer.install(report: { _ in }) == .failed(.couldNotFetch))
        #expect(installer.readyFolder() == nil)
        #expect(place.names().isEmpty)
    }

    @Test func stoppingPartWayIsNotReadyAndKeepsNothing() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let fetcher = FakeFetcher(.hang("weights.safetensors"))
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: fetcher,
                                       freeSpace: { _ in nil })
        let install = Task { await installer.install(report: { _ in }) }
        for await name in fetcher.started.stream where name == "weights.safetensors" { break }
        // The first files are in by now, under their temporary names.
        #expect(place.names().count == 1)
        #expect(place.names().first?.hasPrefix(".partial-") == true)
        install.cancel()
        #expect(await install.value == .notDownloaded)
        #expect(installer.readyFolder() == nil)
        #expect(place.names().isEmpty)
    }

    @Test func tooLittleSpaceFailsBeforeFetchingAnything() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let fetcher = FakeFetcher()
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: fetcher,
                                       freeSpace: { _ in 10 })
        #expect(await installer.install(report: { _ in }) == .failed(.noRoom))
        #expect(fetcher.requests.isEmpty)
        #expect(place.names().isEmpty)
    }

    @Test func whatAnInterruptedDownloadLeftIsRemoved() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let partial = place.folders.root.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try place.writeFiles(in: partial)
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: FakeFetcher(),
                                       freeSpace: { _ in nil })
        await installer.removeLeftovers()
        #expect(place.names().isEmpty)
    }

    @Test func anIncompleteFolderIsReplacedWhole() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        try place.writeReady()
        try FileManager.default.removeItem(at: place.ready.appendingPathComponent("weights.safetensors"))
        try Data("stray".utf8).write(to: place.ready.appendingPathComponent("stray.txt"))
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: FakeFetcher(),
                                       freeSpace: { _ in nil })
        #expect(installer.hasIncompleteFolder())
        #expect(await installer.install(report: { _ in }) == .installed(place.ready))
        #expect(!FileManager.default.fileExists(atPath: place.ready.appendingPathComponent("stray.txt").path))
        #expect(installer.readyFolder() == place.ready)
    }

    // MARK: What is sent

    /// Only the pinned addresses, in order, each a plain GET with the same
    /// two fixed headers: no cookie, no credentials, nothing of the person's.
    @Test func onlyThePinnedAddressesAreFetchedWithNothingAdded() async throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let fetcher = FakeFetcher()
        let installer = ModelInstaller(pin: place.pin, folders: place.folders, fetcher: fetcher,
                                       freeSpace: { _ in nil })
        _ = await installer.install(report: { _ in })
        #expect(fetcher.requests.map(\.url) == place.pin.urls)
        for request in fetcher.requests {
            #expect(request.httpMethod == "GET")
            #expect(request.allHTTPHeaderFields == ModelDownloadRequest.headers)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody == nil)
            #expect(!request.httpShouldHandleCookies)
            #expect(request.url?.query == nil)
        }
    }

    @Test func thePinnedAddressesAreTheHubAtTheRevision() {
        let pin = PinnedModel.default
        #expect(pin.urls.map(\.absoluteString) == pin.files.map {
            "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/"
                + "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/\($0.name)"
        })
        #expect(ModelDownloadRequest.headers == ["User-Agent": "model-download", "Accept-Language": "en"])
    }

    @Test func redirectsGoOnlyToTheHubsOwnFileHosts() throws {
        for allowed in ["https://huggingface.co/x", "https://cdn-lfs-us-1.hf.co/repos/a/b?X-Amz-Signature=1",
                        "https://cas-bridge.xethub.hf.co/xet/a", "https://cdn-lfs.huggingface.co/a"] {
            #expect(ModelDownloadRequest.allowsRedirect(to: try #require(URL(string: allowed))), "\(allowed)")
        }
        for refused in ["http://huggingface.co/x", "https://huggingface.co.example.com/x", "https://example.com/x",
                        "https://hf.co.example.com/x", "https://user:pass@cdn-lfs.hf.co/x", "ftp://cdn-lfs.hf.co/x",
                        "https://nothf.co/x"] {
            #expect(!ModelDownloadRequest.allowsRedirect(to: try #require(URL(string: refused))), "\(refused)")
        }
    }

    @Test func theSessionKeepsAndAddsNothing() {
        let configuration = URLSessionModelFetcher.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpAdditionalHeaders == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    // MARK: The pin

    @Test func thePinIsWholeAndItsButtonSaysItsSize() {
        let pin = PinnedModel.default
        #expect(pin.repository == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(pin.revision.count == 40 && pin.revision.allSatisfy(\.isHexDigit))
        #expect(pin.files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) && $0.bytes > 0 })
        #expect(Set(pin.files.map(\.name)).count == pin.files.count)
        for needed in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            #expect(pin.files.contains { $0.name == needed }, "\(needed)")
        }
        #expect(pin.totalBytes == 2_274_455_727)
        #expect(OnDeviceModelWords.downloadTitle(bytes: pin.totalBytes) == "Download on-device model, about 2.3 GB")
        #expect(OnDeviceModelWords.downloading(received: 1_234_000_000, total: pin.totalBytes)
            == "Downloading. 1.2 of 2.3 GB.")
    }

    @Test func theModelsFolderIsTheAppsOwn() throws {
        let folders = try ModelFolders.onDevice(appFolder: "Example")
        #expect(folders.root.lastPathComponent == "Models")
        #expect(folders.root.deletingLastPathComponent().lastPathComponent == "Example")
        #expect(folders.ready(for: .default).lastPathComponent
            == "mlx-community--Qwen3-4B-Instruct-2507-4bit--50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
    }
}
