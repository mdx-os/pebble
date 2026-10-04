import Foundation

/// One place the pulse checks. The list lives in `pulse/sources.json`.
public struct PulseSource: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        case appStore
        case releaseFeed
        case firstParty
        case xSearch
    }

    public enum Cadence: String, Sendable, Equatable, Codable, CaseIterable {
        case daily
        case weekly
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var cadence: Cadence
    /// The page a person would open.
    public var url: URL?
    /// Where to download text when that differs from `url`, such as a markdown copy.
    public var fetchURL: URL?
    /// X handles, without the @. Only used by `xSearch`.
    public var handles: [String]?
    /// What to ask X search to look for. Only used by `xSearch`.
    public var query: String?
    /// Posts this source may fetch in one run. Only used by `xSearch`.
    public var postCap: Int?

    public init(
        id: String,
        title: String,
        kind: Kind,
        cadence: Cadence,
        url: URL? = nil,
        fetchURL: URL? = nil,
        handles: [String]? = nil,
        query: String? = nil,
        postCap: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.cadence = cadence
        self.url = url
        self.fetchURL = fetchURL
        self.handles = handles
        self.query = query
        self.postCap = postCap
    }

    /// The address to download. X search has no page.
    public var fetchLocation: URL? {
        fetchURL ?? url
    }

    public func validate() throws {
        guard id.range(of: #"^[a-z][a-z0-9]*(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw PulseError(message: "Source id \(id) must be lowercase words separated by hyphens.")
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.contains("\n") {
            throw PulseError(message: "Source \(id) needs a one-line title.")
        }
        switch kind {
        case .appStore, .releaseFeed, .firstParty:
            guard let url, url.scheme == "https" else {
                throw PulseError(message: "Source \(id) needs an https url.")
            }
        case .xSearch:
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PulseError(message: "X search source \(id) needs a query.")
            }
            guard query.count <= 500 else {
                throw PulseError(message: "X search query for \(id) is too long.")
            }
            let handles = try Self.normalizedHandles(handles ?? [], id: id)
            guard !handles.isEmpty, handles.count <= 20 else {
                throw PulseError(message: "X search source \(id) needs 1 to 20 handles.")
            }
            guard let postCap else {
                throw PulseError(message: "X search source \(id) needs a postCap.")
            }
            _ = try XSearchBudget(postCap: postCap)
        }
        if let fetchURL, fetchURL.scheme != "https" {
            throw PulseError(message: "Source \(id) fetch url must be https.")
        }
    }

    public static func normalizedHandles(_ raw: [String], id: String) throws -> [String] {
        var seen: [String] = []
        for handle in raw {
            var name = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("@") {
                name.removeFirst()
            }
            guard name.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else {
                throw PulseError(message: "X handle \(handle) on \(id) is not a handle.")
            }
            if !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }
}

/// The checked-in source list.
public struct PulseSourceList: Sendable, Equatable, Codable {
    public var sources: [PulseSource]

    public init(sources: [PulseSource]) {
        self.sources = sources
    }

    public func validate() throws {
        var seen: Set<String> = []
        for source in sources {
            try source.validate()
            if seen.contains(source.id) {
                throw PulseError(message: "Source id \(source.id) is listed twice.")
            }
            seen.insert(source.id)
        }
    }

    public static func load(from url: URL) throws -> PulseSourceList {
        let data = try Data(contentsOf: url)
        let list = try JSONDecoder().decode(PulseSourceList.self, from: data)
        try list.validate()
        return list
    }

    public func sources(for cadence: PulseSource.Cadence) -> [PulseSource] {
        sources.filter { $0.cadence == cadence }
    }
}
