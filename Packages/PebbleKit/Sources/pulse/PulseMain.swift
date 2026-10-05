import Foundation
import PebbleCore
import PebblePulse

@main
struct PulseMain {
    static func main() async {
        do {
            try await run()
        } catch {
            complain("pulse: \(error)")
            exit(1)
        }
    }

    private static func run() async throws {
        let root = try rootDirectory()
        let sourcesURL = root.appendingPathComponent("pulse/sources.json")
        let snapshots = root.appendingPathComponent("pulse/snapshots")
        let digestURL = root.appendingPathComponent("pulse/digest.json")

        let data = try Data(contentsOf: sourcesURL)
        let sources = try PulseSourceList.load(data)
        let apiKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (apiKey?.isEmpty == false) ? apiKey : nil
        let runner = PulseRunner(
            pages: URLSessionPageClient(),
            search: key.map { XAISearchClient(apiKey: $0) },
            apiKey: key,
            now: Date()
        )
        let digest = try await runner.run(sources: sources, snapshots: snapshots)
        try digest.json().write(to: digestURL, options: .atomic)

        let changed = digest.observations.filter { $0.outcome == .changed }.count
        let unchanged = digest.observations.filter { $0.outcome == .unchanged }.count
        let skipped = digest.observations.filter { $0.outcome == .skipped }.count
        let failed = digest.observations.filter { $0.outcome == .failed }.count
        print("pulse: \(digest.observations.count) sources, \(changed) changed, \(unchanged) unchanged, \(skipped) skipped, \(failed) failed")
        print("model input: \(digest.modelInput.count) characters")
        print("digest: \(digestURL.path)")
        for observation in digest.observations where observation.outcome == .failed || observation.outcome == .skipped {
            let detail = observation.detail.map { " (\($0))" } ?? ""
            complain("pulse: \(observation.id) \(observation.outcome.rawValue)\(detail)")
        }
        if failed > 0, changed == 0, unchanged == 0 {
            throw PulseCLIError.allFailed
        }
    }

    private static func rootDirectory() throws -> URL {
        var args = Array(CommandLine.arguments.dropFirst())
        var root: String?
        while !args.isEmpty {
            let arg = args.removeFirst()
            if arg == "--" {
                continue
            } else if arg == "--root" {
                guard !args.isEmpty else { throw PulseCLIError.usage }
                root = args.removeFirst()
            } else {
                throw PulseCLIError.usage
            }
        }
        let path = root ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private func complain(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

private enum PulseCLIError: Error, CustomStringConvertible {
    case usage
    case allFailed

    var description: String {
        switch self {
        case .usage:
            "Usage: pulse [--root PATH]"
        case .allFailed:
            "Every source failed."
        }
    }
}
