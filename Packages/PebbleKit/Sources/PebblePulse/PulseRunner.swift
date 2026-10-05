import Foundation
import PebbleCore

/// Fetches the source list, writes normalized snapshots, and builds a digest.
public struct PulseRunner: Sendable {
    public var pages: any PageFetching
    public var search: (any XSearching)?
    public var apiKey: String?
    public var now: Date

    public init(
        pages: any PageFetching,
        search: (any XSearching)? = nil,
        apiKey: String? = nil,
        now: Date = Date()
    ) {
        self.pages = pages
        self.search = search
        self.apiKey = apiKey
        self.now = now
    }

    public func run(sources: [PulseSource], snapshots: URL) async throws -> PulseDigest {
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        var observations: [SourceObservation] = []
        var sections: [ModelSection] = []
        for source in sources {
            let result = await observe(source, snapshots: snapshots)
            observations.append(result.observation)
            if let section = result.section {
                sections.append(section)
            }
        }
        let modelInput = ModelInput.assemble(sections)
        return PulseDigest(
            generatedAt: now,
            observations: observations,
            modelInput: modelInput,
            ideaCards: IdeaDraft.cards(from: modelInput)
        )
    }

    private struct Result {
        var observation: SourceObservation
        var section: ModelSection?
    }

    private func observe(_ source: PulseSource, snapshots: URL) async -> Result {
        switch source.kind {
        case .xSearch:
            return await observeSearch(source, snapshots: snapshots)
        case .appStore:
            return await observeAppStore(source, snapshots: snapshots)
        case .webPage:
            return await observePage(source, snapshots: snapshots)
        }
    }

    private func observeSearch(_ source: PulseSource, snapshots: URL) async -> Result {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return Result(observation: observation(source, .skipped, "No XAI_API_KEY set."))
        }
        guard let search else {
            return Result(observation: observation(source, .failed, "X Search is not configured."))
        }
        let query = XSearchQuery(
            handles: source.handles ?? [],
            fromDay: PulseClock.previousDay(now),
            toDay: PulseClock.day(now)
        )
        do {
            let hit = try await search.search(query)
            let snapshot = XPostDiff.snapshot(urls: hit.postURLs)
            if snapshot.isEmpty {
                return Result(observation: observation(source, .failed, "X Search returned no posts."))
            }
            let previous = read(source, snapshots)
            let body = XPostDiff.modelBody(previous: previous, snapshot: snapshot, summary: hit.summary)
            try write(source, snapshots, snapshot)
            return finish(source, previous: previous, current: snapshot, body: body)
        } catch {
            return Result(observation: observation(source, .failed, String(describing: error)))
        }
    }

    private func observeAppStore(_ source: PulseSource, snapshots: URL) async -> Result {
        guard let appID = source.appID else {
            return Result(observation: observation(source, .failed, "App Store source is missing an app id."))
        }
        let page = await fetchResult(source.url)
        let lookup = await fetchResult(AppStoreLookup.url(appID: appID))
        let html = page.page.map { String(decoding: $0.body, as: UTF8.self) }
        let text = AppStoreSnapshot.text(pageHTML: html, lookupJSON: lookup.page?.body, sourceName: source.name)
        if text.isEmpty {
            let detail = page.error ?? lookup.error ?? "App Store page came back empty."
            return Result(observation: observation(source, .failed, detail))
        }
        return store(source, snapshots: snapshots, text: text)
    }

    private func observePage(_ source: PulseSource, snapshots: URL) async -> Result {
        let url = source.fetchURL ?? source.url
        let fetched = await fetchResult(url)
        if let error = fetched.error {
            return Result(observation: observation(source, .failed, error))
        }
        guard let page = fetched.page else {
            return Result(observation: observation(source, .failed, "\(source.name) came back empty."))
        }
        let text = SnapshotText.normalize(PageText.plain(page, url: url))
        if text.isEmpty {
            return Result(observation: observation(source, .failed, "\(source.name) came back empty."))
        }
        return store(source, snapshots: snapshots, text: text)
    }

    private func store(_ source: PulseSource, snapshots: URL, text: String) -> Result {
        let previous = read(source, snapshots)
        do {
            try write(source, snapshots, text)
        } catch {
            return Result(observation: observation(source, .failed, "Could not write the snapshot."))
        }
        let body = SnapshotDiff.changedBody(previous: previous, current: text)
        return finish(source, previous: previous, current: text, body: body)
    }

    private func finish(_ source: PulseSource, previous: String?, current: String, body: String?) -> Result {
        guard let body else {
            return Result(observation: observation(source, .unchanged))
        }
        let section = ModelSection(id: source.id, name: source.name, url: source.url.absoluteString, body: body)
        let detail = previous == nil ? "First snapshot." : nil
        return Result(observation: observation(source, .changed, detail), section: section)
    }

    private func observation(_ source: PulseSource, _ outcome: SourceObservation.Outcome, _ detail: String? = nil) -> SourceObservation {
        SourceObservation(id: source.id, name: source.name, url: source.url.absoluteString, outcome: outcome, detail: detail)
    }

    private func read(_ source: PulseSource, _ directory: URL) -> String? {
        let url = directory.appendingPathComponent("\(source.id).txt")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ source: PulseSource, _ directory: URL, _ text: String) throws {
        let url = directory.appendingPathComponent("\(source.id).txt")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private struct FetchResult {
        var page: FetchedPage?
        var error: String?
    }

    private func fetchResult(_ url: URL) async -> FetchResult {
        do {
            return FetchResult(page: try await pages.fetch(url))
        } catch {
            return FetchResult(error: String(describing: error))
        }
    }
}
