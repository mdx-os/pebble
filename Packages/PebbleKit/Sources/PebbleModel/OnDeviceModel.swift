import Foundation
import PebbleCore

/// Which on-device model the chat should use.
public enum OnDeviceModelKind: Sendable, Equatable {
    /// The fixed placeholder. This is the default.
    case stub
    /// An MLX model directory already on the device.
    case mlx(directory: URL)
}

/// One line the on-device model sees, in chat order.
public struct OnDeviceTranscriptLine: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case system
        case agent
        case person
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// How a configured local model is chosen, and the words sent with a transcript.
///
/// Nothing here contacts the network. A missing or unusable path stays on the
/// placeholder, so CI, tests, and screenshots do not load weights.
public enum OnDeviceTranscript {
    /// Plain words in front of the transcript. The product name is not included.
    public static let instructions = "You are the person's agent on this device. Reply in plain words. Stay with what they asked. Nothing from this conversation leaves the device."

    /// Stop a reply after this many tokens so generation finishes.
    public static let maxReplyTokens = 512

    /// The system line, then each turn in order.
    public static func lines(for transcript: [ChatTurn]) -> [OnDeviceTranscriptLine] {
        var lines = [OnDeviceTranscriptLine(role: .system, text: instructions)]
        for turn in transcript {
            switch turn.speaker {
            case .agent:
                lines.append(OnDeviceTranscriptLine(role: .agent, text: turn.text))
            case .person:
                lines.append(OnDeviceTranscriptLine(role: .person, text: turn.text))
            }
        }
        return lines
    }
}

/// Resolves the model the chat uses.
///
/// The environment variable wins over UserDefaults. Both name a directory
/// already on the device. The placeholder is used when neither is set, or
/// when the value is blank, relative, or not a file URL.
public enum OnDeviceModel {
    public static let environmentKey = "PEBBLE_MLX_MODEL"
    public static let defaultsKey = "pebble.mlx.modelDirectory"

    public static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> OnDeviceModelKind {
        let path = nonempty(environment[environmentKey]) ?? nonempty(defaults.string(forKey: defaultsKey))
        return kind(configuredPath: path)
    }

    public static func kind(configuredPath: String?) -> OnDeviceModelKind {
        guard let directory = directory(from: configuredPath) else { return .stub }
        return .mlx(directory: directory)
    }

    /// The client `ChatView` should use. The placeholder unless MLX is configured.
    public static func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> any ModelClient {
        switch kind(environment: environment, defaults: defaults) {
        case .stub:
            LocalStubModel()
        case .mlx(let directory):
            MLXChatModel(directory: directory)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An absolute file directory, or nil when the value must not be loaded.
    private static func directory(from configuredPath: String?) -> URL? {
        guard let trimmed = nonempty(configuredPath) else { return nil }
        let path: String
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "file",
                  url.isFileURL,
                  url.path.hasPrefix("/") else {
                return nil
            }
            path = url.path
        } else {
            guard trimmed.hasPrefix("/") else { return nil }
            path = trimmed
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
