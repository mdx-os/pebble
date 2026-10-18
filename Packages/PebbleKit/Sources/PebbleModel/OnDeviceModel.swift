import Foundation
import PebbleCore
#if canImport(Darwin)
import Darwin
#endif

/// Which on-device model the chat should use.
public enum OnDeviceModelKind: Sendable, Equatable {
    /// The placeholder, which says plainly why the model isn't ready.
    case stub(OnDeviceModelNotReady)
    /// An MLX model directory already on the device.
    case mlx(directory: URL)

    public var isStub: Bool {
        if case .stub = self { return true }
        return false
    }
}

/// Resolves the model the chat uses.
///
/// A developer's folder comes first: the environment variable, then the
/// UserDefaults key, each naming a directory already on the device. Without
/// either, the folder the person downloaded from the memory screen is used
/// once it is whole. The placeholder is used when there is nothing, when a
/// configured value cannot be read as a local folder, or when the folder is
/// missing, incomplete, or too large for the memory on this device, and it
/// says which. Nothing here contacts the network, and nothing is logged:
/// the memory screen shows which it chose.
public enum OnDeviceModel {
    public static let environmentKey = "PEBBLE_MLX_MODEL"
    public static let defaultsKey = "onDeviceModelFolder"

    /// Memory the model needs beyond its weights: the key and value cache
    /// for a long chat (about 150 KB a token for the pinned model, so about
    /// 300 MB at 2,000 tokens), the MLX buffer cache (capped at 64 MB), the
    /// work of one step, and the app itself. Measured on a Mac, the pinned
    /// model peaked 0.49 GB over its weights on short chats; this leaves
    /// twice that. The rule it replaced let weights use only half of the
    /// memory available, which on iPhone 17e would turn away the 2.26 GB
    /// model that runs there at about 26 tokens a second.
    public static let headroomBytes: UInt64 = 1 << 30

    /// The key and value cache for one token of the pinned model: 36
    /// layers, 8 key and value heads of 128 numbers each, two bytes a number.
    public static let cacheBytesPerToken: UInt64 = 2 * 36 * 8 * 128 * 2

    /// The most tokens one reply may hold in the cache, the prompt and the
    /// reply together. The cache is bounded to this. At 3,072 tokens it is
    /// about 450 MB, which with the 0.49 GB measured on short chats stays
    /// inside `headroomBytes`. The turn limit alone did not bound this: one
    /// pasted document could fill the cache past the headroom, and the
    /// system would end the app and the chat with it.
    public static let contextTokens = 3072

    /// The most tokens the prompt may take, so the longest reply still fits.
    public static let promptTokens = contextTokens - OnDeviceTranscript.maxReplyTokens

    public static func kind(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        folders: ModelFolders? = nil,
        pin: PinnedModel = .default,
        availableMemory: UInt64 = OnDeviceModel.availableMemory()
    ) -> OnDeviceModelKind {
        if let path = nonempty(environment[environmentKey]) ?? nonempty(defaults.string(forKey: defaultsKey)) {
            return kind(configuredPath: path, availableMemory: availableMemory)
        }
        guard let folders else { return .stub(.notDownloaded) }
        return kind(downloaded: folders.ready(for: pin), pin: pin, availableMemory: availableMemory)
    }

    public static func kind(
        configuredPath: String?,
        availableMemory: UInt64 = OnDeviceModel.availableMemory()
    ) -> OnDeviceModelKind {
        guard let directory = directory(from: configuredPath) else { return .stub(.notDownloaded) }
        return usable(directory, availableMemory: availableMemory)
    }

    /// The downloaded folder, only when every pinned file is in it at its size.
    public static func kind(
        downloaded folder: URL,
        pin: PinnedModel,
        availableMemory: UInt64 = OnDeviceModel.availableMemory()
    ) -> OnDeviceModelKind {
        guard FileManager.default.fileExists(atPath: folder.path) else { return .stub(.notDownloaded) }
        guard ModelInstaller.isComplete(folder, pin: pin) else { return .stub(.incomplete) }
        return usable(folder, availableMemory: availableMemory)
    }

    /// The client the app makes once and shares with every chat. It starts
    /// on what `kind` finds, and moves to the model when a download finishes.
    public static func client(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        folders: ModelFolders? = nil,
        pin: PinnedModel = .default,
        availableMemory: UInt64 = OnDeviceModel.availableMemory()
    ) -> OnDeviceChat {
        OnDeviceChat(model(for: kind(environment: environment, defaults: defaults, folders: folders, pin: pin,
                                     availableMemory: availableMemory)))
    }

    /// The model for a kind: MLX for a usable folder, otherwise the
    /// placeholder, which says why instead of pretending to answer.
    public static func model(for kind: OnDeviceModelKind) -> any ModelClient {
        switch kind {
        case .stub(let reason): LocalStubModel(notReady: reason)
        case .mlx(let directory): MLXChatModel(directory: directory)
        }
    }

    /// Whether weights of this size leave `headroomBytes` of `available`.
    public static func fits(weightBytes: UInt64, available: UInt64) -> Bool {
        weightBytes <= available && available - weightBytes >= headroomBytes
    }

    /// The memory this process can draw on.
    ///
    /// iPhone and iPad use the memory the process can still spend.
    /// Mac uses the machine's physical memory.
    public static func availableMemory() -> UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        ProcessInfo.processInfo.physicalMemory
        #endif
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An absolute file directory, or nil when the value must not be loaded:
    /// a relative path, a home shortcut that can't be expanded, an address
    /// that can't be read, a remote one, or a file address with a host.
    private static func directory(from configuredPath: String?) -> URL? {
        guard let trimmed = nonempty(configuredPath) else { return nil }
        if trimmed.contains("://") {
            return directory(fromAddress: trimmed)
        }
        guard let expanded = expandHomeShortcut(trimmed), expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func expandHomeShortcut(_ path: String) -> String? {
        guard path.hasPrefix("~") else { return path }
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : nil
    }

    private static func directory(fromAddress raw: String) -> URL? {
        guard let url = URL(string: raw), url.isFileURL else { return nil }
        if let host = url.host, !host.isEmpty { return nil }
        guard url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }

    /// MLX at the resolved directory when it holds a usable model, otherwise
    /// the placeholder with the reason: no folder, no config.json or
    /// tokenizer.json, no weights, weights that can't be measured, or
    /// weights too large for the memory here.
    private static func usable(_ url: URL, availableMemory: UInt64) -> OnDeviceModelKind {
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .stub(.notDownloaded)
        }
        let config = resolved.appendingPathComponent("config.json")
        let tokenizer = resolved.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: config.path),
              FileManager.default.fileExists(atPath: tokenizer.path) else {
            return .stub(.incomplete)
        }
        switch safetensorsBytes(in: resolved) {
        case .none, .unreadable:
            return .stub(.incomplete)
        case .bytes(let weightBytes) where !fits(weightBytes: weightBytes, available: availableMemory):
            return .stub(.needsMoreMemory)
        case .bytes:
            return .mlx(directory: resolved)
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
