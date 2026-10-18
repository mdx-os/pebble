import CryptoKit
import Foundation
import PebbleCore

/// Where the on-device model is on its way, as the memory screen shows it.
public enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(received: Int64, total: Int64)
    case verifying
    case ready(URL)
    case failed(ModelDownloadProblem)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// True while a download is under way, from the first byte to the last check.
    public var isUnderWay: Bool {
        switch self {
        case .downloading, .verifying: true
        case .notDownloaded, .ready, .failed: false
        }
    }
}

/// Why a download didn't end ready. Each one leaves no ready folder behind.
public enum ModelDownloadProblem: Sendable, Equatable {
    /// The connection broke or the server said no.
    case couldNotFetch
    /// A file arrived with the wrong size or hash.
    case didNotMatch
    /// Not enough free space for the files.
    case noRoom
    /// The files came and matched but couldn't be moved into place.
    case couldNotSave
    /// Found at launch: a model folder with files missing or the wrong size.
    case incomplete
    /// The weights are more than this device can hold in memory. Trying
    /// again won't help, so there is no Try again.
    case needsMoreMemory

    public var canTryAgain: Bool { self != .needsMoreMemory }
}

/// Fetches one request into a file. The real one lives in
/// `ModelDownload.swift`; tests pass their own, so no test reaches the network.
public protocol ModelFetching: Sendable {
    /// Writes the body to `destination`, reporting the bytes so far. Throws
    /// on any failure, a status other than 200, or cancellation.
    func fetch(_ request: URLRequest, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// The folder downloaded models are kept in: inside Application Support,
/// in the app's own folder, and left out of backups, since it can always
/// be fetched again.
public struct ModelFolders: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/<app folder>/Models`. `appFolder` is the
    /// product name, read from `Brand` by the app.
    public static func onDevice(appFolder: String, fileManager: FileManager = .default) throws -> ModelFolders {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return ModelFolders(root: base.appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true))
    }

    /// The finished folder for `pin`. Only a download whose every file
    /// matched is ever moved here.
    public func ready(for pin: PinnedModel) -> URL {
        root.appendingPathComponent(pin.folderName, isDirectory: true)
    }

    /// Names a download in progress starts with. Never read as a model.
    static let partialPrefix = ".partial-"
    /// The ending of a file still arriving, until its hash is checked.
    static let arrivingSuffix = ".download"
}

/// Downloads the pinned model, checks every file, and moves it into place.
///
/// Nothing starts on its own: only `install` fetches, and only the person's
/// tap on the download button calls it. Files arrive under a temporary
/// folder, each under a temporary name. Only once every file has the pinned
/// size and SHA-256 are they renamed, and the folder moved to its finished
/// name in one step. A failure, a mismatch or a stop removes the temporary
/// folder, so a partial or bad download is never taken for ready.
public actor ModelInstaller {
    public nonisolated let pin: PinnedModel
    public nonisolated let folders: ModelFolders
    private let fetcher: any ModelFetching
    private let freeSpace: @Sendable (URL) -> Int64?

    public init(pin: PinnedModel = .default, folders: ModelFolders, fetcher: any ModelFetching,
                freeSpace: @escaping @Sendable (URL) -> Int64? = ModelInstaller.freeSpace) {
        self.pin = pin
        self.folders = folders
        self.fetcher = fetcher
        self.freeSpace = freeSpace
    }

    /// The finished folder, when every pinned file is in it at its size.
    public nonisolated func readyFolder() -> URL? {
        Self.isComplete(folders.ready(for: pin), pin: pin) ? folders.ready(for: pin) : nil
    }

    /// True when a finished folder is there but isn't whole.
    public nonisolated func hasIncompleteFolder() -> Bool {
        FileManager.default.fileExists(atPath: folders.ready(for: pin).path) && readyFolder() == nil
    }

    /// Every pinned file is in `folder` as a regular file of its pinned size.
    /// Sizes only: the hashes were checked before the folder got its name.
    public static func isComplete(_ folder: URL, pin: PinnedModel) -> Bool {
        pin.files.allSatisfy { file in
            let url = folder.appendingPathComponent(file.name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return false }
            return Int64(size) == file.bytes
        }
    }

    /// Removes what an interrupted download left, such as when the app was
    /// closed part way through.
    public func removeLeftovers() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folders.root.path) else { return }
        for name in names where name.hasPrefix(ModelFolders.partialPrefix) {
            try? fileManager.removeItem(at: folders.root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Downloads and checks every pinned file. Ends `.ready` with the
    /// finished folder, `.failed` with why, or `.notDownloaded` when
    /// stopped. `report` hears each step on the way.
    public func install(report: @escaping @Sendable (ModelDownloadState) -> Void) async -> ModelDownloadState {
        removeLeftovers()
        if let ready = readyFolder() { return .ready(ready) }
        let fileManager = FileManager.default
        let total = pin.totalBytes
        do {
            try fileManager.createDirectory(at: folders.root, withIntermediateDirectories: true)
            var root = folders.root
            try MemoryStore.excludeFromBackup(&root)
        } catch {
            return .failed(.couldNotSave)
        }
        if let free = freeSpace(folders.root), free < total {
            return .failed(.noRoom)
        }
        let partial = folders.root.appendingPathComponent(ModelFolders.partialPrefix + UUID().uuidString,
                                                          isDirectory: true)
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
        } catch {
            return .failed(.couldNotSave)
        }

        report(.downloading(received: 0, total: total))
        var done: Int64 = 0
        for file in pin.files {
            let arriving = Self.arriving(file, in: partial)
            let before = done
            do {
                try await fetcher.fetch(ModelDownloadRequest.make(pin.url(for: file)), to: arriving) { bytes in
                    report(.downloading(received: before + min(bytes, file.bytes), total: total))
                }
            } catch {
                return Task.isCancelled || Self.isCancellation(error) ? .notDownloaded : .failed(.couldNotFetch)
            }
            if Task.isCancelled { return .notDownloaded }
            done += file.bytes
        }

        report(.verifying)
        for file in pin.files {
            switch Self.matches(Self.arriving(file, in: partial), file) {
            case .matches: continue
            case .differs: return .failed(.didNotMatch)
            case .stopped: return .notDownloaded
            }
        }

        do {
            for file in pin.files {
                try fileManager.moveItem(at: Self.arriving(file, in: partial),
                                         to: partial.appendingPathComponent(file.name))
            }
            let ready = folders.ready(for: pin)
            // A folder there now was found incomplete; it is replaced whole.
            if fileManager.fileExists(atPath: ready.path) { try fileManager.removeItem(at: ready) }
            try fileManager.moveItem(at: partial, to: ready)
            guard Self.isComplete(ready, pin: pin) else {
                try? fileManager.removeItem(at: ready)
                return .failed(.couldNotSave)
            }
            return .ready(ready)
        } catch {
            return .failed(.couldNotSave)
        }
    }

    enum Check: Equatable {
        case matches
        case differs
        case stopped
    }

    /// Whether `url` has `file`'s size and SHA-256, read a piece at a time.
    static func matches(_ url: URL, _ file: PinnedModelFile) -> Check {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize,
              Int64(size) == file.bytes, let handle = try? FileHandle(forReadingFrom: url) else { return .differs }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            if Task.isCancelled { return .stopped }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 8 * 1024 * 1024)
            } catch {
                return .differs
            }
            // Nil or empty at the end of the file.
            guard let chunk, !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == file.sha256 ? .matches : .differs
    }

    private static func arriving(_ file: PinnedModelFile, in folder: URL) -> URL {
        folder.appendingPathComponent(file.name + ModelFolders.arrivingSuffix)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// Space free for files the person asked for, or nil when it can't be read.
    public static let freeSpace: @Sendable (URL) -> Int64? = { url in
        #if os(iOS) || os(macOS)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }
}
