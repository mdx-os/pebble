import Foundation
import PebbleCore

/// Fetches the source list, writes snapshots, and builds a digest of real changes.
///
/// A failed fetch does not replace a previous snapshot. An unchanged snapshot is
/// not written again and is left out of the text a model would read.
public struct PulseRunner: Sendable {
    public var fetcher: any PageFetching
    public var search: any XSearching
    public var store: SnapshotStore
    public var snapshotPrefix: String
    public var now: Date
    public var cadence: PulseSource.Cadence

    public init(
        fetcher: any PageFetching,
        search: any XSearching,
        store: SnapshotStore,
        snapshotPrefix: String,
        now: Date,
        cadence: PulseSource.Cadence = .daily
    ) {
        self.fetcher = fetcher
        self.search = search
        self.store = store
        self.snapshotPrefix = snapshotPrefix
        self.now = now
        self.cadence = cadence
    }

    public func run(sources: [PulseSource], cards: [StealCard] = []) async -> PulseDigest {
        var entries: [PulseDigest.Entry] = []
        for source in sources where source.cadence == cadence {
            entries.append(await run(source))
        }
        return PulseDigest(generatedAt: now, entries: entries, cards: cards)
    }

    private func run(_ source: PulseSource) async -> PulseDigest.Entry {
        switch source.kind {
        case .xSearch:
            return await runSearch(source)
        case .appStore, .releaseFeed, .firstParty:
            return await runPage(source)
        }
    }

    private func runPage(_ source: PulseSource) async -> PulseDigest.Entry {
        guard let url = source.fetchLocation else {
            return entry(source, status: .failed, detail: "Source \(source.id) has no url.")
        }
        do {
            let page = try await fetcher.fetch(url)
            guard (200..<300).contains(page.status) else {
                return entry(source, status: .failed, detail: "Fetch failed with HTTP \(page.status).")
            }
            let body = try PageNormalizer.normalize(kind: source.kind, body: page.body, contentType: page.contentType)
            return try record(source, body: body)
        } catch {
            return entry(source, status: .failed, detail: error.localizedDescription)
        }
    }

    private func runSearch(_ source: PulseSource) async -> PulseDigest.Entry {
        switch await search.search(source, now: now) {
        case .skipped(let reason):
            return entry(source, status: .skipped, detail: reason)
        case .failed(let reason):
            return entry(source, status: .failed, detail: reason)
        case .text(let body):
            do {
                return try record(source, body: body)
            } catch {
                return entry(source, status: .failed, detail: error.localizedDescription)
            }
        }
    }

    private func record(_ source: PulseSource, body: String) throws -> PulseDigest.Entry {
        let document = SnapshotDocument.render(source: source, body: body)
        let path = "\(snapshotPrefix)/\(source.id).txt"
        let previous = try store.read(source.id)
        if previous == document {
            return entry(source, status: .unchanged, snapshotPath: path, detail: "")
        }
        try store.write(source.id, text: document)
        if previous == nil {
            return entry(source, status: .new, snapshotPath: path, detail: document)
        }
        let diff = LineDiff.unified(old: previous ?? "", new: document, path: path) ?? ""
        return entry(source, status: .changed, snapshotPath: path, detail: diff)
    }

    private func entry(
        _ source: PulseSource,
        status: PulseDigest.Entry.Status,
        snapshotPath: String? = nil,
        detail: String
    ) -> PulseDigest.Entry {
        PulseDigest.Entry(
            sourceID: source.id,
            title: source.title,
            url: source.url,
            status: status,
            snapshotPath: snapshotPath,
            detail: detail
        )
    }
}
