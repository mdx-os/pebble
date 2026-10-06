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

    @Test func absolutePathSelectsMLX() throws {
        let defaults = try freshDefaults()
        let directory = URL(fileURLWithPath: "/tmp/pebble-model", isDirectory: true).standardizedFileURL
        let kind = OnDeviceModel.kind(environment: ["PEBBLE_MLX_MODEL": "/tmp/pebble-model"], defaults: defaults)
        let client = OnDeviceModel.client(environment: ["PEBBLE_MLX_MODEL": "/tmp/pebble-model"], defaults: defaults)
        #expect(kind == .mlx(directory: directory))
        #expect(client is MLXChatModel)
    }

    @Test func fileURLSelectsTheSameDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/pebble-model", isDirectory: true).standardizedFileURL
        #expect(OnDeviceModel.kind(configuredPath: "file:///tmp/pebble-model") == .mlx(directory: directory))
    }

    @Test func environmentWinsOverDefaults() throws {
        let defaults = try freshDefaults()
        defaults.set("/tmp/from-defaults", forKey: OnDeviceModel.defaultsKey)
        let fromEnvironment = URL(fileURLWithPath: "/tmp/from-environment", isDirectory: true).standardizedFileURL
        let kind = OnDeviceModel.kind(
            environment: ["PEBBLE_MLX_MODEL": "/tmp/from-environment"],
            defaults: defaults
        )
        #expect(kind == .mlx(directory: fromEnvironment))
    }

    @Test func defaultsSelectMLXWhenTheEnvironmentIsUnset() throws {
        let defaults = try freshDefaults()
        defaults.set("/tmp/from-defaults", forKey: OnDeviceModel.defaultsKey)
        let directory = URL(fileURLWithPath: "/tmp/from-defaults", isDirectory: true).standardizedFileURL
        #expect(OnDeviceModel.kind(environment: [:], defaults: defaults) == .mlx(directory: directory))
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

    @Test func emptyTranscriptDoesNotNeedWeights() async {
        let model = MLXChatModel(directory: URL(fileURLWithPath: "/tmp/pebble-no-such-model", isDirectory: true))
        await #expect(throws: ModelClientError.noPersonTurn) {
            try await model.reply(to: [])
        }
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "pebble.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
