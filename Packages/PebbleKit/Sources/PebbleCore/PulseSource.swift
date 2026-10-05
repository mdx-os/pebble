import Foundation

/// One public source in the competitor watch.
///
/// The list itself lives in `pulse/sources.json`. This type is only the shape.
public struct PulseSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: Kind
    /// Page a person would open. Idea cards cite this, not a machine-readable mirror.
    public var url: URL
    /// Where to download text when that differs from `url`, such as a Markdown mirror.
    public var fetchURL: URL?
    /// Numeric App Store id. Required for `appStore`.
    public var appID: String?
    /// X handles, without an @. Required for `xSearch`. At most 20.
    public var handles: [String]?

    public enum Kind: String, Codable, Sendable {
        case appStore
        case webPage
        case xSearch
    }

    public init(
        id: String,
        name: String,
        kind: Kind,
        url: URL,
        fetchURL: URL? = nil,
        appID: String? = nil,
        handles: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.fetchURL = fetchURL
        self.appID = appID
        self.handles = handles
    }
}

public enum PulseSourceError: Error, Equatable, CustomStringConvertible {
    case undecodable
    case emptyID
    case badID(String)
    case duplicateID(String)
    case badURL(String)
    case missingAppID(String)
    case badAppID(String)
    case missingHandles(String)
    case tooManyHandles(String)

    public var description: String {
        switch self {
        case .undecodable:
            "Source list could not be read."
        case .emptyID:
            "A source is missing an id."
        case .badID(let id):
            "Source id \"\(id)\" must be lowercase words separated by hyphens."
        case .duplicateID(let id):
            "Source id \"\(id)\" is listed twice."
        case .badURL(let id):
            "Source \"\(id)\" needs an http or https URL."
        case .missingAppID(let id):
            "App Store source \"\(id)\" needs an appID."
        case .badAppID(let id):
            "App Store source \"\(id)\" has an appID that is not all digits."
        case .missingHandles(let id):
            "X Search source \"\(id)\" needs at least one handle."
        case .tooManyHandles(let id):
            "X Search source \"\(id)\" has more than 20 handles."
        }
    }
}

public enum PulseSourceList {
    public static func load(_ data: Data) throws -> [PulseSource] {
        let sources: [PulseSource]
        do {
            sources = try JSONDecoder().decode([PulseSource].self, from: data)
        } catch {
            throw PulseSourceError.undecodable
        }
        try validate(sources)
        return sources
    }

    public static func validate(_ sources: [PulseSource]) throws {
        var seen: Set<String> = []
        for source in sources {
            if source.id.isEmpty { throw PulseSourceError.emptyID }
            if source.id.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
                throw PulseSourceError.badID(source.id)
            }
            if !seen.insert(source.id).inserted {
                throw PulseSourceError.duplicateID(source.id)
            }
            guard let scheme = source.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw PulseSourceError.badURL(source.id)
            }
            if let fetchURL = source.fetchURL {
                guard let scheme = fetchURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    throw PulseSourceError.badURL(source.id)
                }
            }
            switch source.kind {
            case .appStore:
                guard let appID = source.appID, !appID.isEmpty else {
                    throw PulseSourceError.missingAppID(source.id)
                }
                if appID.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil {
                    throw PulseSourceError.badAppID(source.id)
                }
            case .webPage:
                break
            case .xSearch:
                let handles = source.handles ?? []
                if handles.isEmpty { throw PulseSourceError.missingHandles(source.id) }
                if handles.count > 20 { throw PulseSourceError.tooManyHandles(source.id) }
            }
        }
    }
}
