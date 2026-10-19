import Foundation
import PebbleCore
@testable import PebbleModel
import Testing

/// Plenty of memory, so only the rule under test decides.
let plentyOfMemory: UInt64 = 64 << 30

struct OnDeviceModelTests {
    @Test func missingConfigurationUsesTheStubAndSaysItIsNotDownloaded() throws {
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let kind = OnDeviceModel.kind(environment: [:], defaults: defaults)
        let client = OnDeviceModel.client(environment: [:], defaults: defaults)
        #expect(kind == .stub(.notDownloaded))
        #expect((client.active as? LocalStubModel)?.notReady == .notDownloaded)
        #expect(client.runsOnDevice)
    }

    @Test func blankConfigurationUsesTheStub() throws {
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("   ", forKey: OnDeviceModel.defaultsKey)
        #expect(OnDeviceModel.kind(environment: [OnDeviceModel.environmentKey: "  "], defaults: defaults).isStub)
        #expect(OnDeviceModel.kind(configuredPath: nil).isStub)
    }

    @Test func relativePathUsesTheStub() {
        #expect(OnDeviceModel.kind(configuredPath: "models/local").isStub)
        #expect(OnDeviceModel.kind(configuredPath: "https://example.com/weights").isStub)
    }

    @Test func nonexistentFolderUsesTheStub() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-model-\(UUID().uuidString)", isDirectory: true)
        #expect(OnDeviceModel.kind(configuredPath: missing.path) == .stub(.notDownloaded))
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let client = OnDeviceModel.client(environment: [OnDeviceModel.environmentKey: missing.path], defaults: defaults)
        #expect(client.active is LocalStubModel)
    }

    @Test func absolutePathSelectsMLX() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let environment = [OnDeviceModel.environmentKey: folder.path]
        let kind = OnDeviceModel.kind(environment: environment, defaults: defaults, availableMemory: plentyOfMemory)
        let client = OnDeviceModel.client(environment: environment, defaults: defaults, availableMemory: plentyOfMemory)
        expectMLX(kind, directory: folder)
        #expect(client.active is MLXChatModel)
    }

    @Test func fileURLSelectsTheSameDirectory() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        expectMLX(OnDeviceModel.kind(configuredPath: folder.absoluteString, availableMemory: plentyOfMemory),
                  directory: folder)
    }

    @Test func fileURLWithAHostUsesTheStub() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        #expect(OnDeviceModel.kind(configuredPath: "file://localhost\(folder.path)").isStub)
    }

    @Test func tildePathSelectsTheExpandedFolder() throws {
        let name = "model-\(UUID().uuidString)"
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath()
        try writeModelFiles(in: folder, weightBytes: 16)
        defer { remove(folder) }
        let resolved = folder.resolvingSymlinksInPath()
        expectMLX(OnDeviceModel.kind(configuredPath: "~/\(name)", availableMemory: plentyOfMemory), directory: resolved)
    }

    @Test func unknownHomeShortcutUsesTheStub() {
        let path = "~nosuchuser\(UUID().uuidString)/model"
        #expect(OnDeviceModel.kind(configuredPath: path).isStub)
    }

    @Test func symlinkSelectsTheResolvedFolder() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { remove(link) }
        expectMLX(OnDeviceModel.kind(configuredPath: link.path, availableMemory: plentyOfMemory), directory: folder)
    }

    @Test func weightsThatLeaveTooLittleHeadroomUseTheStub() throws {
        let folder = try modelFolder(weightBytes: 100)
        defer { remove(folder) }
        let tight = 100 + OnDeviceModel.headroomBytes - 1
        #expect(OnDeviceModel.kind(configuredPath: folder.path, availableMemory: tight) == .stub(.needsMoreMemory))
        expectMLX(OnDeviceModel.kind(configuredPath: folder.path, availableMemory: tight + 1), directory: folder)
        #expect(OnDeviceModel.kind(configuredPath: folder.path, availableMemory: 99) == .stub(.needsMoreMemory))
    }

    /// The admission rule lets the pinned weights through when 3.5 GB is
    /// free. That figure stands in for an 8 GB phone's leftover memory. It
    /// is not a measurement that the model fits iPhone 17e or the Mac. The
    /// half-of-available rule this replaced turned the model away at that
    /// figure, and this rule still turns away the 5.1 GB Gemma 4 E4B file.
    @Test func thePinnedModelFitsWhereTheHalfRuleTurnedItAway() throws {
        let weights = try #require(PinnedModel.default.files.first { $0.name.hasSuffix(".safetensors") }).bytes
        let phone: UInt64 = 3_500_000_000
        #expect(UInt64(weights) > phone / 2)
        #expect(OnDeviceModel.fits(weightBytes: UInt64(weights), available: phone))
        #expect(OnDeviceModel.fits(weightBytes: UInt64(weights), available: 16 << 30))
        #expect(!OnDeviceModel.fits(weightBytes: UInt64(weights), available: UInt64(weights)))
        #expect(!OnDeviceModel.fits(weightBytes: 5_146_800_534, available: phone))
    }

    @Test func environmentWinsOverDefaults() throws {
        let fromEnvironment = try modelFolder()
        let fromDefaults = try modelFolder()
        defer {
            remove(fromEnvironment)
            remove(fromDefaults)
        }
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(fromDefaults.path, forKey: OnDeviceModel.defaultsKey)
        let kind = OnDeviceModel.kind(
            environment: [OnDeviceModel.environmentKey: fromEnvironment.path],
            defaults: defaults,
            availableMemory: plentyOfMemory
        )
        expectMLX(kind, directory: fromEnvironment)
    }

    @Test func unusableEnvironmentDoesNotFallThroughToDefaults() throws {
        let fromDefaults = try modelFolder()
        defer { remove(fromDefaults) }
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(fromDefaults.path, forKey: OnDeviceModel.defaultsKey)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-model-\(UUID().uuidString)", isDirectory: true)
        let kind = OnDeviceModel.kind(
            environment: [OnDeviceModel.environmentKey: missing.path],
            defaults: defaults,
            availableMemory: plentyOfMemory
        )
        #expect(kind.isStub)
    }

    @Test func defaultsSelectMLXWhenTheEnvironmentIsUnset() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(folder.path, forKey: OnDeviceModel.defaultsKey)
        expectMLX(OnDeviceModel.kind(environment: [:], defaults: defaults, availableMemory: plentyOfMemory),
                  directory: folder)
    }

    // MARK: The downloaded folder

    /// The cause of the canned replies: nothing ever put a model where the
    /// app looked. Now the folder the download fills is used with no
    /// environment variable and no defaults key.
    @Test func aDownloadedModelIsUsedWithNothingElseSet() throws {
        let place = try TestPin.place()
        defer { place.remove() }
        try place.writeReady()
        let name = "tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let client = OnDeviceModel.client(environment: [:], defaults: defaults, folders: place.folders,
                                          pin: place.pin, availableMemory: plentyOfMemory)
        let mlx = try #require(client.active as? MLXChatModel)
        #expect(mlx.folder.resolvingSymlinksInPath().path == place.ready.resolvingSymlinksInPath().path)
    }

    @Test func nothingDownloadedSaysSo() throws {
        let place = try TestPin.place()
        defer { place.remove() }
        #expect(OnDeviceModel.kind(environment: [:], defaults: .standard, folders: place.folders, pin: place.pin,
                                   availableMemory: plentyOfMemory) == .stub(.notDownloaded))
    }

    @Test func aFolderMissingAFileIsIncomplete() throws {
        let place = try TestPin.place()
        defer { place.remove() }
        try place.writeReady()
        try FileManager.default.removeItem(at: place.ready.appendingPathComponent("tokenizer.json"))
        #expect(OnDeviceModel.kind(downloaded: place.ready, pin: place.pin, availableMemory: plentyOfMemory)
            == .stub(.incomplete))
    }

    @Test func aFileOfTheWrongSizeIsIncomplete() throws {
        let place = try TestPin.place()
        defer { place.remove() }
        try place.writeReady()
        try Data("short".utf8).write(to: place.ready.appendingPathComponent("weights.safetensors"))
        #expect(OnDeviceModel.kind(downloaded: place.ready, pin: place.pin, availableMemory: plentyOfMemory)
            == .stub(.incomplete))
    }

    /// Files still under their temporary folder are never a model, however whole.
    @Test func aDownloadStillInItsTemporaryFolderIsNotReady() throws {
        let place = try TestPin.place()
        defer { place.remove() }
        let partial = place.folders.root.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try place.writeFiles(in: partial)
        #expect(OnDeviceModel.kind(environment: [:], defaults: .standard, folders: place.folders, pin: place.pin,
                                   availableMemory: plentyOfMemory) == .stub(.notDownloaded))
    }

    // MARK: The placeholder is honest

    @Test func thePlaceholderSaysTheModelIsNotReadyInsteadOfAnswering() async throws {
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "What should I cook tonight?")]
        for reason in OnDeviceModelNotReady.allCases {
            let reply = try await LocalStubModel(notReady: reason).reply(to: turns)
            #expect(reply == OnDeviceModelWords.notReadyReply(reason))
            #expect(reply != LocalStubModel.fallback)
            #expect(reply.hasPrefix("Sorry, I can't really answer that"))
        }
        let notDownloaded = OnDeviceModelWords.notReadyReply(.notDownloaded)
        #expect(notDownloaded.contains("open \(MemoryWords.title) and choose Download on-device model."))
        #expect(OnDeviceModelWords.notReadyReply(.incomplete).contains("Open \(MemoryWords.title) to download it again."))
    }

    // MARK: The one client

    /// The on-device model must say it runs here, or every on-device chat
    /// refuses it as leaving the device.
    @Test func anOnDeviceChatReachesTheModel() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { remove(folder) }
        let model = MLXChatModel(directory: folder)
        #expect(model.runsOnDevice)
        let chat = OnDeviceChat(model)
        let opening = Conversation.firstRun(named: "Pip", place: chat.privacyPlace)
        #expect(opening.place.staysOnDevice)
        // The empty folder fails to load, so the reply is the placeholder's
        // honest line, not a refusal for leaving the device.
        let answered = try await opening.sending("Hi.", with: chat)
        #expect(answered.turns.last?.text == OnDeviceModelWords.notReadyReply(.couldNotLoad))
        #expect((chat.active as? LocalStubModel)?.notReady == .couldNotLoad)
    }

    /// A folder that fails to load moves the chat back to the placeholder,
    /// tells the listener once, and a model put in since is never replaced.
    @Test func aModelThatFailsToLoadFallsBackAndSaysSo() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-config-\(UUID().uuidString)", isDirectory: true)
        try writeModelFiles(in: folder, weightBytes: 16)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("config.json"))
        defer { remove(folder) }
        let chat = OnDeviceChat(MLXChatModel(directory: folder))
        let heard = FailedFolders()
        chat.onLoadFailure(heard.add)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "What should I cook tonight?")]
        #expect(try await chat.reply(to: turns) == OnDeviceModelWords.notReadyReply(.couldNotLoad))
        #expect((chat.active as? LocalStubModel)?.notReady == .couldNotLoad)
        #expect(heard.all == [folder])
        #expect(try await chat.reply(to: turns) == OnDeviceModelWords.notReadyReply(.couldNotLoad))
        #expect(heard.all == [folder])
    }

    @Test func theClientMovesToTheModelAndRefusesOneThatLeavesTheDevice() async throws {
        let chat = OnDeviceChat(LocalStubModel(notReady: .notDownloaded))
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hello there.")]
        #expect(try await chat.reply(to: turns) == OnDeviceModelWords.notReadyReply(.notDownloaded))
        #expect(!chat.use(LeavesDevice()))
        #expect(chat.active is LocalStubModel)
        #expect(chat.use(LocalStubModel()))
        #expect(try await chat.reply(to: turns) == LocalStubModel.fallback)
        #expect(chat.runsOnDevice)
    }

    /// The load listener must not keep a model that has been replaced. The
    /// model is what holds the weights, so it has to be able to go.
    @Test func aReplacedModelCanBeDeallocated() {
        let chat = OnDeviceChat(LocalStubModel())
        weak var gone: MLXChatModel?
        autoreleasepool {
            let model = MLXChatModel(
                directory: URL(fileURLWithPath: "/tmp/no-such-model", isDirectory: true),
                runner: OnDeviceRunner(),
                generator: QuietGenerator())
            gone = model
            #expect(chat.use(model))
            chat.onLoaded { _ in }
            model.noteLoaded()
            #expect(chat.use(LocalStubModel()))
        }
        #expect(gone == nil)
    }

    // MARK: The transcript

    @Test func transcriptStartsWithTheOnDeviceInstruction() {
        let lines = OnDeviceTranscript.lines(for: [
            ChatTurn(id: UUID(), speaker: .agent, text: "Hi."),
            ChatTurn(id: UUID(), speaker: .person, text: "Hello."),
        ])
        #expect(lines.map(\.role) == [.system, .agent, .person])
        #expect(lines.map(\.text) == [
            OnDeviceTranscript.instructions,
            "Hi.",
            "Hello.",
        ])
        #expect(OnDeviceTranscript.maxReplyTokens == 512)
    }

    @Test func transcriptKeepsOnlyTheRecentTurns() {
        let turns = (0..<30).map { index in
            ChatTurn(id: UUID(), speaker: .person, text: "t\(index)")
        }
        let lines = OnDeviceTranscript.lines(for: turns)
        #expect(lines.count == OnDeviceTranscript.maxHistoryTurns + 1)
        #expect(lines.first?.role == .system)
        #expect(lines.first?.text == OnDeviceTranscript.instructions)
        #expect(lines.dropFirst().first?.text == "t6")
        #expect(lines.last?.text == "t29")
    }

    // MARK: The token budget

    /// One token a character, so the test can see what fits.
    private static func characters(_ lines: [OnDeviceTranscriptLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.count }
    }

    /// A pasted document inside the turn limit would still fill the cache
    /// past the headroom. The oldest turns go until the prompt fits; the
    /// system line and the latest message stay.
    @Test func aLongPasteIsLeftOutOldestFirstAndTheLatestMessageStays() async throws {
        let budget = OnDeviceModel.promptTokens
        let pasted = String(repeating: "a", count: budget * 4)
        let turns = [
            ChatTurn(id: UUID(), speaker: .person, text: "Read this for me."),
            ChatTurn(id: UUID(), speaker: .person, text: pasted),
            ChatTurn(id: UUID(), speaker: .agent, text: "I read it."),
            ChatTurn(id: UUID(), speaker: .person, text: "What was the main point?"),
        ]
        let all = OnDeviceTranscript.lines(for: turns)
        #expect(all.count == turns.count + 1)
        #expect(Self.characters(all) > budget)
        let kept = try await OnDeviceTranscript.fitting(all, budget: budget, count: Self.characters)
        #expect(Self.characters(kept) <= budget)
        #expect(kept.first == all.first)
        #expect(kept.map(\.text) == [OnDeviceTranscript.instructions, "I read it.", "What was the main point?"])
    }

    @Test func aTranscriptThatFitsIsSentWhole() async throws {
        let turns = (0..<6).map { ChatTurn(id: UUID(), speaker: $0.isMultiple(of: 2) ? .person : .agent, text: "t\($0)") }
        let all = OnDeviceTranscript.lines(for: turns)
        let kept = try await OnDeviceTranscript.fitting(all, budget: OnDeviceModel.promptTokens, count: Self.characters)
        #expect(kept == all)
    }

    /// The latest message alone too long is a plain error the chat can say, never a crash.
    @Test func aLatestMessageTooLongAloneIsRefused() async throws {
        let budget = OnDeviceModel.promptTokens
        for earlier in [0, 3] {
            var turns = (0..<earlier).map { ChatTurn(id: UUID(), speaker: .person, text: "t\($0)") }
            turns.append(ChatTurn(id: UUID(), speaker: .person, text: String(repeating: "b", count: budget + 1)))
            await #expect(throws: MLXChatModelError.tooLong) {
                try await OnDeviceTranscript.fitting(OnDeviceTranscript.lines(for: turns), budget: budget,
                                                     count: Self.characters)
            }
        }
        #expect(!MLXChatModelError.tooLong.isLoadFailure)
    }

    /// The cache is bounded to the budget, and the budget's cache fits the headroom.
    @Test func theCacheIsBoundedInsideTheHeadroom() {
        let parameters = MLXChatModel.parameters
        #expect(parameters.maxKVSize == OnDeviceModel.contextTokens)
        #expect(parameters.maxTokens == OnDeviceTranscript.maxReplyTokens)
        #expect(OnDeviceModel.promptTokens + OnDeviceTranscript.maxReplyTokens == OnDeviceModel.contextTokens)
        let measuredOverWeights: UInt64 = 490_000_000
        #expect(UInt64(OnDeviceModel.contextTokens) * OnDeviceModel.cacheBytesPerToken + measuredOverWeights
            <= OnDeviceModel.headroomBytes)
    }

    @Test func emptyTranscriptDoesNotNeedWeights() async {
        let model = MLXChatModel(directory: URL(fileURLWithPath: "/tmp/no-such-model", isDirectory: true))
        await #expect(throws: ModelClientError.noPersonTurn) {
            try await model.reply(to: [])
        }
    }

    @Test func emptyFolderThrowsAndTheNextReplyDoesNotReload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { remove(folder) }
        let model = MLXChatModel(directory: folder)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi.")]
        await #expect(throws: MLXChatModelError.unavailable) {
            try await model.reply(to: turns)
        }
        await #expect(throws: MLXChatModelError.unavailable) {
            try await model.reply(to: turns)
        }
    }

    @Test func invalidConfigThrowsAndTheNextReplyDoesNotReload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-config-\(UUID().uuidString)", isDirectory: true)
        try writeModelFiles(in: folder, weightBytes: 16)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("config.json"))
        defer { remove(folder) }
        let model = MLXChatModel(directory: folder)
        let turns = [ChatTurn(id: UUID(), speaker: .person, text: "Hi.")]
        await #expect(throws: MLXChatModelError.invalidConfiguration) {
            try await model.reply(to: turns)
        }
        await #expect(throws: MLXChatModelError.invalidConfiguration) {
            try await model.reply(to: turns)
        }
    }

    /// Compares the selected folder by its resolved path.
    ///
    /// File URL equality also compares the directory slash, and resolving a
    /// path before the folder exists drops that slash.
    private func expectMLX(
        _ kind: OnDeviceModelKind,
        directory folder: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .mlx(let directory) = kind else {
            Issue.record("Expected the on-device model.", sourceLocation: sourceLocation)
            return
        }
        let selected = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let expected = folder.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(selected == expected, sourceLocation: sourceLocation)
    }

    private func modelFolder(weightBytes: Int = 16) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
        try writeModelFiles(in: folder, weightBytes: weightBytes)
        // Resolve after the directory exists so the URL matches kind(), including the directory slash.
        return folder.resolvingSymlinksInPath()
    }

    private func writeModelFiles(in folder: URL, weightBytes: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 0, count: weightBytes).write(to: folder.appendingPathComponent("weights.safetensors"))
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A model that says its words leave the device.
private final class FailedFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []

    func add(_ folder: URL) {
        lock.lock()
        folders.append(folder)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return folders
    }
}

private struct LeavesDevice: ModelClient {
    func reply(to transcript: [ChatTurn]) async throws -> String { "remote" }
}

/// A model stand-in that never loads weights of its own.
private struct QuietGenerator: OnDeviceGenerating {
    func reply(to transcript: [ChatTurn]) async throws -> String { "" }
    func drain() async {}
}
