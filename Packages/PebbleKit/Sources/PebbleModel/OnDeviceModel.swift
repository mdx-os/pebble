import Foundation
import os
import PebbleCore
#if canImport(Darwin)
import Darwin
#endif

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

    /// How many recent turns go with the system line. Older turns are left out.
    public static let maxHistoryTurns = 24

    /// The system line, then the most recent turns in order.
    public static func lines(for transcript: [ChatTurn]) -> [OnDeviceTranscriptLine] {
        var lines = [OnDeviceTranscriptLine(role: .system, text: instructions)]
        let recent = transcript.suffix(maxHistoryTurns)
        for turn in recent {
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
/// already on the device. The placeholder is used when neither is set, when
/// the value cannot be read as a local folder, or when that folder is missing,
/// incomplete, or too large for the memory on this device.
public enum OnDeviceModel {
    public static let environmentKey = "PEBBLE_MLX_MODEL"
    public static let defaultsKey = "pebble.mlx.modelDirectory"

    /// Weights may use at most half of the memory this process can draw on.
    static let weightShareDenominator: UInt64 = 2

    private static let log = Logger(subsystem: "com.mdxos.pebble", category: "model")

    public static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        weightBudget: UInt64 = OnDeviceModel.defaultWeightBudget()
    ) -> OnDeviceModelKind {
        let path = nonempty(environment[environmentKey]) ?? nonempty(defaults.string(forKey: defaultsKey))
        return kind(configuredPath: path, weightBudget: weightBudget)
    }

    public static func kind(
        configuredPath: String?,
        weightBudget: UInt64 = OnDeviceModel.defaultWeightBudget()
    ) -> OnDeviceModelKind {
        guard let directory = directory(from: configuredPath) else { return .stub }
        guard let usable = usableDirectory(directory, weightBudget: weightBudget) else { return .stub }
        return .mlx(directory: usable)
    }

    /// The client `ChatView` should use. The placeholder unless a usable MLX folder is configured.
    public static func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        weightBudget: UInt64 = OnDeviceModel.defaultWeightBudget()
    ) -> any ModelClient {
        switch kind(environment: environment, defaults: defaults, weightBudget: weightBudget) {
        case .stub:
            log.info("Using the placeholder.")
            return LocalStubModel()
        case .mlx(let directory):
            log.info("Using the on-device model at \(directory.path, privacy: .private)")
            return MLXChatModel(directory: directory)
        }
    }

    /// Half of the memory available to this process.
    ///
    /// iPhone and iPad use the memory the process can still spend.
    /// Mac uses the machine's physical memory.
    public static func defaultWeightBudget() -> UInt64 {
        let available: UInt64
        #if os(iOS)
        available = os_proc_available_memory()
        #else
        available = ProcessInfo.processInfo.physicalMemory
        #endif
        return available / weightShareDenominator
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An absolute file directory, or nil when the value must not be loaded.
    private static func directory(from configuredPath: String?) -> URL? {
        guard let trimmed = nonempty(configuredPath) else { return nil }
        if trimmed.contains("://") {
            return directory(fromAddress: trimmed)
        }
        guard let expanded = expandHomeShortcut(trimmed) else { return nil }
        guard expanded.hasPrefix("/") else {
            log.info("A relative path was ignored, so replies stay on the placeholder.")
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func expandHomeShortcut(_ path: String) -> String? {
        guard path.hasPrefix("~") else { return path }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            log.info("A home shortcut could not be expanded, so replies stay on the placeholder.")
            return nil
        }
        return expanded
    }

    private static func directory(fromAddress raw: String) -> URL? {
        guard let url = URL(string: raw) else {
            log.info("The configured address could not be read, so replies stay on the placeholder.")
            return nil
        }
        guard url.isFileURL else {
            log.info("A remote address was ignored, so replies stay on the placeholder.")
            return nil
        }
        if let host = url.host, !host.isEmpty {
            log.info("A file address with a host was ignored, so replies stay on the placeholder.")
            return nil
        }
        guard url.path.hasPrefix("/") else {
            log.info("A relative path was ignored, so replies stay on the placeholder.")
            return nil
        }
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }

    /// The resolved directory when it contains a usable model, otherwise nil.
    private static func usableDirectory(_ url: URL, weightBudget: UInt64) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            log.info("No model folder at the configured path, so replies stay on the placeholder. \(resolved.path, privacy: .private)")
            return nil
        }
        let config = resolved.appendingPathComponent("config.json")
        let tokenizer = resolved.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: config.path),
              FileManager.default.fileExists(atPath: tokenizer.path) else {
            log.info("The model folder is missing config.json or tokenizer.json, so replies stay on the placeholder. \(resolved.path, privacy: .private)")
            return nil
        }
        switch safetensorsBytes(in: resolved) {
        case .none:
            log.info("The model folder has no weights file, so replies stay on the placeholder. \(resolved.path, privacy: .private)")
            return nil
        case .unreadable:
            log.info("The weights could not be measured, so replies stay on the placeholder. \(resolved.path, privacy: .private)")
            return nil
        case .bytes(let weightBytes) where weightBytes > weightBudget:
            log.info("The model is too big for the memory on this device, so replies stay on the placeholder. \(resolved.path, privacy: .private)")
            return nil
        case .bytes:
            return resolved
        }
    }

    private enum WeightTotal {
        case none
        case unreadable
        case bytes(UInt64)
    }

    /// Total size of the `.safetensors` files in the folder.
    private static func safetensorsBytes(in directory: URL) -> WeightTotal {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .unreadable
        }
        var total: UInt64 = 0
        var found = false
        for file in files where file.pathExtension == "safetensors" {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size >= 0 else {
                return .unreadable
            }
            let (sum, overflow) = total.addingReportingOverflow(UInt64(size))
            if overflow {
                return .bytes(UInt64.max)
            }
            total = sum
            found = true
        }
        return found ? .bytes(total) : .none
    }
}
