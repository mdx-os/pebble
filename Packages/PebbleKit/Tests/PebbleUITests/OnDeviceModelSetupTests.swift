import CryptoKit
import Foundation
import PebbleCore
import PebbleModel
@testable import PebbleUI
import SourceScan
import Testing

/// A tiny pinned model, and a fetcher that serves it or breaks it, so no
/// test reaches the network.
private enum Tiny {
    static let contents: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
        "tokenizer.json": Data(#"{"model":{}}"#.utf8),
        "weights.safetensors": Data(repeating: 7, count: 2048),
    ]

    static let pin = PinnedModel(
        repository: "example/tiny-model",
        revision: "89abcdef0123456789abcdef0123456789abcdef",
        files: contents.keys.sorted().map { name in
            let data = contents[name]!
            return PinnedModelFile(name: name, bytes: Int64(data.count),
                                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    )

    static func folders() throws -> ModelFolders {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ModelFolders(root: root)
    }
}

private final class TinyFetcher: ModelFetching, @unchecked Sendable {
    let corrupt: Bool
    private let lock = NSLock()
    private var count = 0

    init(corrupt: Bool = false) {
        self.corrupt = corrupt
    }

    var fetched: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func counted() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func fetch(_ request: URLRequest, to destination: URL, bytes: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws {
        counted()
        var data = Tiny.contents[request.url!.lastPathComponent]!
        if corrupt { data[0] ^= 0xFF }
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

@MainActor
struct OnDeviceModelSetupTests {
    @Test func nothingIsFetchedUntilThePersonAsks() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let fetcher = TinyFetcher()
        let chat = OnDeviceModel.client(environment: [:], folders: folders, pin: Tiny.pin)
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders, fetcher: fetcher),
                                       chat: chat)
        for _ in 0..<5 { await Task.yield() }
        #expect(setup.state == .notDownloaded)
        #expect(fetcher.fetched == 0)
        #expect((chat.active as? LocalStubModel)?.notReady == .notDownloaded)
    }

    @Test func aFinishedDownloadMovesEveryChatToTheModel() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let chat = OnDeviceModel.client(environment: [:], folders: folders, pin: Tiny.pin)
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders,
                                                                 fetcher: TinyFetcher(), freeSpace: { _ in nil }),
                                       chat: chat, availableMemory: { 64 << 30 })
        setup.download()
        #expect(setup.state.isUnderWay)
        await setup.underway?.value
        #expect(setup.state == .ready(folders.ready(for: Tiny.pin)))
        #expect(chat.active is MLXChatModel)
    }

    @Test func aMismatchedDownloadFailsAndTheChatStaysHonest() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let chat = OnDeviceModel.client(environment: [:], folders: folders, pin: Tiny.pin)
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders,
                                                                 fetcher: TinyFetcher(corrupt: true),
                                                                 freeSpace: { _ in nil }),
                                       chat: chat, availableMemory: { 64 << 30 })
        setup.download()
        await setup.underway?.value
        #expect(setup.state == .failed(.didNotMatch))
        #expect((chat.active as? LocalStubModel)?.notReady == .notDownloaded)
        #expect(OnDeviceModelRow.detail(for: setup.state, pin: Tiny.pin) == OnDeviceModelWords.didNotMatch)
    }

    @Test func aModelTooBigForThisDeviceIsNotUsedAndOffersNoTryAgain() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let chat = OnDeviceModel.client(environment: [:], folders: folders, pin: Tiny.pin)
        let fetcher = TinyFetcher()
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders, fetcher: fetcher,
                                                                 freeSpace: { _ in nil }),
                                       chat: chat, availableMemory: { 1024 })
        setup.download()
        await setup.underway?.value
        #expect(setup.state == .failed(.needsMoreMemory))
        #expect((chat.active as? LocalStubModel)?.notReady == .needsMoreMemory)
        let before = fetcher.fetched
        setup.download()
        #expect(setup.underway == nil)
        #expect(fetcher.fetched == before)
    }

    /// A downloaded folder whose files are all there at their sizes but
    /// won't load (here, config.json isn't JSON) first reads as ready. The
    /// first reply finds it out: the chat says the model isn't ready, the
    /// row shows it failed with Download again, and that removes the bad
    /// folder, fetches it again, and moves the chat to the new model.
    @Test func aModelThatWontLoadShowsFailedAndDownloadAgainRepairsIt() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let ready = folders.ready(for: Tiny.pin)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        for (name, data) in Tiny.contents {
            let written = name == "config.json" ? Data(repeating: UInt8(ascii: "x"), count: data.count) : data
            try written.write(to: ready.appendingPathComponent(name))
        }
        let fetcher = TinyFetcher()
        let chat = OnDeviceModel.client(environment: [:], folders: folders, pin: Tiny.pin,
                                        availableMemory: 64 << 30)
        let failing = try #require(chat.active as? MLXChatModel)
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders, fetcher: fetcher,
                                                                 freeSpace: { _ in nil }),
                                       chat: chat, availableMemory: { 64 << 30 })
        #expect(setup.state == .ready(ready))

        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "What should I cook tonight?")]
        #expect(try await chat.reply(to: turns) == OnDeviceModelWords.notReadyReply(.couldNotLoad))
        #expect((chat.active as? LocalStubModel)?.notReady == .couldNotLoad)
        for _ in 0..<20 where setup.state != .failed(.couldNotLoad) { await Task.yield() }
        #expect(setup.state == .failed(.couldNotLoad))
        #expect(OnDeviceModelRow.detail(for: setup.state, pin: Tiny.pin) == OnDeviceModelWords.couldNotLoad)
        #expect(ModelDownloadProblem.couldNotLoad.canTryAgain)

        setup.repair()
        #expect(setup.state.isUnderWay)
        await setup.underway?.value
        #expect(fetcher.fetched == Tiny.contents.count)
        #expect(setup.state == .ready(ready))
        #expect(try Data(contentsOf: ready.appendingPathComponent("config.json")) == Tiny.contents["config.json"])
        let repaired = try #require(chat.active as? MLXChatModel)
        #expect(repaired !== failing)
    }

    /// A developer's own folder that won't load is never removed by Download again.
    @Test func downloadAgainLeavesADevelopersFolder() async throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let own = folders.root.appendingPathComponent("own-model", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        for (name, data) in Tiny.contents {
            try (name == "config.json" ? Data("not json".utf8) : data).write(to: own.appendingPathComponent(name))
        }
        let chat = OnDeviceModel.client(environment: [OnDeviceModel.environmentKey: own.path], folders: folders,
                                        pin: Tiny.pin, availableMemory: 64 << 30)
        #expect(chat.active is MLXChatModel)
        let setup = OnDeviceModelSetup(installer: ModelInstaller(pin: Tiny.pin, folders: folders,
                                                                 fetcher: TinyFetcher(), freeSpace: { _ in nil }),
                                       chat: chat, availableMemory: { 64 << 30 })
        _ = try await chat.reply(to: [ChatTurn(id: UUID(), speaker: .person, text: "Hello there.")])
        for _ in 0..<20 where setup.state != .failed(.couldNotLoad) { await Task.yield() }
        #expect(setup.state == .failed(.couldNotLoad))
        setup.repair()
        await setup.underway?.value
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("config.json").path))
        #expect(setup.state == .ready(folders.ready(for: Tiny.pin)))
    }

    /// The app finds the model the download put in its own folder, with no
    /// environment variable or defaults key, and starts the setup from it.
    @Test func theAppUsesTheDownloadedModelWithNothingElseSet() throws {
        let folders = try Tiny.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let ready = folders.ready(for: .default)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
        // Files of the pinned sizes, holes and all, so nothing large is written.
        for file in PinnedModel.default.files {
            let url = ready.appendingPathComponent(file.name)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes))
            try handle.close()
        }
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = OnDeviceModelSetup.forApp(brand: Brand(name: "Example"), environment: [:], defaults: defaults,
                                            folders: folders, availableMemory: { 64 << 30 })
        #expect(app.model.active is MLXChatModel)
        #expect(app.setup?.state == .ready(ready))
    }

    /// The app hands its one on-device client to the home screen and the
    /// setup to the memory screen, and never stands the placeholder in by
    /// hand, which is how a merged home screen once lost the model.
    @Test func theAppPassesItsOneModelAndItsSetup() throws {
        let app = try String(contentsOf: SwiftSource.repositoryRoot(from: #filePath)
            .appendingPathComponent("App/Sources/PebbleApp.swift"), encoding: .utf8)
        let code = String(SwiftSource(app).code)
        #expect(!code.contains("LocalStubModel("))
        #expect(code.contains("OnDeviceModelSetup.forApp(brand: brand)"))
        #expect(code.contains("model: model,"))
        #expect(code.contains(".environment(\\.onDeviceModelSetup, modelSetup)"))
    }

    @Test func eachStepHasItsOwnWords() {
        let pin = PinnedModel.default
        let states: [ModelDownloadState] = [
            .notDownloaded, .downloading(received: 0, total: pin.totalBytes), .verifying,
            .ready(URL(fileURLWithPath: "/tmp")), .failed(.couldNotFetch), .failed(.didNotMatch), .failed(.noRoom),
            .failed(.couldNotSave), .failed(.incomplete), .failed(.needsMoreMemory), .failed(.couldNotLoad),
        ]
        let words = states.map { OnDeviceModelRow.detail(for: $0, pin: pin) }
        #expect(Set(words).count == states.count)
        #expect(Set(states.map(OnDeviceModelRow.phase)).count == states.count)
        #expect(!ModelDownloadProblem.needsMoreMemory.canTryAgain)
        #expect(ModelDownloadProblem.didNotMatch.canTryAgain)
    }
}
