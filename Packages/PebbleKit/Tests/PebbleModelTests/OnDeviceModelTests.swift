import Foundation
import PebbleCore
import PebbleModel
import Testing

struct OnDeviceModelTests {
    @Test func missingConfigurationUsesTheStub() throws {
        let defaults = try freshDefaults()
        let kind = OnDeviceModel.kind(environment: [:], defaults: defaults)
        let client = OnDeviceModel.client(environment: [:], defaults: defaults)
        #expect(kind == .stub)
        #expect(client is LocalStubModel)
    }

    @Test func blankConfigurationUsesTheStub() throws {
        let defaults = try freshDefaults()
        defaults.set("   ", forKey: OnDeviceModel.defaultsKey)
        #expect(OnDeviceModel.kind(environment: ["PEBBLE_MLX_MODEL": "  "], defaults: defaults) == .stub)
        #expect(OnDeviceModel.kind(configuredPath: nil) == .stub)
    }

    @Test func relativePathUsesTheStub() {
        #expect(OnDeviceModel.kind(configuredPath: "models/local") == .stub)
        #expect(OnDeviceModel.kind(configuredPath: "https://example.com/weights") == .stub)
    }

    @Test func nonexistentFolderUsesTheStub() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(OnDeviceModel.kind(configuredPath: missing.path) == .stub)
        let defaults = try freshDefaults()
        let client = OnDeviceModel.client(environment: [OnDeviceModel.environmentKey: missing.path], defaults: defaults)
        #expect(client is LocalStubModel)
    }

    @Test func absolutePathSelectsMLX() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let defaults = try freshDefaults()
        let kind = OnDeviceModel.kind(environment: [OnDeviceModel.environmentKey: folder.path], defaults: defaults)
        let client = OnDeviceModel.client(environment: [OnDeviceModel.environmentKey: folder.path], defaults: defaults)
        expectMLX(kind, directory: folder)
        #expect(client is MLXChatModel)
    }

    @Test func fileURLSelectsTheSameDirectory() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        expectMLX(OnDeviceModel.kind(configuredPath: folder.absoluteString), directory: folder)
    }

    @Test func fileURLWithAHostUsesTheStub() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        #expect(OnDeviceModel.kind(configuredPath: "file://localhost\(folder.path)") == .stub)
    }

    @Test func tildePathSelectsTheExpandedFolder() throws {
        let name = "pebble-model-\(UUID().uuidString)"
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath()
        try writeModelFiles(in: folder, weightBytes: 16)
        defer { remove(folder) }
        let resolved = folder.resolvingSymlinksInPath()
        expectMLX(OnDeviceModel.kind(configuredPath: "~/\(name)"), directory: resolved)
    }

    @Test func unknownHomeShortcutUsesTheStub() {
        let path = "~nosuchuserpebble\(UUID().uuidString)/model"
        #expect(OnDeviceModel.kind(configuredPath: path) == .stub)
    }

    @Test func symlinkSelectsTheResolvedFolder() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { remove(link) }
        expectMLX(OnDeviceModel.kind(configuredPath: link.path), directory: folder)
    }

    @Test func oversizedWeightsUseTheStub() throws {
        let folder = try modelFolder(weightBytes: 100)
        defer { remove(folder) }
        #expect(OnDeviceModel.kind(configuredPath: folder.path, weightBudget: 99) == .stub)
        expectMLX(OnDeviceModel.kind(configuredPath: folder.path, weightBudget: 100), directory: folder)
    }

    @Test func environmentWinsOverDefaults() throws {
        let fromEnvironment = try modelFolder()
        let fromDefaults = try modelFolder()
        defer {
            remove(fromEnvironment)
            remove(fromDefaults)
        }
        let defaults = try freshDefaults()
        defaults.set(fromDefaults.path, forKey: OnDeviceModel.defaultsKey)
        let kind = OnDeviceModel.kind(
            environment: [OnDeviceModel.environmentKey: fromEnvironment.path],
            defaults: defaults
        )
        expectMLX(kind, directory: fromEnvironment)
    }

    @Test func unusableEnvironmentDoesNotFallThroughToDefaults() throws {
        let fromDefaults = try modelFolder()
        defer { remove(fromDefaults) }
        let defaults = try freshDefaults()
        defaults.set(fromDefaults.path, forKey: OnDeviceModel.defaultsKey)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-missing-\(UUID().uuidString)", isDirectory: true)
        let kind = OnDeviceModel.kind(
            environment: [OnDeviceModel.environmentKey: missing.path],
            defaults: defaults
        )
        #expect(kind == .stub)
    }

    @Test func defaultsSelectMLXWhenTheEnvironmentIsUnset() throws {
        let folder = try modelFolder()
        defer { remove(folder) }
        let defaults = try freshDefaults()
        defaults.set(folder.path, forKey: OnDeviceModel.defaultsKey)
        expectMLX(OnDeviceModel.kind(environment: [:], defaults: defaults), directory: folder)
    }

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

    @Test func emptyTranscriptDoesNotNeedWeights() async {
        let model = MLXChatModel(directory: URL(fileURLWithPath: "/tmp/pebble-no-such-model", isDirectory: true))
        await #expect(throws: ModelClientError.noPersonTurn) {
            try await model.reply(to: [])
        }
    }

    @Test func emptyFolderThrowsAndTheNextReplyDoesNotReload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-empty-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("pebble-bad-config-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("pebble-model-\(UUID().uuidString)", isDirectory: true)
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

    private func freshDefaults() throws -> UserDefaults {
        let name = "pebble.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

}
