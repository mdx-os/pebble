import Foundation
import PebbleCore

public struct PulseInvocation: Sendable, Equatable {
    public var sources: String
    public var snapshots: String
    public var digest: String
    public var help: Bool

    public static let usage = """
    pebble-pulse [--sources pulse/sources.json] [--snapshots pulse/snapshots] [--digest build/pulse/digest.md]

    Saves each source as text under the snapshots directory and writes a digest
    of what changed. X search runs only when XAI_API_KEY is set, and it refuses
    to keep a result that fetched more posts than the source cap.
    """

    public static func parse(_ arguments: [String]) throws -> PulseInvocation {
        var sources = "pulse/sources.json"
        var snapshots = "pulse/snapshots"
        var digest = "build/pulse/digest.md"
        var help = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                help = true
            case "--sources":
                sources = try value(after: &index, in: arguments, flag: argument)
            case "--snapshots":
                snapshots = try value(after: &index, in: arguments, flag: argument)
            case "--digest":
                digest = try value(after: &index, in: arguments, flag: argument)
            default:
                throw PulseError(message: "Unknown argument \(argument).")
            }
            index += 1
        }
        return PulseInvocation(sources: sources, snapshots: snapshots, digest: digest, help: help)
    }

    private static func value(after index: inout Int, in arguments: [String], flag: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw PulseError(message: "\(flag) needs a path.")
        }
        return arguments[index]
    }
}

public enum PulseCommand {
    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fetcher: (any PageFetching)? = nil,
        transport: (any HTTPSending)? = nil,
        now: Date = Date()
    ) async -> Int {
        let invocation: PulseInvocation
        do {
            invocation = try PulseInvocation.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
        if invocation.help {
            print(PulseInvocation.usage)
            return 0
        }

        do {
            let sourcesURL = URL(fileURLWithPath: invocation.sources)
            let list = try PulseSourceList.load(from: sourcesURL)
            let snapshotsURL = URL(fileURLWithPath: invocation.snapshots)
            let digestURL = URL(fileURLWithPath: invocation.digest)
            let key = environment[XSearchClient.apiKeyEnvironment]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let search = XSearchClient(
                apiKey: (key?.isEmpty == false) ? key : nil,
                transport: transport ?? URLSessionHTTPSender()
            )
            let runner = PulseRunner(
                fetcher: fetcher ?? URLSessionPageFetcher(),
                search: search,
                store: SnapshotStore(directory: snapshotsURL),
                snapshotPrefix: invocation.snapshots.hasSuffix("/")
                    ? String(invocation.snapshots.dropLast())
                    : invocation.snapshots,
                now: now
            )
            let digest = await runner.run(sources: list.sources)
            try FileManager.default.createDirectory(
                at: digestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(digest.markdown().utf8).write(to: digestURL, options: .atomic)
            let counts = count(digest)
            print(
                "pulse: \(counts.new) new, \(counts.changed) changed, \(counts.unchanged) unchanged, \(counts.skipped) skipped, \(counts.failed) failed"
            )
            print("digest: \(invocation.digest)")
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func count(_ digest: PulseDigest) -> (new: Int, changed: Int, unchanged: Int, skipped: Int, failed: Int) {
        var counts = (new: 0, changed: 0, unchanged: 0, skipped: 0, failed: 0)
        for entry in digest.entries {
            switch entry.status {
            case .new: counts.new += 1
            case .changed: counts.changed += 1
            case .unchanged: counts.unchanged += 1
            case .skipped: counts.skipped += 1
            case .failed: counts.failed += 1
            }
        }
        return counts
    }
}
